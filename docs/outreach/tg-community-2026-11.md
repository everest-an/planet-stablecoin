# TG 社群运营包 — 2026-11

机器人已上线：webhook `https://ppppp.space/api/tg`，命令 `/index /asset /risk /perp`。
它在**任何群或私聊**里都能用——这是最好的拉群钩子：把机器人拉进别人的群，它就在那里提供指数。

## 0. 先解决一个冲突（重要）

这个机器人 token 之前指向 `www.protocolbanks.com/api/telegram/webhook`（Protocol Bank 的机器人）。
我已把 webhook 改到 Planet。**Protocol Bank 的 TG 机器人现在收不到消息。**
两选一：
- A. 接受（Protocol Bank 的 bot 若已停用则无影响）
- B. 去 @BotFather 给 Planet 建一个**新 bot**（2 分钟），我把 webhook 换过去、把旧的还给 Protocol Bank

## 1. 结构：一个群 + 一个频道（两周内只做群）

```
群  t.me/<name>          讨论 + 机器人命令 + 每日指数
频道（第 2 周再开）       只发指数与数据，作为广播位
```

群名建议：`Planet · commodity index`（英文，避免中文群被当土狗盘）
群简介（置顶）：
```
A 14-commodity purchasing-power index on Arbitrum One, with machine-readable data quality.
Live: ppppp.space/ppi · Bot: /index · Not investment advice. No price talk, no shilling.
```

## 2. 置顶消息（发完钉住）

```
What this group is:
- The Planet PPI: 14 commodities (energy, metals, agriculture, industrial), one on-chain index.
- Every asset carries a risk state (normal / caution / frozen) published with the price.
- Bot commands: /index /asset CL=F /risk /perp

What it is not:
- Not a stablecoin, no commodity reserve.
- Not audited externally; the self-audit and tests are public in the repo.
- No price predictions, no signals, no referrals.

Links: index · history · methodology · perps · metals
```

## 3. 内容节奏（机器人自动 + 人工每周一篇）

```
每天 08:00 UTC   机器人自动发当日 /index（见 .github/workflows/tg-daily.yml）
每周一           一篇"周度篮子状态"：哪些资产 caution/frozen、指数变化、为什么
每次数据事件      资产进入 caution/frozen 时发一条（这是最独特的钩子：
                 别人只发价格，我们发"数据质量"）
```

## 4. 拉人（按转化率排序，全部免费）

| 动作 | 话术 | 预期 |
|---|---|---|
| **把机器人拉进已有的商品/黄金群** | "a bot that shows the live commodity index and whether the data is fresh" | 最高：不用建群就能触达 |
| X 发每日指数 + 群链接 | 用 /history 图做配图 | 中 |
| 在 X 回复商品/黄金大 V 的帖子（带指数截图） | 只发事实，不发链接 | 中 |
| Reddit r/Gold、r/CryptoCurrency（先攒 karma） | "PAXG vs XAUT" 文章的链接 | 低但持久 |
| DM 10 个持有 PAXG/XAUT 的人 | 提供 /metals 的多链持仓视图 | 低但精准 |

## 5. 群规（防土狗化）

```
1. 只讨论商品、指数、数据、机制。价格喊单/带单 → 删。
2. 任何"合作/推广"先私聊管理员。
3. 不发邀请链接、不拉人进其他群。
4. 机器人命令随时可用，别刷屏。
```

## 6. 第一周的每日动作（每天 10 分钟）

```
1. 看 /index 自动帖是否发出（失败会体现在 Actions）
2. 回 1-2 条群消息（真人在场比内容重要）
3. X 发一条：指数 + 一个数据质量事件（如果有）
4. 拉 1 个相关群试机器人
```

## 7. 不该做的

- 买粉、拉人送钱、空投预期 —— 会把群变成撸毛群，真客户全走
- 每天发价格喊单 —— 这不是交易信号群
- 在别人的群里刷链接 —— 只提供机器人，不刷广告
