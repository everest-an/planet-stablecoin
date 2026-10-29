# Operator kit — Planet as the gold counter for existing zh communities

Written 2026-10-29. The executable version of the strategy: we do not build a community, we become
the tool of communities that already exist and already monetise gold-token demand.

## 1. What an operator gets (one screen, no work)

- A working, read-only "gold counter": any wallet, any address, all five issuers (PAXG/XAUT/KAG/
  VNXAU/KAU) in one place, in ounces, with spot AND on-chain market price side by side.
- One-quote five-chain buy comparison through Rango (USDC on Arbitrum/Base/Optimism/Polygon/Ethereum).
- zh UI, MiCA warnings, issuer verification links — trust content the operator would otherwise
  have to write themselves.
- Affiliate revenue share on every swap that passes through (Rango affiliate: ref + treasury
  address — code is live and inert, waiting on the two values).

The operator keeps their audience, their brand, their trust. We are the page, not the community.

## 2. Who we pitch (in order)

| Type | Example (real) | Why they care |
|---|---|---|
| Gold-token arbitrage/content creators | 叮噹哥 @dingdangbro (bilibili, Telegram) | their audience already trades PAXG/XAUT; our spot-vs-market spread display is an arb screen |
| "Buy gold with USDT" guide sites | Datawallet zh guides (affiliate-monetised) | they already monetise this flow with affiliate links — ours is another link to add |
| OTC/USDT-outflow service providers | zh stablecoin-gold services | their customers need the multi-wallet view after they buy |
| Wallet/tax/portfolio content sites | any zh crypto media | a free embeddable tool |

Not targets: CEXes (WEEX owns the leveraged speculation demand — we do not compete with perps).

## 3. The pitch (zh, three lengths)

**One line (DM):**
> 你们社群的读者已经在交易 PAXG/XAUT 了。我有一个现成的"黄金柜台"页面（只读、不托管、中文），
> 能把他们所有钱包里的金和银汇总成盎司、显示现货和链上真实价差、一键比价五条链买入。挂你们
> 的链接，每笔兑换分成。要看一下吗？

**Medium (email):**
> 主题：给你们社群一个现成的黄金柜台（含分成）
>
> 你们的读者在用 USDT 买黄金代币（PAXG/XAUT 合计 ~$44 亿市值，中文需求在涨）。但买完之后，
> 他们的问题没人答：钱包里到底有多少盎司？这个代币是真的还是仿盘？现货价和链上成交价差多少？
> 哪条链买最划算？
>
> Planet 已经把这几件事做完了：只读、不托管、中文、五发行方、双价格、五链比价，还有 MiCA 等
> 合规提示。你们要做的是把链接放进你们的内容里。所有经过页面的兑换走 Rango affiliate 分成。
>
> 30 秒看演示：ppppp.space/metals

**Long (partnership):**
> 见 §4 的条款 + §5 的素材。核心一句话：我们不做社群，我们做你们社群的柜台。

## 4. Terms we can offer today

- Revenue: Rango affiliate share on swaps routed through the page (rate = whatever Rango's
  programme pays; first payout confirms the number before we quote it anywhere).
- Content: we provide the comparison tables (PAXG vs XAUT vs VNXAU vs KAG, issuer/jurisdiction/
  redemption), already verified — operators rebrand freely.
- No exclusive deals, no minimums, no custody, no KYC of ours.

## 5. Ready-made assets we hand over

- The comparison table (from docs/rango-integration.md + issuer pages, verified on-chain).
- The honest-risk checklist (issuer risk, MiCA, redemption minimums — from the Datawallet-grade
  research in docs/strategy-2026-10.md Addendum 2).
- The 30-second demo path: pppppp.space/metals → paste any address → see ounces + prices.

## 6. Execution checklist (the next 30 days)

1. [x] Revenue enabled: RANGO_AFFILIATE_WALLET = 0x3d0ab5…23B (wallet-only mode, no ref needed; 0.1% user fee, disclosed).
2. [ ] Send the one-line DM to @dingdangbro and 5 zh guide sites (messages in §3).
3. [ ] Track: /api/events funnel (pageview → quote → swap) per referrer (add a utm param — pending).
4. [ ] Success metric: 10 swaps/month from non-owner wallets = the model works; 0 after 30 days =
   the model dies and the honest move is B2B feed only.

## 7. What we do NOT do

- No perps, no leverage (WEEX owns that; we are the buy-and-hold layer).
- No own token for consumers (the PPI stays research).
- No pretending the affiliate share is a business — it is gas money until volume says otherwise.
