# 合约审查报告（Contract Review）

> 范围：`ton/contracts/` 自研合约（`jetton/*` 为 vendored，仅关注我们需处理的点）。
> 方法：**逐合约人工审查**（读源码 + 结合本会话实测行为），聚焦访问控制、异步/弹回、整数、签名重放、经济博弈、**静默失败**。
> 关联：`docs/mainnet-readiness.md`（A8 第三方审计）、`docs/security.md`、`docs/audit-report.md`。
> 状态：**内部审查（非第三方审计）**，用于把问题收敛到"第三方审计只需确认"的程度。

图例：🔴 高 · 🟠 中高 · 🟡 中/低 · ℹ️ 标签/清理

---

## 0. 摘要（先修这三个）

| 排名 | 发现 | 位置 | 状态 |
|---|---|---|---|
| 1 | **全冻结时 PPI 回落 1.0，且铸造照样通过** | `planet_core.computePpi` + `handleMint` | ✅ **已修**：`den == 0` 返回 **0**；`handleMint` 增加 `assert (currentPpi > 0) throw ERR_NO_ACTIVE_ASSETS(123)`。测试：`ppi is undefined when every asset is frozen`（纯函数）、`mint is rejected when the index is undefined`（部署）、并把旧测试 `ppi falls back…` 改为断言 **0** |
| 2 | **时间锁 `TlSetOwner` 立即生效**（且这是唯一能改 owner 的路径 → 我们的迁移命令此前不可用） | `planet_timelock.tlHandleSetOwner` | ✅ **已修**：只接受**时间锁自身**为发送者（即只能 `Propose→delay→Execute`）。测试重写为 `ownership changes only through propose + execute`（直接调用被拒 101 ✓ + 走流程成功 ✓） |
| 3 | **Execute 用 NoBounce，内层失败静默** | `planet_timelock.handleExecute` | ✅ **已修**：改为 `BounceMode.Only256BitsOfBody` → 失败会弹回（交易树可见，可重新提案）。⚠️ 待办：加 `lastBounced` 标记 + getter，让 `oracle-monitor` 能直接巡检 |

**已一并修**：`GV-1` 投票后撤资（`Unstake` 在"最近投过的提案未结束"前锁仓，`ERR_VOTE_LOCKED=411`，含"没投票者不受影响"的测试）· `BD-2` premium 上界 · `BD-3` `totalIssued` 下溢断言。

**验证**：CI 全绿 —— **238 测试 / 19 文件**，All files 95.9% 行 / 85.7% 分支 / 92.0% 评分。

**未修（有意留待或已记录）**：`BD-1`（bond 赎回不付款却置位 —— 接真钱前必改，已在合约注释与本文标注）· `C-2`（burn 镜像无新鲜度护栏，需权衡不同步风险）· `C-3`（burn 桶仅记账）· `TL-3`（delay 可为 0）· `GV-2/GV-3`（提案不链上执行 / 无提案门槛）· `BK-1`（PlanetBasket 空壳）。

> ⚠️ **重要**：以上修复**只在代码与 CI 里**，**尚未部署** —— 每个合约改动都意味着**新地址**，需要一次**批量重部署**（Core 新地址 + 重配 14 商品篮子 + 重注册签名者 + 时间锁 owner 迁移 + 全站地址更新）。


---

## 1. `planet_core.tolk`

### 🔴 C-1 全冻结 → PPI 回落 1.0 → 仍可铸币
```tolk
fun computePpi(...) {
    ...
    if (den == 0) { return PPI_SCALE; }   // 所有资产 frozen → 返回 1.0
}
fun handleMint(...) {
    assert (diffAbs(storage.currentPpi, PPI_SCALE) <= BAND_FREEZE) throw ERR_DEVIATION; // 1.0 必然通过
```
**影响**：14 个资产全部进入 `frozen`（例如两个数据源同时异常、源间价差普遍 >2%）时，指数**假装是 1.0**，而 `BAND_FREEZE` 只检查偏离 ≤15% → 直接放行 → 用户在"没有可靠价格"时按 1.0 铸币，储备/供应被错误记价。
**最小修法**：`den == 0` 时**不是**返回 1.0，而是让 `computePpi` 返回 0（或引入 `ppiValid: bool`），并在 `handleMint` 里 `assert (ppi 有效 && 有活跃资产)` → **数据全坏时拒绝铸币**（响亮失败）。同时给 `ppi()` getter/`/api/v1/oracle` 暴露"活跃资产数"以便监控。

### 🟡 C-2 burn 镜像没有新鲜度护栏（与铸币不对称）
`handleMint` 有 `MAX_ORACLE_AGE` 6h 护栏 ✓，`handleBurnMirror` 没有 ✗ → 陈旧价下的赎回会**错误扣减储备**。
**说明**：不能简单加同样断言 —— 镜像来自 minter（PLT 已销毁），拒绝会导致 **core 与 minter 供应不同步** ✗。**修法**：记录/告警而非拒绝（或对"过期镜像"单独记账并允许运营修正），并在文档标注。

### ℹ️ C-3 `feesToBurn` 只是累加，合约里没有任何销毁动作
"45% 回购销毁 / 30% 储备 / 25%（实为 30/50/20+10 风险金）" 中的 **burn 桶只做记账** ✗，真正的回购销毁是**运营动作**。
**修法**：文档/白皮书如实标注为"运营执行"，或在后端实现可验证的回购销毁流程。

### ℹ️ C-4 治理权重仍需"离线方法论"补齐
`GovernanceSetWeight` 只保证 ≤15% 且和 = 100% ✓，但**权重怎么定**（流动性/产量加权）没有链上约束 → 依赖 `docs/methodology.md`（已公开 ✓）与治理流程 ✓。可接受，但审计时应说明。

### ✅ 已确认良好
时间戳单调 + 50% 跳变护栏 + 域分离（`PRICE_DOMAIN` + 合约地址）+ 重名去重（bitmask）+ `SetSigner/SetThreshold` 校验（`m ≤ signerCount`）+ 非正金额拒绝 + `onBouncedMessage` 忽略弹回 + 治理操作 `owner-only` + basePrice 锁后不可改。

---

## 2. `planet_timelock.tolk`

### 🟠 TL-1 `TlSetOwner` 立即生效（绕过延时）
```tolk
fun tlHandleSetOwner(sender: address, msg: TlSetOwner) {
    assert (sender == storage.owner) throw TL_ERR_NOT_OWNER;
    storage.owner = msg.newOwner;   // 直接生效，无 Propose/delay
```
**影响**：当前 owner 可**瞬时**把 owner 交给任意地址 → 若 owner 密钥被盗，攻击者可立刻换 owner，**60s 反应窗口形同虚设**。
**附带发现（重要）**：因为 `handleExecute` 是**从时间锁自己**把 body 发回 `dest`，如果 `dest` 指向时间锁本身，`sender` 就是时间锁而**不是 owner** → 现有断言会失败 ✗ ⇒ **"通过时间锁改 owner"这条路径当前不可用**，`relayer.mjs settimelockowner` 因此是**坏的** ✗（本报告修正了此前的假设）。
**最小修法**：让 `tlHandleSetOwner` 接受 **时间锁自身** 作为合法发送者（即只允许"自我提案 + 延时执行"这一条路）：
```tolk
assert (sender == contract.getAddress()) throw TL_ERR_NOT_OWNER;  // 只允许经 Propose→Execute
```
这样 owner 变更**必须**走 60s 延时 ✓，且 `settimelockowner` 也随之可用 ✓。

### 🟠 TL-2 Execute 内层失败静默
```tolk
storage.hasPending = false;  storage.save();
val out = createMessage({ bounce: BounceMode.NoBounce, ... });   // 失败不弹回
out.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
```
**影响**：Core 拒绝该动作（例如参数非法 / 权限已变）时，**没有任何反馈**，`hasPending` 已清空 → owner 以为成功。
**最小修法**：改成**可弹回**模式（如 `BounceMode.Only256BitsOfBody`），并在 `onBouncedMessage` 里置 `lastBounced = true` + `lastBouncedAt = now`（新增 getter）→ 让监控（`oracle-monitor`）能发现"提案执行失败" ✓。

### 🟡 TL-3 `delay` 可被设为 0
`handleSetDelay` 只校验 `>= 0` ✓ → owner 可把延时改成 0 ✓（等于取消延时 ✗）。
**修法**：主网配置要求 `delay ≥ 86400`；可在合约里加一个下限常量（或至少在 runbook/监控里断言 `delay() > 0`）。

### ✅ 已确认良好
`Propose` 要求 `!hasPending`（防覆盖）+ `Execute` 校验 `now ≥ eta` + 清 pending 在发送**之前**（避免卡死，TL2 注释已说明）+ 所有入口 `owner` 校验 + 弹回体忽略。

---

## 3. `planet_gov.tolk`（PLTG）

### 🟠 GV-1 投票后立即撤资（vote-then-unstake）
`handleVote` 用**投票时刻的当前质押量**作为权重，**没有锁定期、也没有快照**：
```
staker：stake 1e6 → vote（权重记 1e6）→ unstake 全部（资金走人，票仍在）
```
**影响**：治理权重与实际风险脱钩 → 可"零成本投票"，也能对**多个提案**重复同样操作（`lastVote` 只防同提案重复）。
**最小修法（二选一）**：① 提案创建时**快照**该提案权重（需记录每个质押者的投票时点余额）；② 投票**锁定**质押到 `endTs`（类似 veCRV，最简：`unstake` 时校验"没有未结束的已投提案"）。

### 🟡 GV-2 提案只有计票，无链上执行
`Proposal.executed` 永远是 `false` ✓，执行靠链下（时间锁）。**影响**：治理是**咨询性质**，不是"通过即生效"。
**修法**：文档明确（现已在 `/docs`、`/methodology` 提及 ✓）；若要真执行，需把 `GovernanceSetWeight` 等权限交给治理合约（较大改动）。

### 🟡 GV-3 任意小额质押即可提案
`handlePropose` 只要求 `amount > 0` ✓ → 可刷提案 ✗。
**修法**：加提案门槛（如 `amount ≥ 某 bps of totalStaked`）。

### ✅ 已确认良好
奖励用标准 reward-per-share 累加器（`rewardDebt` 在 stake/unstake 时同步 ✓，不会丢已计收益 ✓）；`NotifyRewards` owner-only + `totalStaked > 0` ✓；`pendingOf` 只读 ✓；同提案重复投票被 `lastVote` 拦 ✓。

---

## 4. `planet_fund.tolk`

### 🟡 FD-1 `funded` 在 burn **之前**置位
`handleShareReceived` 先 `funded = true` 并 `save()`，再发 `AskToBurn`（`NoBounce`）→ 若 burn 失败，**赎回仍会放款**，份额未被销毁。
**影响**：份额仍留在基金钱包（**偿付性是中性的** ✓），但 `totalSupply` 未减少 → 供应与份额不一致。
**修法**：接受现状并在文档说明（已注明 ✓）；若要严格，改为**收到 BurnNotification 后再置 funded**（跨合约确认，复杂度上升）。

### ✅ 已确认良好
两阶段申购（**仅托管 M-of-N 确认后才铸**，修复 EC1）；NAV 单调 + 跳变上限 + 地板；TEP-74 收款校验 `sender == fundWallet` 且**排除自身**；未 funded 不放款（`ERR_NOT_FUNDED`）；`onBouncedMessage` 忽略。

---

## 5. `planet_bond.tolk`

### 🟠 BD-1 `Redeem` 不付款却把债权标记为已赎回
```tolk
fun handleRedeem(...) { ... storage.bonds.set(sender, BondRec{ ..., redeemed: true }); storage.totalIssued -= b.face; }
```
**影响**：**任何人都能对自己调用** ✓，调用即 `redeemed = true` ✗ 之后 `ERR_ALREADY_REDEEMED` → **用户一次误点就永久失去债权** ✗。测试网是 mock 记账 ✓，一旦接真钱即高危。
**最小修法**：付款与置位**顺序反转**（先付后置），或把 `Redeem` 改为 **owner/托管驱动**（用户只发起请求），或至少加"未付款不可置位"的显式不变量。

### 🟡 BD-2 `premiumBps` 无上界
`handleSetPremium` 不校验范围 → 可设成 >10000 → `face` 被无限放大 ✗。
**修法**：`assert (msg.premiumBps <= 10000)`。

### 🟡 BD-3 `totalIssued -= b.face` 潜在下溢
无 `assert (storage.totalIssued >= b.face)`；int64 下溢会翻成大正数 ✗。
**修法**：加断言。

### ℹ️ BD-4 独立账本、未与 Core 联动
`core` 字段只存不用 ✗；"PPI<0.95 自动开债"未实现 ✓（已在文档说明 ✓）。

---

## 6. `planet_basket.tolk`

### ℹ️ BK-1 空壳残留
真正的篮子归 **PlanetCore** ✓；`PlanetBasket` 是个注册表，**无人写入**（没有 `SetAsset` 调用 ✗），却在站点合约表被列出 ✗ → 误导。
**修法**：要么接线上链（部署脚本写入 + Core 读），要么从站点/文档移除并标注 deprecated。

---

## 7. 无法独立复核的项

- **Oracle 独立审查未完成**：本环境 `oracle` 子代理因模型配置错误（`anthropic/claude-opus-5` 不存在）启动失败 ✗ → 本报告为**单人会审**，第三方审计（A8）仍需购买 ✗。

---

## 8. 结论与建议顺序

**先修（本报告已给出最小修法）**：C-1（全冻结铸币）→ TL-1（owner 绕过延时，且修好才能用多签迁移）→ TL-2（静默执行失败）→ GV-1（投票后撤资）→ BD-1（债券误置位）。

**再补**：C-2/C-3 标注、TL-3、GV-2/GV-3、BD-2/BD-3、BK-1 清理。

**影响上线的性质**：这些多为"**静默失败**"与"**权限/博弈**"类问题 —— 与主网判定（A8 审计）直接相关；建议在购买第三方审计前先修完"先修"清单，让审计聚焦在验证而非发现。
