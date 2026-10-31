# 大客户获客包 — 2026-10

目标：把 PPI 指数卖进"已经在做永续/商品/RWA"的场所，而不是向零售推销。B2B 一轮 10 家，
每家只要一个角度，不群发。

## 一、目标清单（按匹配度排序）

| # | 对象 | 为什么是它 | 切入点 |
|---|---|---|---|
| 1 | **Ostium**（链上商品永续） | 已经在做商品永续，价格源是它的命门 | "你结算所用的商品价格，能告诉你的清算引擎数据何时变坏吗？" |
| 2 | **GMX**（Arbitrum） | 同链、同枢纽、多市场架构，指数是第 N 个市场 | "新增一个 14 商品指数市场，价格源带风控分级" |
| 3 | **Vertex**（Arbitrum） | 同上，机构向 | 指数永续作为差异化市场 |
| 4 | **Drift**（Solana，跨链扩展） | 多链部署意愿强 | 跨链指数（预言机是拉取式，天然跨链） |
| 5 | **Synthetix / Kwenta** | 合成资产老牌，商品是空白 | 商品篮子合成敞口 |
| 6 | **Hyperliquid** | 上币严格但流量最大 | 不作为第一轮；先积累记录 |
| 7 | **Wintermute / Keyrock**（做市商） | 他们才是 LP 的答案 | "池子需要第一笔 $100k–1M 的做市资金，分成谈" |
| 8 | **DefiLlama / Dune** | 不是客户，是分发 | 上架指数与 TVL 面板 = 免费曝光 |
| 9 | **Arbitrum 生态/DAO** | 资助 + 背书 | 已有 grant 申请文档，补链上记录后提交 |
| 10 | **RWA 协议（Backed / Ondo 生态）** | 商品 RWA 是下一个叙事 | 指数作为 RWA 商品的定价参考 |

## 二、冷邮件（300 字，直接发创始人/BD）

> Subject: A commodity index that flags bad data before it liquidates your users
>
> Hi [name],
>
> Your perp markets settle on price feeds. When a commodity feed goes stale or prints a wick, the
> liquidation engine has no way to know — it treats a bad print exactly like a real move.
>
> We run a 14-commodity index on Arbitrum One that publishes data quality as a first-class field:
> every asset carries a state (normal / caution / frozen), every update is 2-of-3 signed, and the
> settlement source rejects a core where a single key can move the price. A venue can raise margin
> or block new positions *before* a bad print cascades.
>
> Live contracts (verified, Arbitrum One): core 0x61de…cbbb, oracle 0x0daf…1824, methodology at
> https://ppppp.space/methodology.
>
> Would a 20-minute call next week be useful? I can walk through the risk states and what integration
> looks like — read-only price source, no migration.
>
> [name]
> Planet

## 三、一句话电梯稿（当面/语音用）

> "别的场所给你一个价格数字。我们给你一个价格，外加'这个数据现在可不可信'——你的保证金可以
> 在坏价打穿用户之前先反应。14 个商品、2-of-3 签名、Arbitrum 主网已上线、合约已验证。"

## 四、发送纪律

- 每天最多 3 封，逐封改第一段（引用对方最近的一条产品动态）
- 不要提"审计中"——只说"自审报告公开在仓库，外部审计在预算内"；被追问时给审计文档链接
- 第一批只求回复率，不求成交；回复了就先约 20 分钟，不急着报价
- 记录到 `docs/outreach/log.md`：日期 / 对象 / 版本 / 回复 / 下一步

## 五、必须先补的三块（否则邮件发出去也白搭）

1. **指数历史记录**：每天快照 → `docs/data/ppi/`（公开可查，7 天起算）
2. **一个公开的验证页**：`/ppi` 已经是；再加 JSON-LD Dataset，让 AI 搜索能引用
3. **第一笔真实 LP**：哪怕 $1,000 —— 邮件里"live"才站得住
