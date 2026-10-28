# Rango integration — the contract we verified, and one live bug it exposed

Verified 2026-10-27 against the real API with the account's key. Everything below was executed, not
read off a page.

## The three calls, and the one field that cost the most time

### 1. Quote

```
POST https://api.rango.exchange/routing/bests?apiKey=…
{ "from": {blockchain, symbol, address}, "to": {…}, "amount": "100",
  "selectedWallets": { "ARBITRUM": "0x…", "ETH": "0x…" }, "slippage": "1" }
→ { routeId, results: [ { requestId, outputAmount, swaps[] } ] }
```

Wallets belong in the **request**, not only in confirm: passing `fromAddress` alone is accepted but
then confirm has nothing to bind to.

### 2. Confirm

```
POST /routing/confirm?apiKey=…
{ "requestId": "…", "selectedWallets": { "ARBITRUM": "0x…", "ETH": "0x…" }, "destination": "0x…" }
→ { ok, result: { requestId, route… }, validationStatus, missingBlockchains }
```

**`selectedWallets` is required and is a map of EVERY blockchain in the route.** This is the whole
reason `confirm` returned `errorCode 1201 — Can not find wallet for ARBITRUM, ETH!` for four
different payload shapes: the field was simply missing. Not a permissions problem, not a plan limit.

### 3. Create transaction (per step)

```
POST /tx/create?apiKey=…
{ "requestId": "…", "step": 1,
  "userSettings": { "slippage": "1.0", "infiniteApprove": false },
  "validations": { "balance": false, "fee": false, "approve": true } }
→ { ok, transaction: { type:"EVM", to, data, value, gasLimit, nonce, isApprovalTx, spender, … } }
```

The field is **`isApprovalTx`**. When it is true you must sign and land that transaction, then call
`/tx/create` **again** for the same step to receive the real swap. Loop until `isApprovalTx` is false.

Status afterwards: `GET /tx/check-status?requestId=…&txId=…`, states `running | failed | success`.

## The correct client loop

```
bests → pick route
confirm { requestId, selectedWallets }        // every chain in the route
for step in 1..N:
    loop:
        tx = createTransaction({ requestId, step })
        if (!tx.transaction) throw
        send tx.transaction via the user's wallet; wait for the receipt
        if (!tx.transaction.isApprovalTx) break     // that was the swap
    // next step
poll check-status until success/failed
```

Two details that are easy to get wrong and expensive to debug:

- an approval is a **separate** `createTransaction` round trip, not a field on the swap tx;
- `validations.balance/fee` should be false if you already checked them client-side, otherwise Rango
  repeats the check and can fail on stale balances.

## The bug this uncovered

`E:\Protocol Bank\components\cross-chain-swap.tsx` → `handleSwap` does not execute a swap:

- it never calls `sendTransaction` / `writeContract` on the connected signer;
- `confirmRoute()` posts only `{requestId, routeId}` — no `selectedWallets`, so the real API answers 1201;
- `createTransaction()` builds a payload but **drops its `userWallets` argument**;
- then it shows "Swap initiated!" and calls `onSwapComplete` with `tx?.hash ?? requestId`.

So a user pressing swap sees a success toast and nothing happens on-chain. The proxy at
`app/api/rango/route.ts` forwards whatever it is given, so the fix is entirely client-side: pass
`selectedWallets`, then run the loop above.

**This is a production bug, not a test one.** It is the highest-priority item in either repository.

## Key handling

- The key lives in Vercel as `RANGO_API_KEY` (Production, Secret). It is never sent to the browser.
- `web/api/quote.js` returns `503 not_configured` when the variable is missing, rather than a button
  that does nothing.
- The key was shared in plaintext during this session. Rotate it in the Rango dashboard once the
  current round of work is finished; nothing in this repository needs the old value.

## Verification log (2026-10-27)

Three layers, strongest evidence first.

**1. Rango contract — live API, real payloads.**
`bests` → `confirm` → `tx/create` all return 200 against the production key. Confirm without
`selectedWallets` returns `errorCode 1201`; with it, 200. Create returns a real EVM approval
transaction (to = USDC, 138-char calldata) on the source chain.

**2. Executor logic — jsdom with a stubbed wallet.**
quote → swap now → confirm → create(approve) → sign → create(swap) → sign → "sent, 2 transactions
confirmed". This is what caught the first loop's bug (it broke out after the approval, so the swap
was never sent).

**3. On-chain mechanics — real transactions, test tokens, Ethereum Sepolia.**
Deployed two mock ERC-20s and a toy DEX from the agent test wallet, then ran exactly the sequence the
executor performs:

    TUSDC  1000 → 995   (approve → transferFrom)
    TPAXG     0 → 5     (payout)
    3 transactions, all status success

    TUSDC 0x5f3183f7df18bd359ba5731d4c472e2ff08af4b1
    TPAXG 0x24e29d2a8a8160594b0a6dd697d536d2d5c5ba6c
    TDex  0xaa71786f8d1bd978706cb0341483fd9a37aac07a

**What is still not verified:** a real Rango route end to end. That needs ~5 USDC on Arbitrum plus
~0.00002 ETH on Ethereum for the destination leg (PAXG has no official Arbitrum deployment, so the
last hop is on mainnet). The test wallet holds gas for neither leg, so the funding has to come from
outside.

## Outcome

The Protocol Bank fix (branch `fix/rango-swap-execution`) is merged into `main` at `5fc5b692`.
It is the same logic as `/api/execute` plus the on-chain sender, and TypeScript is clean on the
merge. The previous behaviour was to show a success toast and do nothing; the new behaviour is to
either execute or report why not — which is a strict improvement even before a real route is run.

## Revenue: the affiliate route (decided 2026-10-27)

**Decision: charge nothing of our own. Take Rango's affiliate share instead.**

Why not our own fee: a fee we collect means we hold money, which means custody, refunds, accounting
and a regulated activity. Rango already charges the user a route fee; its affiliate programme pays a
registered integrator out of that same fee. The user pays exactly what the route quotes, no markup,
no custody, no additional promise.

Implementation: `/api/quote` attaches `affiliateRef` and `affiliateWallets` to the `bests` request
when both env vars are set:

    RANGO_AFFILIATE_REF      the ref registered with Rango
    RANGO_AFFILIATE_WALLET   the treasury address (one EVM address covers every EVM chain)

Both unset = no affiliate, which is the current live behaviour: the code is deployed and inert until
those two values exist. An unregistered ref is silently ignored by Rango, so registering it is a
prerequisite, not a formality.

Target rate: whatever Rango's programme pays on the routes we use (typically a fraction of the route
fee). Do **not** advertise a percentage until the first payout confirms it.

### What this does not solve

The affiliate share is small and volume-dependent. It turns "free tool" into "tool that pays for its
own gas", not into a business. The business-sized revenue is still the B2B feed conversation and,
before that, a real backing model.
