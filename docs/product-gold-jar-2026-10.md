# Product design — "黄金存钱罐" (Gold Jar)

2026-10-29. Designed on what actually exists (quote → swap → sign → resume, the Telegram bot, the
5-metal wallet view) and on the one demand this project has evidence for: people in weak-currency
economies want to save in gold but never get around to it.

## 0. The three candidates, and why two died

**A. 黄金存钱罐 (Gold Jar) — picked.** Recurring, goal-based gold saving. Weekly one-tap buy,
a jar that visibly fills, a tangible goal ("1 oz = one real coin").

**B. 黄金红包 (gold red packet) — killed.** Culturally perfect for zh users and viral by design,
but the packet must sit in escrow between send and claim. That is custody, and custody is the
thing this project has refused since day one. Revisit only with a licensed custodian.

**C. 用黄金付款 (pay with gold) — killed.** Buildable in an afternoon on our swap stack, but the
demand is fake: gold is a savings asset. Nobody spends their hedge. Payment in gold is a demo,
not a product.

## 1. The insight

Everyone sells gold. Almost nobody sells *the habit of accumulating it*.

The buyer we have evidence for (Turkey, Argentina, China-outbound) does not lack access to PAXG —
they lack a reason to buy every week instead of "someday". Buying gold is a decision; decisions
get postponed. A jar converts the decision into a default.

And the goal has a physical anchor nobody else uses: **1 troy ounce = one real coin**. "Save
$100 of PAXG" means nothing; "you are 0.22 oz away from a real gold coin" means something.

## 2. The product

**One line:** 一个会自己长大的黄金存钱罐 —— 每周买一点，攒够一盎司，就是一枚真金币。

**Flow:**

1. **Set the jar.** Connect wallet → pick a goal (0.1 / 0.5 / 1 oz, or a custom USD amount) →
   pick a rhythm (weekly / biweekly / monthly). Stored locally, no account.
2. **The reminder does the work.** The Telegram bot pings on the chosen day: "你的金罐子今天该加金了
   —— 本周报价 0.0231 oz" with a one-tap deep link.
3. **One tap, one signature.** The link opens /metals pre-filled with the week's amount and the
   best chain quote. The existing quote → confirm → sign → resume pipeline does the rest.
4. **The jar fills.** A progress bar that reads like a jar: 78% · 0.78 / 1.00 oz · 还差 8 周.
   The number is read from the chain (the wallet view we already have), not from our database.
5. **Streak.** Weeks in a row. Miss one and the jar says so — gently. Streaks are the retention
   engine; they are also honest (no fake urgency).
6. **Full.** Celebration + a plain-language note: 1 oz can be redeemed for a real coin through the
   issuer (430 oz minimum for a bar — say it, don't hide it), or sold, or kept.
7. **Share the jar.** A card: "我的金罐子：0.78 盎司，还差 0.22 就到 1 盎司". Sharing is how new
   users arrive — the recipient sees a goal, not an ad.

## 3. Why users actively want it (intrinsic, not marketing)

- **Inflation anxiety** is already there; the jar gives it a weekly ritual instead of a decision.
- **The physical goal** (one coin) is a stronger motivator than a dollar amount — it is a thing
  you can hold.
- **Discipline beats timing.** DCA removes the "should I buy now?" paralysis, which is exactly
  what stops people from ever starting.
- **It is honest.** No yield promises, no leverage, no fake APR. Just gold, bought regularly.

## 4. How we make money

1. **Rango affiliate 0.1% per buy** — already live, already wired to the treasury wallet. A jar
   user buys 52×/year instead of once, so revenue per user is ~50× a viewer's.
2. **Optional management fee later** (0.1–0.3%/yr) — only after there is real AUM, and only with
   clear disclosure. Do not charge before the habit exists.
3. **Operator cut** — a community operator who brings jar users keeps a share (the /operators deal).

The economics only work at volume, and volume only comes from the habit. That is why the product
is the habit, not the swap.

## 5. MVP — what to build in two weeks, on what already exists

| Piece | Reuses | New work |
|---|---|---|
| Goal + rhythm setup | — | one form, localStorage |
| Jar progress | /api/metals + readWallet | a jar-style progress component |
| One-tap weekly buy | /api/quote → /api/execute (sig) | prefill from the reminder link |
| Weekly reminder | tg-webhook bot | a scheduled message + deep link |
| Streak | localStorage + buy events | counter |
| Share card | — | meta image / simple SVG card |

Deliberately **not** in the MVP: auto-signing (needs smart accounts), fiat on-ramp, physical
redemption, multiple jars.

## 6. Honest failure modes

- **Small tickets, small revenue.** $10/week × 0.1% = $0.005/week per user. This only works with
  thousands of users or larger tickets — which is why the operator channel matters more than the
  feature.
- **Reminder fatigue.** If the Telegram ping is noisy, users mute it and the jar dies. One ping,
  one day, no follow-ups.
- **The streak can feel like a debt.** It must read as encouragement, never as a guilt trip.
- **Gold price falls.** Say it plainly in the jar: gold can go down; the jar is a habit, not a
  promise.

## 7. What success looks like (30/60/90)

- 30 days: 20 jars created, 5 with a second deposit (the only number that matters).
- 60 days: 30% of jars have ≥4 weekly deposits — the habit exists.
- 90 days: jars generate more affiliate revenue than one-off swaps; an operator brings 10 jars.

## 8. Why this is the right product for this team

It needs no capital, no licence, no custody, and no new infrastructure — every component already
exists and has been tested with real money. It converts the toy (/metals) into a habit, and the
habit is the only thing that can pay for itself before the Circle-style float business (ETF
reserve, custodian, licence) becomes possible.
