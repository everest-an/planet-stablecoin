# Planet 合约审计报告（内部自审 · 类型全覆盖）

> 范围：`ton/contracts/`（`planet_core.tolk` · `signed_price.tolk` · `oracle_state.tolk` · `limits.tolk` ·
> `planet_timelock.tolk` · `planet_bond.tolk` · `jetton/*`）。
> 方法：按**类型**逐项审查（访问控制 / 算术溢出 / 状态一致性 / 预言机与签名 / 经济 / 输入校验 /
> DoS / TON 特有语义）。**这是内部自审，不能替代第三方审计**（见 `docs/mainnet-readiness.md` A6）。
>
> 严重度：🔴 Critical · 🟠 High · 🟡 Medium · ⚪ Low/Info · ✅ 良好实践

---

## 1. 访问控制（Access Control）

| # | 级别 | 发现 | 位置 | 建议 |
|---|---|---|---|---|
| AC1 | ⚪ | 所有 owner 动作统一 `assert(sender == owner)` | core 各 handler | ✅ 一致，良好 |
| AC2 | 🟡 | **`SetOwner` 无零地址校验** → owner 可被设为 `0`，合约永久无 owner 动作（自锁死） | `handleSetOwner` | `assert(newOwner != <zero>)`；或走 timelock 两步 |
| AC3 | 🟡 | **`SetThreshold` 无上界**：可设 `m > signerCount` → 推价永远无法满足 → 自 DoS | `handleSetThreshold` | `assert(m >= 1 && m <= os.signerCount)` |
| AC4 | 🟡 | **`SetSigner` 允许非连续 index**：只注册 index=5 → signerCount=6，槽 0–4 缺失 → 见 OR1（DoSing 推价） | `handleSetSigner` | 见 OR1 修复 |
| AC5 | ✅ | 未知 opcode → `else => throw 0xFFFF` | `onInternalMessage` | ✅ |
| AC6 | ✅ | `BurnMirror` 仅接受 jettonMinter；`CamUpdate` 仅接受注册 CAM；`OracleUpdateAssetPrice` 仅接受 oracle | 各 handler | ✅ |

## 2. 算术与溢出（Arithmetic）

| # | 级别 | 发现 | 位置 | 建议 |
|---|---|---|---|---|
| AR1 | ✅ | 铸赎数学中间量 widen 为 257-bit `int`，避免 int64 溢出 | `mintAmount*`/`burnAmount*` | ✅ |
| AR2 | 🟠 | **`handleBurnMirror` 的 `totalReserve -= received` 可下溢**（仅校验 supply，未校验 reserve）→ 储备记账被破坏（变巨大正数） | `handleBurnMirror` | `assert(storage.totalReserve >= received)` |
| AR3 | 🟡 | **赎回费无上界**：`burnFeeBpsForPpi` 在 PPI 极低于锚时可能 > 10000bps → `gross*(1-f)` 为负 → `totalReserve` 反向增大 | `burnAmountAtPpi` / `handleBurnMirror` | 对费率 clamp（如 `<= 2000`），或赎回也做 band-freeze 检查 |
| AR4 | ⚪ | `feeSplit` 余数归 staking，无 dust 问题 | `feeSplit` | ✅ |
| AR5 | ⚪ | `computePpi` 分母为 0（全 frozen）回退 1.0 | `computePpi` | ✅ 有意为之 |

## 3. 状态一致性 / 异步（State & Async — TON 语义）

| # | 级别 | 发现 | 位置 | 建议 |
|---|---|---|---|---|
| SC1 | 🟠 | **铸造不回滚**：Core 先 `totalSupply/totalReserve +=`，再异步请求 minter 铸币；若 minter 拒绝/退回，core 已记账但代币未铸 → **供应记账漂移** | `handleMint` | 两阶段（确认后记账）或依赖 minter=Core 管理 + 链下对账告警 |
| SC2 | ✅ | 赎回镜像由 minter 回写（`BurnMirror`），以 minter `totalSupply` 为真相源 | `handleBurnMirror` + jetton | ✅ 设计正确 |
| SC3 | ⚪ | TON 无 EVM 式重入；状态先 `save()` 再发消息 | core | ✅ |
| SC4 | 🟡 | `handleCamUpdate` 用 `cams.mustGet(index)` **早于** `index < assetCount` 检查 → 未注册时抛通用错误而非 `ERR_BAD_INDEX` | `handleCamUpdate` | 调整校验顺序 / 用 get+isFound |

## 4. 预言机与签名（Oracle & Signatures）

| # | 级别 | 发现 | 位置 | 建议 |
|---|---|---|---|---|
| OR1 | 🟡 | **签名者槽位空洞 → DoS**：验证循环用 `signers.mustGet(si)`（si∈[0,signerCount)）；若 owner 非连续注册，`mustGet` 抛出 → **所有签名推价失败** | `handleSignedPriceUpdate`(N) | 用 `get`+`isFound` 跳过空槽；或在 `SetSigner` 强制连续 |
| OR2 | ✅ | M-of-N 要求**互不相同**的签名者（bitmask 去重） | `handleSignedPriceUpdateN` | ✅ |
| OR3 | ✅ | 时间戳严格单调（防重放）+ 单次 50% 跳变护栏 | `applyOraclePayload` | ✅ |
| OR4 | 🟡 | **遗留 `handleUpdatePrice`（owner）直接写 `currentPpi`，绕过篮子/band/跳变护栏** | `handleUpdatePrice` | 移除，或仅允许 `!baseLocked` 时使用 |
| OR5 | ⚪ | 签名更新任何人可转发（真实来源是签名） | `handleSignedPriceUpdate` | ✅ 设计正确 |
| OR6 | ⚪ | `SignedPriceUpdateN` 的 `n`(uint8) 未设上界 → 理论 gas 放大（攻击者自付） | core N-handler | 可加 `n <= signerCount` 之类软限 |
| OR7 | ⚪ | CAM 可传任意 volatility/liquidity（影响 RTRA 阈值），CAM 为受信 | `handleCamUpdate` | 受信，可加 clamp |

## 5. 经济 / 业务（Economic）

| # | 级别 | 发现 | 位置 | 建议 |
|---|---|---|---|---|
| EC1 | 🔴 | **铸造无真实价值背书**：`Mint.amount` 是**消息体字段**，实际只把 `msgValue`(TON) 转发给 minter；`totalReserve += amount` 是**虚构记账** → **可凭空铸币**、供应无抵押 | `handleMint` | 阶段一 PoC 的 "mock accounting"；**上主网前必须**改为托管真实资产（USDC/RWA）或明确禁止 |
| EC2 | 🟡 | 阶段一定位应在前端/白皮书**更醒目**标注（App 写 "deposit USDC" 易被误解为真实入金） | app/web | 文案加 "testnet · mock" |
| EC3 | ✅ | 费率分档（30/50/20 + 10% 风险基金）、风险基金抽成、套利返利、赎回非对称费 | core | ✅（v1.6 调整比例，见 WHITEPAPER） |
| EC4 | ⚪ | 熔断仅约束**铸币**（`BAND_FREEZE`），赎回不冻结（配合非对称费） | `handleMint` | 设计选择，记录即可 |

## 6. 时间锁（Timelock）

| # | 级别 | 发现 | 位置 | 建议 |
|---|---|---|---|---|
| TL1 | ✅ | `Propose→delay→Execute→Cancel` + `now()` 门限；owner 可设多签 = M-of-N + 延迟 | `planet_timelock.tolk` | ✅（SetOwner 往返已链上验证） |
| TL2 | 🟡 | `handleExecute` **先 `out.send` 再清 pending**：若发送失败/回滚则 pending 不清（链上曾观察到 gas 不足时残留） | `handleExecute` | 先清 pending 再发送，或拆分 |
| TL3 | ⚪ | `TlSetDelay` 无上界（owner 自设） | timelock | owner 自担 |

## 7. 输入校验（Input Validation）

| # | 级别 | 发现 | 位置 | 建议 |
|---|---|---|---|---|
| IV1 | ✅ | `SetBasketAsset` 校验 `basePrice > 0`；篮子权重在每次推价时校验 `sum == 100%` | core | ✅ |
| IV2 | ⚪ | `CamUpdate` 的 `riskState` 未限 0/1/2（>2 视为非 frozen，会进 PPI） | `handleCamUpdate` | `assert(riskState in {0,1,2})` |
| IV3 | ⚪ | `SetArb` 的 `rebateBps` 未限 ≤ 当前费率（>费率时被 clamp 到 0，安全） | `handleMint` | ✅ 已 clamp |

## 8. TON 特有语义

| # | 级别 | 发现 | 位置 | 建议 |
|---|---|---|---|---|
| TN1 | 🟠 | 消息带 `bounce` 时失败会退回；但 `handleMint` 已改状态，**退回不自动回滚** → 见 SC1 | core | 两阶段 / 对账 |
| TN2 | ⚪ | 存储 ref 使用正确（oracle/limits/map 放 ref，主 cell 未超 1023 bit） | core | ✅ |
| TN3 | ⚪ | `SEND_MODE_PAY_FEES_SEPARATELY` + 明确 forward ton，gas 语义清晰 | core | ✅ |
| TN4 | ⚪ | Getter 用 `mustGet`，未设时抛错（前端已 try/catch） | core | ✅ |

---

## 9. 结论与优先级

**✅ 基础扎实**：访问控制一致、算术 widen、未知 opcode 拒绝、多源+M-of-N+护栏+时间锁。

**上线前必修（按优先级）**
1. 🔴 **EC1** 铸造需真实资产背书（或明确 PoC 边界）——**主网硬门槛**。
2. 🟠 **SC1/TN1** 铸造两阶段/对账，消除异步漂移。
3. 🟠 **AR2** 赎回 reserve 下溢断言。
4. 🟡 **OR1/AC3/AC2** 签名槽空洞 DoS、threshold 上界、SetOwner 零地址。
5. 🟡 **OR4** 移除遗留 `UpdatePrice` 旁路；**AR3** 赎回费 clamp；**TL2** 先清 pending。

**建议**：以上修复后跑第三方审计（Halborn/Certora 类）+ 形式化（PPI 数学/铸赎/镜像不变量）。当前**不建议上主网**。

> 复现：`ton/contracts/tests/*.tolk`（108 测试 / 90.2%）。本报告的每条建议应配一个回归测试。
