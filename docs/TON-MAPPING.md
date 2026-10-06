# Planet — Solana → TON 迁移映射（TON-MAPPING v0.1）

> 依据：现有 Solana 仓库 `programs/planet/src/*`（Rust/Anchor）+ `docs/PLAN-TON.md`
> 更新：2026-10-04

---

## 1. 总览

| 层 | Solana（现有，作参考） | TON（目标） | 状态 |
|---|---|---|---|
| 合约语言 | Rust / Anchor | **Tolk**（Acton） | 草稿已写，待 WSL 编译 |
| 代币标准 | SPL Token / Token-2022 | **Jetton (TEP-74/89)** | 待实现 |
| 钱包 | Phantom 等 | **TON Connect** | 待实现 |
| 预言机 | Pyth (Solana) | **RedStone**（主）/ DIA（备） | 已定（Pyth 停 TON） |
| DEX | Raydium / Jupiter | STON.fi / DeDust / TONCO | 待定 |
| 定时任务 | Clockwork（已死）| 链下 keeper | 待定 |
| 储备证明存储 | Arweave | 链下/Arweave，哈希上链 | 待定 |

---

## 2. 模块级映射

| Solana 文件 | 职责 | TON 目标 | 状态 |
|---|---|---|---|
| `lib.rs`（指令入口） | 指令分发 | `planet_core.tolk` 的 `onInternalMessage` + `AllowedMessage` 联合 | 草稿 |
| `state.rs`（ReserveState / Asset / MigrationState） | 储备状态 + 商品 + 迁移态 | `Storage` struct（TON c4） | 草稿 |
| `ppi.rs`（calculate_ppi / compute_rebalance_deltas / should_rebalance） | PPI + RTRA | Tolk 纯函数 `mintAmount`/`burnAmount` + 待加 `calculatePpi`/`computeRebalance` | 部分 |
| `mint_burn.rs`（mint_amount / burn_amount / fee_split） | 铸/赎算法 + 费率拆分 | Tolk `mintAmount`/`burnAmount`（已写）+ `feeSplit`（待加） | 部分 |
| `risk.rs`（RiskState / consume_risk） | 单笔/窗口限额 + 暂停 | `Risk` 存储段 / 独立 `risk.tolk` | 待实现 |
| `attestation.rs`（ReserveAttestation / verify_reserve / collateral_ratio） | 储备证明 | `Attestation` struct + `verifyReserve` | 待实现 |
| SPL mint/burn CPI | 调用 token program | 向 PLT **Jetton Minter** 发 `MintNewJettons` / `BurnNotification` | Jetton 已就位；PlanetCore→Minter 接线待做 |
| `Clock` + keeper.ts | 定时触发 | 链下 keeper 发 `Rebalance` 消息 | 待定 |

---

## 3. 编程模型差异（迁移要点）

| 维度 | Solana | TON |
|---|---|---|
| 执行模型 | 同步 CPI | **异步消息**（actor） |
| 状态 | 独立账户（PDA） | 合约自身 cell（c4）+ `Storage.load()/save()` |
| 地址 | PDA (seeds) | 合约地址；无 PDA 概念 |
| 代币 | SPL Token / SPL-2022 | Jetton（minter + 每用户 wallet） |
| 数值 | `u64` + 定点，禁浮点 | `int`（257-bit）+ 定点，禁浮点 |
| 溢出 | 手动 `checked_*` | Tolk int 默认带溢出检查（throw） |
| 权限 | `has_one = authority` 约束 | `assert(in.senderAddress == owner)` |
| 支付 gas | lamports | TON (nanograms)，消息携带 value |
| 定时 | Clockwork（已死） | 链下 keeper |

---

## 4. 数据模型映射（草案）

```
ReserveState            ->  Storage { owner, totalReserve, totalSupply, currentPpi, paused }
Asset（name/weight/…）  ->  map<int, Asset>（商品索引 -> 权重/基准价/现价）
RiskState               ->  Risk { maxPerTx, maxPerWindow, windowSize, windowStart, amountInWindow, paused }
ReserveAttestation      ->  Attestation { custodian, totalValue, holdingsHash, attestedAt }
MigrationState          ->  enum / int 状态位
```

---

## 5. 未决 / 待办

- [x] **PLT Jetton（TEP-74）已 vendor 并编译通过**：`contracts/jetton/JettonMinter.tolk` + `JettonWallet.tolk` + 支撑文件（源自 `ton-blockchain/tolk-bench` `01_jetton`）。CI Tolk 编译✅。
- [x] **PlanetCore → JettonMinter 铸造接线（完成，CI 编译✅）**：`handleMint(in.senderAddress, in.valueCoins, msg)` 构造 `InternalTransferStep`（空 `forwardPayload` = `beginCell().endCell().beginParse()`）+ 发 `MintNewJettons` 到 `storage.jettonMinter`。定标：`msg.queryId as uint64`、`minted as coins`。
- [x] **赎回/销毁设计决策（已定）**：PLT 走标准 TEP-74 —— 用户用**自己的 JettonWallet** 销毁 PLT，`BurnNotificationForMinter` 由钱包发给 **JettonMinter**，由其扣减 `totalSupply`。
  - **单一真相源**：PLT 供应量以 **`JettonMinter.totalSupply`** 为准；`PlanetCore.totalSupply` 降级为**展示用镜像**，不驱动赎回。
  - **USDC 出金**：不与销毁强耦合在同一条消息链（TON 无同步跨合约调用，强耦合会产生难测失败模式）。改为 Phase 1 的**授权赎回流程**（owner/keeper 依据 Minter 供应快照放款）+ 集成测试。
  - **待办（Phase 1）**：赎回集成测试 + 利率/费率 30/50/20（+10% 风险基金）的链上落账。
- [x] **PLTG 治理代币**：复用同一 `JettonMinter`（**部署第二个实例**：admin = 治理地址、genesis totalSupply = 10 亿、mintable 关闭）；**治理/质押合约 `PlanetGov.tolk` 已实现**（质押 + 按份额分红 + 按质押量投票，见 `docs/competitive-comparison.md`）。参数见 `PLAN-TON.md §1.5`。

- [ ] 商品篮子多资产数据结构在 Tolk 中的表达（map / array / cell）
- [ ] Jetton 合约（PLT + PLTG）实现方案（参考 `ton-blockchain/acton-contracts`）
- [ ] RedStone 在 TON 的接入方式（Pull 需合约验签）
- [ ] `feeSplit`（30/50/20）在 TON 上的落账方式（Jetton 转账 / 金库合约）
- [x] **Tolk 编译验证通过**：GitHub Actions (`ton-build.yml`) 用 Acton 1.2.0 编译 `planet_core.tolk` 成功（本地 WSL 可选）。已修：Acton.toml manifest、`in` 作用域、`Storage.load/save`、message opcode、`int64` 定宽字段。
