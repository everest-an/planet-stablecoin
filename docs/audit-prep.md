# 审计准备包（Audit Prep Pack）

> **用途**：让第三方审计**确认**设计，而不是**重新发现**问题。
> **状态**：testnet v1.8 已部署并验证（地址见 `HANDOFF.md` 的 v1.8 段落）。
> **配套**：`contract-review.md`（本轮 10 项发现与修复）、`adr/0001-immutable-core-upgradeable-oracle-adapter.md`（升级模型）。

---

## 1. 范围

**在范围内（需审计）** —— `ton/contracts/` 的 Tolk 合约：

| 合约 | 职责 |
|---|---|
| `planet_core.tolk` | 篮子 / 链上 PPI / 铸赎 / 费率 / 风控 / 签名价格校验 / Jetton 接线 |
| `planet_timelock.tolk` | owner 提权的时间锁（Propose → delay → Execute） |
| `planet_gov.tolk` | PLTG 质押 / pro-rata 费用分红 / 质押加权参数投票 |
| `planet_bond.tolk` | 稳定债券（订阅 / 请求赎回 / 运营结算） |
| `planet_fund.tolk` | TEP-74 份额的接收与销毁（无托管赎回） |
| `jetton/*.tolk` | PLT TEP-74（vendored，含 `ChangeMinterAdmin` / `ChangeMinterContent`） |
| `signed_price.tolk` / `oracle_state.tolk` / `limits.tolk` / `burn_mirror.tolk` | 载荷编码 / oracle 状态 / 风控限额 / 赎回镜像 |

**范围外（明确）**：`planet_core.tact`（旧 Tact PoC，仅参考）、`legacy-solana/`（算法参考，不维护）、`relayer/`、`web/`、`app-tg/`（非托管、不持私钥，仅构造交易）。

---

## 2. 架构与不变量（Invariants）

**这些是"必须恒成立"的命题 —— 审计请逐条证伪。**

- **I1** 每次价格更新前后，篮子权重之和恒为 `1e6`（`applyOraclePayload` 断言）。
- **I2** 任一资产权重 ≤ `maxAssetWeight`（15% = `150000`）。
- **I3** 基价在 `LockBasePrices` 后不可改；`basePrice > 0`。
- **I4** `computePpi` = 对**未冻结**资产的加权均值（按活跃权重**重归一化**）；**无活跃资产时返回 0**（C-1 修复）。
- **I5** `Mint` 需满足：全局 oracle 新鲜度 ≤ `MAX_ORACLE_AGE`（6h）**且** 指数有定义（`currentPpi > 0`，否则 `ERR_NO_ACTIVE_ASSETS=123`）。
- **I6** 每笔费用按 **BURN 30% / RESERVE 50% / staking 20% + 10% 风险基金** 记账，无泄漏；三桶 + 风险基金可对账。
- **I7** 所有特权操作（篮子 / 限额 / 费率 / oracle 地址 / 签名者 / owner / 暂停）**仅**接受 `owner`。
- **I8** 时间锁上的 owner 变更**只能** `Propose → delay → Execute`（TL-1 自我限定发送者）。
- **I9** 债券 `totalIssued ≥` 每条 `face`；结算**恰好一次**（BD-3）。
- **I10** 签名价格需 ≥ `threshold` 个**互不相同**的有效签名者；覆写某槽位即**撤销**原密钥。

---

## 3. 信任模型 / 威胁模型

| 角色 | 持有 | 能做什么 | 不能做什么 |
|---|---|---|---|
| **用户** | 自己的私钥 | 铸 / 赎 / 质押 / 投票 / 转账 | —— 协议不自持私钥，**永远由用户签** |
| **热签名密钥**（relayer） | `RELAYER_MNEMONIC` | 只能**推送价格**（链上校验：签名 / 单调时间戳 / 权重和 / 偏离带 / 冻结） | 动不了 owner 权、参数、资金 |
| **owner** | 时间锁的 owner | 过 `Propose → delay → Execute` 后改参数 | **无法绕过 delay**；测试网 60s，生产应为**多签 + 24h+** |
| **oracle 适配层** | （待建，零资金） | 喂价 | 不托管价值 |

**攻击面优先级（审计重点）**
1. **owner 密钥被盗**：全权、但受 delay 约束 —— **delay 窗口即退出窗口**，这是唯一防线（生产必须加长 + 多签）。
2. **热密钥被盗**：仅能推价，且被偏离带 / 冻结 / 权重 / 6h 新鲜度限幅 —— 请评估"在限幅内能造成多大偏差"。
3. **签名载荷可被任意人转发**：靠**严格单调时间戳**（`timestamp > lastOracleUpdate`）防重放 —— 请评估窗口期抢跑。

---

## 4. 发现登记册（Findings Register）

### 4.1 已修（本轮，均已上链 + 有回归测试）

| ID | 严重度 | 问题 | 修复 |
|---|---|---|---|
| **C-1** | 高 | 全资产冻结时 PPI 回落 1.0 ⇒ 可按伪指数铸币 | `den==0` 返回 0 + 铸币断言 `currentPpi > 0` |
| **TL-1** | 中高 | 时间锁 owner 直改绕过 delay | 仅接受时间锁自身为发送者 |
| **TL-2** | 中 | Execute 用 NoBounce，内层失败静默 | 改为可弹回 |
| **TL-3** | 中 | delay 可被重置为 0（等于取消反应窗口） | `N→0` 拒绝（`0→N` 允许） |
| **GV-1** | 中 | 投过票即可立即撤资（有票无风险） | 提案未结束前锁仓（`ERR_VOTE_LOCKED=411`） |
| **GV-3** | 低 | 提案无门槛 ⇒ 可刷屏 | 需持 ≥1% 已质押量（`ERR_PROPOSAL_THRESHOLD=412`） |
| **BD-1** | 高 | 赎回即置位却**不付款** ⇒ 误点毁债权 | 拆为**请求**（用户）+ **运营结算**（owner） |
| **BD-2** | 低 | premium 无上界 | 限 `0 ≤ premiumBps ≤ BPS_DENOM` |
| **BD-3** | 低 | `totalIssued` 可能下溢 | 断言 `totalIssued ≥ face` |
| **BK-1** | 低 | 空壳 Basket 误导 | 标注弃用 + 从站点移除 |

### 4.2 有意保留（设计决策，请在审计中挑战）

| ID | 说明 | 为何不简单修 |
|---|---|---|
| **C-2** | 赎回镜像（burn mirror）无新鲜度护栏，与铸币**不对称** | 镜像来自 minter、PLT 已销毁；拒绝会造成 **core 与 minter 供应不同步** ⇒ 需专门设计 |
| **C-3** | `feesToBurn` 桶**仅记账**，链上无真实销毁动作 | 属经济/流程问题，非合约行为；已在文档如实标注 |
| **GV-2** | 提案**不链上执行**（咨询性质） | 有意：当前治理只表达意见，不自动改参数 |

### 4.3 加固待办（非急迫，见分析）

| ID | 说明 | 严重度评估 |
|---|---|---|
| **H-1** | 陈旧度是**全局**的（`lastOracleUpdate`），希望改为 **per-asset** | **低**：需要一份"新鲜但未上链"的签名才能抢跑，窗口仅 relayer 本轮 ~60s，其余资产最多陈旧数分钟 ⇒ 经济影响可忽略。仍建议下一版做 |
| **H-2** | 合约会**永久困住附带 TON**（旧 Core 曾积 1.63 TON） | **低**：金钱损耗非安全；建议下一版降低附带值 + 加 owner 扫出 |
| **H-3** | `PlanetFund` 尚未接线、owner 仍是旧时间锁 | **信息级**：当前无资金、无用户 |
| **H-4** | 签名者 `threshold = 1`（M>2 已支持但未启用） | **信息级**：生产应提至 2 以上 |

---

## 5. 测试与证据

- **单元/集成**：**239 测试 / 19 文件**，覆盖率 **95.9% 行 / 85.1% 分支 / 91.8% 评分**（CI 门槛 90，只升不降）。
- **CI**：`.github/workflows/ton-build.yml`（Acton build + test + coverage）；`ton-deploy-dryrun.yml`（**emulation 预检部署脚本**）。
- **链上验证（v1.8，实测）**：`assetCount=14`、`baseLocked=true`、`signerAt(0)=热密钥`、`owner=新时间锁`、14 资产价格上链并回读一致、`/api/v1/oracle` → `healthy=true / fresh=true`。
- **可复现**：`docs/deploy-runbook.md`（部署顺序、地址刷新清单、验证清单）。

---

## 6. 已知边界（诚实披露）

- **PoC 阶段**：链上**合成指数代币**，**不含真实大宗商品储备**，**不是足额抵押稳定币**，**不是稳定币**。
- 无第三方审计、无多签、无 RWA 托管、无储备证明、无保险基金（风险基金为记账）。
- 测试网数字无价值。

---

## 7. 我们希望审计师回答的问题

1. `computePpi` 的重归一化 + 冻结排除，是否存在可被"操纵冻结状态"套利的路径？
2. 费率分档 + 偏离带 + 风险基金记账，是否会出现**桶与真实余额不一致**（配合 C-3）？
3. 签名价格载荷的**编码/域分离**是否存在歧义或跨类别重放？
4. 时间锁的 `dest`/`body`/`eta` 校验是否足以防止"提案后篡改目标"？
5. Gov 的 pro-rata 奖励（RPS 定点）是否存在**舍入套利**或可提取的尘埃？
6. Jetton 集成（mint ↔ burn mirror 对称性、C-2）在极端时序下的账目一致性？
7. **不可变 + 迁移**模型（ADR-0001）下，是否存在"必须热修"的残余风险？

---

## 8. 部署 / 升级模型

见 `adr/0001-immutable-core-upgradeable-oracle-adapter.md`：**核心不可变**、参数走时间锁治理、逻辑变更走**迁移（redeploy + 搬余额）** —— 因此本文件是审计的**起点**，审计结论应驱动**下一次部署**（而非补丁）。
