# Outreach playbook — who to contact, how, and what to send

Written 2026-10-29. The owner sends these personally; every message is copy-paste ready, every
link carries a ref so the funnel data says who worked.

## The one rule first

Send from your personal account. Bots cannot start chats (Telegram rule). One human sentence opens
the door; everything after can be automated.

## Target 1 — 叮噹哥 (arbitrage creator)

- Who: bilibili creator, "PAXGUSDT & XAUUSD 跨市场套利实操" (BV1GeynBdEbE), audience already
  trades gold tokens daily.
- Channels: Telegram @dingdangbro · bilibili 私信/视频评论区 · 视频简介里的 QQ 2913789015.
- Angle: our page IS an arb screen — spot price vs on-chain market price side by side, five-chain
  buy comparison. His audience wants exactly that spread.

Message (Telegram / QQ):

> 叮噹哥，我做了个简单网页，一句话：把你视频里讲的金价差价直接显示出来——现货金价和链上 PAXG
> 价格放一页，差多少一眼看到。
>
> 观众再粘一下自己的钱包地址，就能看到自己手里有多少盎司黄金。
>
> 链接放你视频简介，观众通过它买黄金，你拿 0.1% 提成。
>
> 链接：https://ppppp.space/metals?ref=dingdangbro

If he asks about the cut: "0.1% 是 Rango 默认返点，第一笔到账后数字说话；不签独占、不碰你
的粉丝关系。"

## LESSON: the first pitch was too jargon-heavy (dingdangbro said he did not understand it)

The original message named KAG discounts, on-chain vs spot prices and five chains — inside
baseball. The pitch that works for a general audience leads with ONE plain sentence about what the
thing IS, then what the reader gets. Screenshots beat words: send the /metals totals panel and the
buy comparison instead of explaining them.

## Target 2 — guide/affiliate content sites (Datawallet-style)

- Who: zh "how to buy gold with USDT" guide sites that already monetise with affiliate links.
- Channels: their site contact form / hello@ email / X.
- Angle: their readers learn HOW to buy, then are left alone; our page answers "after you buy" —
  and it's another affiliate link for them.

Message:

> 主题：你们"用 USDT 买黄金"指南的下一步 —— 现成工具 + 分成
>
> 你们的读者看完指南买完 PAXG/XAUT 之后，没人回答：钱包里到底多少盎司？代币是不是仿盘？
> 链上价和现货差多少？哪条链买最省？
>
> 我们把这四件事做成了一个只读页面（中文、不托管、不碰 KYC）：https://ppppp.space/metals
> 在指南里加一个链接（加 ?ref=你的名字 即可），读者每笔兑换你们拿 0.1% 分成，数据可查。
> 合作页：https://ppppp.space/operators

## Target 3 — PAXG/XAUT Telegram groups & zh gold communities

- Where: Telegram search "PAXG" / "XAUT" / "黄金代币"; WeChat gold-token groups you may already
  be in.
- Message (short, group-friendly):

> 群里应该有人问过：我钱包里的金到底多少盎司、买贵了没？这个只读页面粘贴地址就出答案，
> 现货/链上双价 + 五链比价：https://ppppp.space/metals?ref=tg
> 不托管、不注册、不碰私钥。

## What happens after a reply

1. They say yes → send them their ref link, they place it, done. Track in
   `/api/events` logs (pageview/quote/swap_clicked/completed all carry ref=).
2. They ask about money → answer only with: "0.1% 默认分成，第一笔到账后确认，不承诺没实测过的数。"
3. They ask about legality → "只读页面，不托管不兑换资金，兑换发生在 Rango 和用户钱包之间。"

## The 30-day judgement

Success = 10 swaps/month from non-owner wallets (visible per ref in the events log). 0 swaps after
30 days = the distribution model dies; pivot to B2B feed only. No third option.
