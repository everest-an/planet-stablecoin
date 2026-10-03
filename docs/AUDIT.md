# Planet 智能合约 — 可信任与审计清单（AUDIT）

> 目标：让「合约可被任何人独立验证」，而不是让人"相信项目方审计过了"。
> 对**无主体**项目，这是唯一的信任来源。
> 关联：`PLAN-TON.md`、`TON-MAPPING.md`、`GTM.md`

---

## 0. 信任模型（无主体版本）

传统项目靠"公司背书 + 审计报告"建立信任。无主体项目**没有主体可背书**，因此信任必须来自：

```
可验证性（verifiability） > 背书（attestation）
```

即：任何人能自行 **读到源码 → 复现编译 → 核对链上 code hash → 复算状态**，就不需要信任任何一方。

---

## 1. 信任阶梯（按优先级落地）

| # | 手段 | 作用 | 当前状态 |
|---|---|---|---|
| ① | **源码公开** | 任何人可读 | ✅ 仓库私有 → **待公开** |
| ② | **`acton verify` 链上验证** | 发布能复现 code hash 的源码，任何人编译核对 | ⬜ 待做（需部署后） |
| ③ | **可复现构建** | 确定性构建 → 本地编译得到同一 hash | ⬜ 待做（钉死 toolchain 版本） |
| ④ | **测试门禁** | 单元 + 集成 + 不变量 + fuzz + 覆盖率 | 🟡 部分（9 测试全过；缺不变量/fuzz/覆盖率门禁） |
| ⑤ | **权限最小化 / 无后门** | 核心逻辑无 owner 提款后门；管理操作走**多签 + 时间锁** | ⬜ 待做 |
| ⑥ | **第三方审计** | Halborn / Certora（加分项，非唯一信任来源） | ⬜ 白皮书声称，实际未做 |
| ⑦ | **漏洞赏金 + 储备证明** | 托管方 Merkle 证明，任何人复算 | ⬜ 待做 |
| ⑧ | **透明度** | 所有参数变更发链上事件，可追溯 | 🟡 部分（事件设计在 Solana 版有） |

---

## 2. 当前已具备（可核对的事实）

- **CI 三级门禁全绿**（`.github/workflows/ton-build.yml`）：
  - `Tolk (Acton)`：`acton build` + `acton wrapper --all` + `acton test`（9 个测试）
  - `TG Mini App`：`npm run build`
  - `Tact PoC`：`npm run build`
- **测试覆盖**（`ton/contracts/tests/`）：
  - 单元：`mintAmount` / `burnAmount` / `feeAmount` / `feeSplit`（45/30/25）/ `rebalanceDrift` / `shouldRebalance`
  - 集成：`PlanetCore` 部署 + getter 校验
- **工具链钉版本**：`Acton.toml` 钉 `acton = "1.2.0"`（利于可复现构建）

---

## 3. 待办清单（按顺序）

### 3.1 可复现构建（低成本、高信任）
- [ ] 钉死 `Acton` 版本（已钉）+ Rust/依赖版本
- [ ] 记录每个合约的 **code hash**（`acton build --info`）
- [ ] 在 README/CI 输出 hash，供第三方比对

### 3.2 链上验证（部署后）
- [ ] 部署 testnet 后执行：
  ```bash
  acton verify PlanetCore --address <ADDR> --wallet deployer
  acton verify JettonMinter --address <ADDR> --wallet deployer
  acton verify JettonWallet  --address <ADDR> --wallet deployer
  acton verify PlanetBasket  --address <ADDR> --wallet deployer
  ```
- [ ] 在 README 附验证链接

### 3.3 不变量 + 覆盖率门禁（下一步最优先）
- [ ] 不变量测试：
  - `PLT 供应量 ≤ 储备价值`（若接真实储备）
  - `Σw_i = 1e6`（权重恒为 100%）
  - `totalReserve`、`totalSupply` 单调性/边界
- [ ] `acton test --coverage --coverage-minimum-percent 80` 接入 CI
- [ ] fuzz（`@test.fuzz`）覆盖 `mintAmount`/`burnAmount`/`rebalanceDrift`

### 3.4 权限最小化 / 多签时间锁
- [ ] 审计 `owner` 权限点：`SetPaused` / `SetJettonMinter` / `SetAsset` / `UpdatePrice`
- [ ] 确认**无** owner 提款/铸币后门（铸币只能由 `Mint` 流程触发）
- [ ] 生产环境把 `owner` 迁移到 **TON 多签钱包**（如 Tonkeeper multi-sig / Safe-TON）
- [ ] 关键参数变更加**时间锁**（延时执行 + 事件）

### 3.5 第三方审计与赏金
- [ ] 接触 Halborn / Certora（白皮书声称的机构）做审计
- [ ] 设立漏洞赏金（Immunefi 等）
- [ ] 形式化验证：对 `PPI`、供应、抵押率写不变量证明

### 3.6 储备证明（若走向实物储备）
- [ ] 托管方每日提交 `total_value + holdings_hash`（见 `custodian.md`）
- [ ] 哈希对应 Arweave 明细，任何人可复算

---

## 4. 给审计方/用户的自查命令

```bash
# 1. 编译并打印 code hash（可复现核对）
cd ton && acton build --info

# 2. 跑全部测试
acton test

# 3. 覆盖率
acton test --coverage

# 4. 变异测试（验证测试有效性）
acton test --mutate

# 5. 静态检查
acton check
```

---

## 5. 一句话结论

> **审计报告不是信任来源；"任何人可独立编译 + 核对 code hash + 复算状态"才是。**
> 无主体项目应把信任建立在**可验证性**上，第三方审计只作补充。
