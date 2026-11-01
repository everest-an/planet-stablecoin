# 分发渠道清单（论坛 / 社群 / agent 入口）— 2026-11

原则：**先发"数据载体"（不用登录就能被爬、被引用），再发"人看的论坛"（要账号、有版规）。**
刷屏式推广会毁掉"数据可信"的定位——每一处发帖都必须带可验证的事实，不带形容词。

## A. 不用登录就能被逛到（优先级最高，发一次长期有效）

| 渠道 | 谁能看到 | 动作 | 状态 |
|---|---|---|---|
| **Hugging Face Datasets** | AI 研究员 + **agent 抓取** | 把 `docs/data/ppi/*.json` 发成数据集（dataset card + 每日更新） | 待建（需 HF 账号，免费） |
| **Kaggle Datasets** | 数据从业者 | 同上，CSV 版 | 待建（需账号） |
| **GitHub（已有）** | 开发者 + agent | README 已更新；可开 Discussions | ✅ 已在线 |
| **llms.txt（已有）** | LLM 爬虫 | 已上线 | ✅ |
| **Dune / DefiLlama** | DeFi 用户 + 分析师 | 按 listing-kit 提交（LP 到位后） | 已备好 |
| **MCP Registry（agent 工具目录）** | **AI agent** | 把 PPI API 包成一个 MCP server（`get_ppi`、`get_asset`、`get_risk`），发布到 Smithery/Glama/mcp.so | 待建（我可以写） |

**为什么这是重点**：agent 不需要账号、不会嫌广告、只认 schema。一个 MCP server + 一个 HF 数据集，
等于在所有 agent 的工具箱里放了一个"商品指数"入口——这是 2026 年最便宜的获客。

## B. 要账号、但值得发（一发一帖，价值优先）

### 1. Hacker News — Show HN（技术人群，流量大且质量高）
```
Title: Show HN: An on-chain commodity index that publishes data quality

Body:
We built a 14-commodity index (energy, metals, agriculture, industrial inputs) on Arbitrum One
where every asset carries a machine-readable risk state (normal/caution/frozen), every update is
2-of-3 signed, and the single-key path is disabled on mainnet.

The problem we started from: perpetual markets liquidate against a price feed, but a stale value or
a bad print is indistinguishable from a real move. So the index publishes the quality of its own
data, and a venue can raise margin before a cascade.

- Live index: https://ppppp.space/ppi
- Methodology: https://ppppp.space/methodology
- Contracts (verified): core 0x61de…cbbb
- Code + tests + self-audit: https://github.com/everest-an/planet-stablecoin

Not externally audited; the repo says so in several places. Happy to answer anything about the
oracle design or the TWAP liquidation gate.
```

### 2. Reddit — r/defi 或 r/CryptoCurrency（先读版规；r/defi 允许项目介绍，r/CC 会删）
与 HN 同文案，标题改：`A 14-commodity on-chain index that publishes data quality (not just price)`
**纪律**：先回 5 个别人的帖子再发自己的；flair 选 "Project/Research"。

### 3. X / Twitter（你有密钥）
一条主推 + 引用链：
```
A price feed that can't tell you when its data is bad is a liquidation engine waiting to happen.

We built a 14-commodity index on Arbitrum One where every asset carries a risk state
(normal / caution / frozen) and every update is 2-of-3 signed.

Live: ppppp.space/ppi
```
配图：/ppi 截图（含 risk 列）。**不写"革命性"、"颠覆"**。

### 4. Telegram / Discord 群（加密/大宗/黄金群）
只发**一条**，带数据截图和链接；发完退群或留观。别群发同一文案。

### 5. Farcaster / Mirror（Web3 原生，不需登录即可阅读）
把 /commodity-index 长文同步一份，链上署名。

## C. 不建议

- **4chan /biz、无账号匿名版**：能发，但受众与品牌不匹配，且会被截图当笑话
- **群发 DM / 拉人**：直接毁掉信誉
- **付费 KOL**：现在没产品数据支撑，钱花得冤

## D. 建议顺序（本周）

1. **HF 数据集**（我把 JSON 打包 + 写 dataset card，你上传；免费）
2. **MCP server**（我写代码，你发到 Smithery；免费）→ 这是"agent 逛的地方"的正解
3. **Show HN**（周二/周三上午 PT，最容易上首页）
4. **X 一条 + Farcaster 一条**
5. Reddit 放到指数满 7 条记录之后（有历史再发，不然被问"有数据吗"）

## E. 发帖前的三个硬条件（已有两个）

- ✅ 可验证的链上合约 + 审计文档 + 方法论
- ✅ 公开 API + llms.txt + Dataset schema
- ⏳ 指数 7 天历史（11-07 达成）
