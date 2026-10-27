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
