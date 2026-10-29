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

## Outcome: the wallet holds real PAXG

The 5 USDC is still in CCTP, but the mainnet ETH from the successful bridge was enough to complete the
demonstration on its own:

    0.0007 ETH -> 0.000403745752141591 PAXG
    tx 0xd0456d7a3501a9c25cf4f6aa785f01ae599d857d72983873633f3a1e5199cf84
    1 step, Eth SushiAggregator, gas 290,422, success
    remaining mainnet ETH 0.000184422882866351

**The test wallet now holds PAXG on Ethereum mainnet, bought with a real on-chain swap through the
same Rango path the site uses.** That is the evidence the project was missing: not a simulation, not
a testnet mint, but an actual ounce of tokenised gold.

What is still unproven is the **two-step** route completing unattended, which is precisely what the
strand above exposed. The difference matters and should be stated that way in any external claim:

> one-step cross-chain purchase: executed with real funds (tx above)
> two-step purchase (bridge + destination swap): blocked by a resume bug on our side

## Ledger of real transactions

| # | Tx | What |
|---|---|---|
| 1 | `0xadaf7576…a36e` | approve USDC (Arbitrum) |
| 2 | `0x31df72d6…2a09` | 5 USDC → ETH on Arbitrum |
| 3 | `0xb519e876…f153` | 0.001 ETH Arbitrum → Ethereum (Across) |
| 4 | `0x58b2f2e3…827f` | approve USDC → 0 (Arbitrum) |
| 5 | `0x1637a13b…e1e6` | approve USDC → 5 (Arbitrum) |
| 6 | `0xd512ec66…0792` | 5 USDC into the CCTP route (**stranded, attested**) |
| 7 | `0xd0456d7a…cf84` | 0.0007 ETH → 0.000403745752141591 PAXG (**real gold**) |

## Resolution — the strand was a delay, not a loss

On 2026-10-29 the CCTP mint completed on its own (Rango's relayer, ~2 days later): the wallet received
**4.934632 USDC on Ethereum**, i.e. the 5 USDC minus bridge fees. Money had never been at risk of
disappearing — only of being stuck, which is still a real product bug, but not a loss.

The missing last step was then completed directly on Ethereum:

    4.9 USDC -> 0.001210043778937096 PAXG
    approve 0x2329e451628b595254cf5aeeccc4214253c2520c6c41679a559ef8473ec1518a
    swap    0xeb3e271f8d709cfe8a219685bc18a88e58df770a54a78422eafe0efa1c391d29
    Eth SushiAggregator, 1 step

**End state of the wallet (all bought through Rango, all real):**

    Ethereum  PAXG 0.001613789531078687 oz  (~$6.52)   <- /api/metals reads exactly this
    Ethereum  USDC 0.034632
    Ethereum  ETH  0.001609
    Arbitrum  USDC 1.867313 | ETH 0.001149

The resume fix (requestId persisted before the first signature) remains the correct fix: even though
this one settled itself, the next route that stalls mid-step needs a handle, and the shipped code
now keeps one.

## Ledger (final)

| # | Tx | What |
|---|---|---|
| 1 | `0xadaf7576…a36e` | approve USDC (Arbitrum) |
| 2 | `0x31df72d6…2a09` | 5 USDC → ETH on Arbitrum |
| 3 | `0xb519e876…f153` | 0.001 ETH Arbitrum → Ethereum (Across) |
| 4 | `0x58b2f2e3…827f` | approve USDC → 0 (Arbitrum) |
| 5 | `0x1637a13b…e1e6` | approve USDC → 5 (Arbitrum) |
| 6 | `0xd512ec66…0792` | 5 USDC into CCTP (**settled 10-29: 4.9346 USDC arrived**) |
| 7 | `0xd0456d7a…cf84` | 0.0007 ETH → 0.0004037 PAXG |
| 8 | `0x3e7efdaf…cd1e` | 0.0015 ETH Arbitrum → Ethereum (Across, gas top-up) |
| 9 | `0x2329e451…518a` | approve USDC (Ethereum) |
| 10 | `0xeb3e271f…1d29` | 4.9 USDC → 0.00121 PAXG (**the loop closes**) |
