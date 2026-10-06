# 同类算法代币对比 + 商品篮子如何更新

> 目的：回答两个问题 ——（1）**我们的商品篮子可以更新吗？**（2）**和同类"算法/指数/篮子"代币相比，从逻辑合理性看该怎么更新？**
> 来源：Reserve Protocol 文档、Frax 官方文档（FPI/FXB/sFRAX）、Ampleforth 官方站（正文已抓取核对）；PAXG/商品指数部分为通用认知，已标注。
> 关联：`docs/WHITEPAPER.md` §0、`docs/plan-future` 内部契约 `docs/fund-contract-design.md`。

---

## 0. 一句话结论

- **篮子可以更新**：合约已内建治理级 `GovernanceAddAsset`（追加商品）与 `GovernanceSetWeight`（改权重，**不动 basePrice**），在 `baseLocked` 之后仍可调；由 **owner（你）签名**发起，owner 已/可迁移到**时间锁 + 多签**，所以"你签名 → 延时执行"。
- **更新逻辑**：参照 Reserve / FPI / 商品指数，建议从"拍脑袋权重"升级为 **规则化权重 + 季度再平衡 + 有上限 + 有应急通道**，并把权重变更交给 **PLTG 质押投票**（本轮已实现）。

---

## 1. 同类项目对比（按"最像我们"排序）

| 项目 | 定位 | 篮子怎么定义/更新 | 对标要点 |
|---|---|---|---|
| **Reserve Protocol（Index DTF / RToken）** | 多资产抵押稳定币 + 指数基金 DTF | 篮子 = 一组抵押资产 + **目标数量（权重）**；治理用 `setPrimeBasket`/`forceSetPrimeBasket` 增删/改权重；**Dutch auction**（CoW Swap/DEX）执行再平衡；抵押资产不合格时自动切 **backup basket**；治理=质押者投票（标准路径 2d 延迟+3d 投票+3d 时间锁，quorum 10%）+ **optimistic 路径**跑常规操作；**解除质押延迟必须长于治理周期** | 我们已有：owner→时间锁、PLTG 质押、basePrice 不可变。**缺**：目标权重与 backup/禁用资产切换、拍卖式再平衡、乐观治理路径 |
| **Frax FPI（Frax Price Index）** | **锚定"一篮子消费品"（US CPI-U）** 的稳定币 —— 与我们的"购买力"命题**最接近** | 篮子=CPI 一篮子；**Chainlink 预言机每月**（bls.gov 发布后）把 12 个月通胀率上链，**赎回价按秒累积**；维持 **100% CR**：AMO 收益须≥CPI，否则 **TWAMM 卖 FPIS→FRAX** 补足；**FPIS**=治理代币享铸币税；**Comptroller 多签**持有合约 | 我们：链上 PPI + 签名预言机 + 风险基金 + 债券，思路一致。**可借鉴**：以"某个官方指数"作为锚/对照、月度节奏、CR 概念、治理代币吸收波动 |
| **Frax 生态其他件** | — | **FXB**=零息债券（折价拍、到期兑 1 FRAX）≈ 我们的 `PlanetBond`；**sFRAX**=金库分周派协议收益 ≈ 我们的 PLTG 质押分红；**Fraxswap TWAMM** 用于再平衡 | 我们的债券/质押/再平衡方向与 Frax 一致，可对标其参数 |
| **Ampleforth（AMPL）** | **弹性供应**目标 CPI 调整后美元 | **改数量不改价**（rebasing），非稀释；官方强调"预言机被攻击也无法盗取资金"；治理代币 **FORTH**；2019 上线、长期回归目标 | 我们没走 rebasing（改价=PLT 市价自由浮动）。**可借鉴**：把"预言机风险"限定为不可盗取、治理代币化 |
| **PAXG / XAUT**（通用认知） | 1:1 实物黄金（托管+审计） | 篮子=单一资产，靠**托管 + 定期鉴证（PoR）**；无治理权重 | 这是**路线 A（真 1:1）**的形态：我们需要托管方 + PoR + 合规，非纯代码可解 |
| **商品指数（S&P GSCI / BCOM）**（通用认知） | 传统商品指数 | **规则化权重**（GSCI≈产量加权、BCOM≈流动性加权）+ **年度再平衡** + 展期规则 + 单品种/板块上限 | **最该抄的是"方法论"**：公开、可复算、有上限、有再平衡日历 |

---

## 2. 从逻辑合理性看：篮子"应该怎么更新"

### 2.1 能更新 vs 不该乱更新
- **能更新**：商品结构会变（新上市品种、流动性迁移、地缘断供），篮子必须可演进 —— 这正是白皮书 §2.2"每季度由 DAO 投票调整"。
- **不该乱更新**：**已上线资产的 basePrice 必须冻结**（否则 owner 可篡改 PPI 历史、凭空改锚）。我们的合约已强制：`GovernanceSetWeight` **只改 weight、不碰 basePrice**；`SetBasketAsset` 锁价后失效。✔ 这条与 Reserve 的"权重可调但抵押资产语义稳定"同源。

### 2.2 建议的更新规则（可落地）
1. **规则化权重**（替代拍脑袋）：
   - 方案 X：**全球贸易额/产量加权**（像 GSCI）——最能代表"购买力"，但数据需外部。
   - 方案 Y：**流动性加权**（像 BCOM）——最抗操纵、最好取数（成交量）。
   - 方案 Z：**等权 + 上限**——最简单、最透明。
   - **推荐先 Y/Z 起步**：用 relayer 已有数据源可得"日均成交额"→ 权重 ∝ 流动性，**单品种 ≤15%、单板块 ≤40%**。
2. **再平衡节奏**：**季度**（白皮书口径）+ **应急通道**（某品种数据源故障/停牌 → 该资产 `riskState=2 frozen`，自动剔除 PPI，等治理决定去留）。
3. **增删资产**：
   - **加**：`GovernanceAddAsset`（追加，不覆盖）✔ 已实现。
   - **删/停用**：当前 `GovernanceSetWeight` 要求 `weight>0`，**无法置 0 软下线** —— **建议放开"允许 weight=0"**（权重为 0 的资产不参与 PPI，实现软删除，避免重排索引这种高危操作）。
4. **治理路径**：权重/增删走 **PLTG 质押投票**（本轮已实现投票）→ 通过后由 **时间锁**执行 `GovernanceSetWeight`。这与 Reserve 的"质押者投票 + 时间锁"一致。
5. **上限与熔断**：沿用现有护栏 —— 单次推价跳变 >50% 拒；`|PPI-1|>15%` 拒铸；源间价差 >2% 冻结。

### 2.3 与"锚"的关系（重要）
- FPI 用**官方 CPI** 做锚、我们更像**自定义商品篮子指数（PPI）**。逻辑上二者不同：
  - FPI 的锚是"外部权威指数"→ 只需要**月度取数**，篮子本身不常改；
  - 我们的 PPI 是"自建篮子"→ **权重与成分就是产品本身**，因此**篮子的治理/方法论必须公开、可复算、有上限**，否则就是一篮子随意的币价平均，缺乏可信度。
- 结论：**把"篮子方法论"当作一级产品资产来治理**（公开文档 + 版本号 + 变更史链上可查，像 Reserve 的 `BasketSet` 事件）。

---

## 3. 落地清单（建议按序）

| # | 项 | 类型 | 依赖 |
|---|---|---|---|
| B1 | 放开 `GovernanceSetWeight` 允许 `weight=0`（软下线），并补测试 | 合约（小） | 纯代码 |
| B2 | 增加 `GovernanceRemoveLastAsset`？——**不建议**（重排索引风险高），用 B1 软下线即可 | — | — |
| B3 | 公开"篮子方法论 v1"文档（权重规则/上限/再平衡日历/变更史） | 文档 | — |
| B4 | 权重变更 → PLTG 投票通过 → 时间锁执行（串起本轮 PLTG + 时间锁） | 流程 | 部署后 |
| B5 | relayer 增加"日均成交额"输出，用于流动性加权 | 脚本 | 数据源 |
| B6 | 官网加"对比同类代币"区块（见 `web/index.html`） | 前端 | — |

> 其中 **B1** 是纯代码小改（可立刻做并 CI 验证）；**B3/B6** 本轮已给初稿。

---

## 4. 参考来源
- Reserve Protocol：`docs.reserve.org/core-components/index-dtfs/overview`、`github.com/reserve-protocol/protocol`（BasketHandler / BackingManager / recollateralization）
- Frax：`docs.frax.finance/frax-price-index/overview-cpi-peg-and-mechanics`（FPI 200%→100% CR、月度 CPI、TWAMM）、`docs.frax.finance`（FXB/sFRAX/veFXS）
- Ampleforth：`ampleforth.org`（rebasing、FORTH、oracle 风险表述）
- PAXG/XAUT、S&P GSCI/BCOM：通用认知（未逐条核对，落地前需复核）
