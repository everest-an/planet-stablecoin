# Fast, simple, low-compliance: what that actually commits us to

Decision recorded 2026-10-27, in answer to "which route can run quickly, simply, with the least
compliance cost".

## The answer, stated plainly

**Stay synthetic. Do not take custody. Do not promise a return. Cap the exposure.**

That is the only configuration that is all three of fast, simple and cheap to comply with, and it is
the one already deployed. Everything else — holding ETFs, hedging with futures, tokenised fund shares
— buys you a better product and a regulated activity at the same time. You cannot have the ETF upside
without being the party that owns or hedges it.

What "low compliance cost" means here, precisely:

| We do | We do not |
|---|---|
| issue a token whose value tracks a published index | hold customer assets |
| settle mint/redeem in a stablecoin we control | promise a yield, a peg, or a return |
| publish every price and every channel | take custody, act as broker, or run a fund |
| cap total supply | market it as an investment |

**Zero compliance cost is only available at zero real money.** The moment a token is sold with an
expectation of value, someone will ask what it is. The configuration above is the one with the least
to answer for: no custody, no fiduciary duty over assets, no return promise. It is not "no
compliance" — it is "the smallest honest surface".

## What this costs us, said out loud

1. **We cannot sell "earn ETF volatility."** If a customer wants ETF upside, the honest instruction
   is: buy the ETF. Anyone who promises that upside while holding stablecoins is paying it out of
   their own reserve.
2. **The product is a purchasing-power unit, not an investment.** The pitch is "your unit keeps pace
   with a basket of real goods", not "your unit goes up".
3. **Revenue is fees only.** No management fee on AUM, because a management fee implies we manage
   something. Mint/redeem fees are the whole business until Stage 2.

## What changes as a result

- **Hard supply cap.** A synthetic reserve that pays index returns is a subsidy; a subsidy needs a
  ceiling or it is an open-ended liability. Set `mintCap` and `maxMintPerTx` now, raise them by
  governance as the reserve grows.
- **Pro-rata redemption stays.** It is the contract's admission that the reserve may not cover the
  index — which is exactly right for a product that never promised it would.
- **The site must not say "backed by ETFs".** It says "tracks the price of"; §1.2 already does.
- **A treasury fee line is optional and separable.** It is revenue, not compliance, and can wait
  until there is revenue to route.

## The upgrade path, unchanged

Stage 2 (hold or hedge the basket) remains the destination and remains a company, not a commit:
entity, broker or custodian, attestation cadence. Until then, the honest sentence is the one already
on the site — and a cap that bounds what the subsidy can cost.
