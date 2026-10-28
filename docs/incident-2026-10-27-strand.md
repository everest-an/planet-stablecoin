# Incident: 5 USDC stranded mid-route in a Rango CCTP bridge (2026-10-27)

## What happened

To fund the Ethereum gas needed for the PAXG leg, I bridged **0.001 ETH Arbitrum → Ethereum** with our
own executor. That worked, one Across step, and proved the executor end to end:

    0xb519e876ab794c7fae2eb2533baf8a8fdc6a6cf3e5e201da4095c6150d83f153   ETH 0.001 → 0.000977

Then I ran **5 USDC (Arbitrum) → PAXG (Ethereum)**, a two-step route
(`Cctp V2 Economy Aggregator > EthereumUniswapV3`).

| Step | Result |
|---|---|
| 1 — approve USDC (to 0, then to amount) | success, `0x58b2f2e3…`, `0x1637a13b…` |
| 1 — swap into the CCTP route | success, `0xd512ec66…` (USDC 6.867 → 1.867) |
| 2 — swap on Ethereum | **failed**: `/tx/create` → `Something went wrong, please try again` |

## Where the money is

The Arbitrum swap emitted a valid CCTP v2 message, and **the attestation is complete**:

    message hash  0x009f513ab15cb489be099882f0b1dda9f257ad963edfee1fda3364b7deec4d5f
    message       376 bytes
    iris          https://iris-api.circle.com/v2/messages/3?transactionHash=0xd512ec66…
    destination   0x28b5a0e9c621a5badaa536219b3a228c8168cf5d   ← Rango's own router, not our wallet

`receiveMessage` has **not** been called: Ethereum USDC is 0 at both our wallet and that router. The
5 USDC sits inside CCTP, fully attested, waiting for a mint.

## Why it is stranded

The destination encoded in the message is Rango's contract, so the minted USDC cannot be redirected to
us. Completion depends on Rango's relayer (Economy routes are relayed, hence slower), or on signing
their step 2 — and step 2's `tx/create` failed, with no stored `requestId` to retry it.

**That is our bug, not theirs: the executor keeps the `requestId` in memory only.** When a later step
fails, there is no way to resume, and the funds are already committed to the route.

## What to change in the shipped code

1. **Persist `requestId` before signing step 1**, and expose a `resume(requestId)` path that retries
   `tx/create` for the failed step. A route with 2+ steps must be resumable, because step 1 moves
   real money.
2. **Refuse multi-step routes in the UI until (1) exists.** A one-step route cannot strand funds at a
   step boundary; a two-step route can.
3. Surface Rango's own message text to the user instead of a generic failure, so "please try again"
   is not the whole story when money has moved.

## Current balances

    Arbitrum   1.867313 USDC   |  0.002652 ETH
    Ethereum   0 USDC          |  0.000977 ETH
    PAXG       0 on both chains

## Recovery

1. Wait for Rango's relayer to call `receiveMessage` (it is attested, so the mint is one tx away).
2. If it has not landed within a few hours, contact Rango support with the Arbitrum tx hash
   `0xd512ec66620602d5fba7430bd70be00290be95a841badd2644d7e6adcf250792` and note that the
   attestation is already complete — this is a relayer delay, not a failure.
3. Do not re-run the same route until (1) is implemented; it would strand another 5 USDC the same way.

## What is still proven

The core capability is not in doubt: a real cross-chain purchase executed with real funds
(`0xb519e876…`), and the earlier Arbitrum swap (`0x31df72d6…`). What is unproven is a **two-step**
route completing without a resume path — and this incident is the reason to build one.
