# 近年智能合约安全事故分析 × Planet 自查

> 目标：把 **2022–2025 常见攻击类型**逐类对照 `ton/contracts/`，判断我们是否有同类漏洞。
> 关联：`docs/audit-report.md`（逐条审计）、`docs/security.md`（威胁模型）。**非替代第三方审计。**
> 依据：TON 官方安全文档（Security best practices）、TEP-74 审计要点、公开事故复盘。

---

## 0. 方法论

1. 归纳**攻击根因类型**（不是个案），每类举 1–2 个真实事故 + 损失。
2. 对每类标注我们的**现有控制**、**残余风险**、**是否可被同类手法命中**。
3. TON 与 EVM 语义不同（异步消息、bounce、地址派生），单独一节。

图例：✅ 已缓解 · 🟡 部分/需运营配合 · 🔴 命中（已修/待修）

---

## 1. 访问控制与密钥泄露（Access Control / Key Compromise）

| 事故 | 损失 | 根因 |
|---|---|---|
| Ronin Bridge (2022) | ~$624M | 验证者私钥被攻陷（5/9 签名泄露） |
| Harmony Horizon (2022) | ~$100M | 多签私钥泄露 |
| Orbit/各类 Bridge | 多起 | 单点管理钥 |

**我们的控制**：所有 owner 动作 `assert(sender == owner)`；`SetOwner` 可迁移到 **TON 多签钱包**；`PlanetTimelock` 提供 `Propose→delay→Execute`（延迟反应窗口）。
**残余风险**：🟡 目前 owner 仍是**单钥**（测试网）。**主网必须** 多签 + 时间锁 + 密钥分离（部署钥 ≠ relayer 钥）。
**结论**：**命中但已被合约层缓解**；组织层需补（见 `mainnet-readiness.md` B1/B2）。

## 2. 签名验证与重放（Signature / Replay）

| 事故 | 损失 | 根因 |
|---|---|---|
| Wormhole (2022) | ~$326M | 签名验证被绕过（未校验 guardian set） |
| Nomad (2022) | ~$190M | 验证逻辑错误 → 人人可伪造 |
| Poly Network (2021) | ~$611M | 跨链验证缺陷 |

**我们的控制**：`isSignatureValid`（ed25519）+ **M-of-N 互异签名者**（bitmask 去重）+ 时间戳严格单调（防重放）。
**本次深挖发现**：
- 🔴 **NEW-2 无域分隔**：`hash = payload.hash()` 仅含 payload，**未绑定合约地址/链** → 复用同一签名钥的**不同部署**可被**跨合约重放**。（TON 文档明确要求"把接收方/上下文并入被签名数据"。）
  → **已修**：新增 `priceHash()` = `domain tag(0x504C4E54) + core.address + payload`，relayer/测试同步；回归测试通过。
- ✅ 时间戳单调（单合约内）防同合约重放。
**残余风险**：🟡 同一签名钥跨链（testnet/mainnet）复用仍会重放——需**每链独立签名钥**（运营）。

## 3. 预言机/价格操纵（Oracle Manipulation）

| 事故 | 损失 | 根因 |
|---|---|---|
| Mango Markets (2022) | ~$114M | 用自有资金拉抬抵押品价格 |
| Euler (2023) | ~$197M | 缺健康检查 + 可操控捐赠 |
| bZx / Cream | 多起 | 单一 DEX 现货价被闪电贷操纵 |

**我们的控制**：**链下签名**多源（Yahoo+Sina，取**中位数**）+ **M-of-N** + **单次 50% 跳变护栏** + **源偏离 >2% 自动 frozen（排除出 PPI）**。**不读链上 DEX 现货价** → 闪电贷操纵无着力点。
**残余风险**：🟡 若 relayer 私钥被窃且阈值=1，仍可推价（但受 50% 跳变 + 熔断限制）。主网应 **3-of-5 多源**。
**结论**：**基本免疫**常见闪电贷型操纵；密钥与阈值是重点。

## 4. 逻辑/校验错误（Logic & Validation）

| 事故 | 损失 | 根因 |
|---|---|---|
| NutDAO/多次 | 多起 | 缺 `baseLocked`/边界校验 |
| 各类 | — | 未校验输入、状态机错误 |

**我们的控制**：`SetBasketAsset` 校验 `basePrice>0`；权重在推价时校验 `sum==100%`；`CamUpdate` 校验 `riskState∈{0,1,2}`（本次修）；`SetThreshold` 校验 `1≤m≤signerCount`（本次修）；`SetOwner` 拒绝零地址（本次修）。
**残余风险**：⚪ 低。

## 5. 整数溢出/下溢（Integer）

**我们的控制**：Tolk 运行时为 **257-bit**，中间量 widen；定点 1e6。
**本次发现并修**：
- 🟠 **AR2** `totalReserve -= received` 可下溢 → 已加 `assert(reserve >= received)`。
- 🟠 **AR3** 赎回费无上界 → 极端 PPI 下 `gross*(1-f)` 为负 → 已 clamp 费率 ≤ 20%。
**残余风险**：⚪ 低。

## 6. 重入（Reentrancy）

RON/Curve Vyper (2023, ~$70M) 等为 **EVM 独有**（同步调用 + 回调）。
**TON 无同步重入**：消息异步、无回调；状态先 `save()` 再发消息。**不适用**。
**但** TON 有**异步部分执行**风险（见 §7 TON-3），我们已识别（SC1）。

## 7. TON 特有（关键差异化）

来源：TON 官方《Security best practices》+ TEP-74 审计要点。

| # | TON 陷阱 | 我们 | 说明 |
|---|---|---|---|
| TON-1 | **sender 伪造**：信任 body 里的地址（如 `transfer_notification`）而不重算来源地址 | ✅ | PlanetCore 不接收 jetton 通知；**JettonMinter 校验 burn 来源 = 派生钱包地址**、mint 来源 = admin |
| TON-2 | **bounce 处理**：bounce 未处理 → 记账与实际漂移/误把 bounce 当命令 | 🔴→✅ | **NEW-1（本次修）**：Core/Bond/Timelock 新增 `onBouncedMessage`（忽略），杜绝畸形 body 被当命令解析（含回归测试） |
| TON-3 | **异步部分执行 / 中间人**：跨消息属性不保证 | 🟠 | 铸造先记账后异步铸币；minter 失败不自动回滚（SC1）。缓解：两阶段/对账告警（待） |
| TON-4 | **签名消息被 front-run**：mempool 可见，签名可被抢用 | ✅ | 我们的签名**不转移资金**（只更新价格）；且域分隔后不可改收件人 |
| TON-5 | **账户销毁**（`SEND_MODE_CARRY_ALL_BALANCE\|DESTROY`）竞态 | ✅ | 未使用该模式 |
| TON-6 | **无条件 ACCEPT 外部消息** → 耗尽余额 | ✅ | 合约均**无外部消息入口**（仅 internal） |
| TON-7 | **不稳定随机数** | ✅ | 未使用随机 |
| TON-8 | **避免无界数据结构** | ✅ | 循环受 `assetCount`/`signerCount`/`n(≤255)` 约束 |
| TON-9 | **gas/excess 返还** | ⚪ | 未返还 excess（余额累积）——非安全，优化项 |

---

## 8. 本次深挖的新发现（已全部修复）

| 编号 | 级别 | 问题 | 修复 | 验证 |
|---|---|---|---|---|
| **NEW-1** | 🟡 | 核心合约未拒绝 **bounced** 消息（Jett莫 Wallet 之外），畸形 body 可被当命令解析 | 加 `onBouncedMessage`（Core/Bond/Timelock） | `test bounced mint is ignored` |
| **NEW-2** | 🟡 | 签名**无域分隔** → 跨部署重放 | `priceHash = tag + core.address + payload` + relayer/测试同步 | 全部签名测试（域分隔后仍通过） |

> 另：本次修复的 AR2/AR3/OR1/OR4/AC2/AC3/IV2/TL2 见 `docs/audit-report.md`。
> **合计**：8（原审计）+ 2（深挖）= **10 项** 已修复并回归，**116 测试 / 90.1%**，CI 绿。

---

## 9. 结论

- **常见大规模事故的主因（访问控制/密钥、签名重放、预言机操纵、逻辑/整数）**我们都已针对性设防，且本次深挖补齐了 **TON 特有的 bounced 处理** 与 **签名域分隔** 两处。
- **最大残余风险不在合约代码，而在运营与外部**：
  1. 🟡 owner/relayer **单钥** → 主网必须多签 + 时间锁 + 密钥分离；
  2. 🟠 **异步铸造不回滚**（SC1）→ 两阶段/对账；
  3. 🔴 **铸造无真实背书**（EC1，PoC 设计）→ 主网前必须接真实资产/托管；
  4. ⬜ **未过第三方审计**——**这是主网分界线**。
- 建议：以上落地后，交由第三方（Halborn/Certora 类）+ 形式化（PPI/铸赎/镜像不变量）。
