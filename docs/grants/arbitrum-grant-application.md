# Arbitrum Foundation Grant — Application (Multichain Track)

> **Applicant:** Everest Holdings Group Co., Ltd.（珠峰控股集团）· Everest An · e@ppppp.space · Telegram @EverestAn
> **Track:** **Multichain** ($20k–$60k, 2+ milestones) — for projects from another chain integrating with Arbitrum
> **Status:** ready to submit once deployed; the only blank is the deployed address.
> **Why this track:** we are not asking Arbitrum to fund an idea. We are bringing a **working, tested RWA stack**
> from another chain and deploying it on Arbitrum. That is the exact case the Multichain track exists for.

---

## 1. What we are

An **on-chain commodity purchasing-power index (PPI)** — a basket of 14 global commodities aggregated into a
single index, expressed as an ERC-20, with a governance timelock and an M-of-N signed price oracle.

**Repo (public):** https://github.com/everest-an/planet — the EVM implementation is in `monad/`.
**Evidence:** **5 contracts, 57 Foundry tests, all passing in CI** (`monad-build.yml`).
**Docs:** `monad/` contains the contracts; `docs/audit-prep.md` holds the scope, the 10 invariants, and the
trust/threat model that an auditor would start from.

## 2. Why Arbitrum, and why now

- The stack is **already EVM**. Deploying to Arbitrum is a configuration change (RPC + chain id), not a rewrite.
  We are doing it because **RWA needs cheap, fast execution and a credible DeFi home** — and Arbitrum is where
  the liquidity and the institutional RWA conversation already are.
- We are **late-stage testnet**, which is the Growth/Multichain stage this program supports: contracts built,
  tested, and reviewed; not a whitepaper.
- Our go-to-market is **B2B**: commodity traders and licensed distributors in Dubai (DMCC/VARA) who hold real
  inventory and cannot obtain bank trade finance. That is a **real-asset pipeline**, not a farming incentive.

## 3. What is already built (and what it cost us to get right)

| Component | What it does | Tests |
|---|---|---|
| `PlanetCore` | basket, on-chain index, mint/redeem, tiered fees, freshness + band guards | 18 |
| `PlanetToken` | ERC-20, mint/burn restricted to the Core | 11 |
| `PlanetTimelock` | propose → delay → execute; ownership changes only through it | 8 |
| `SignedPriceOracle` | M-of-N ECDSA, distinct signers, domain-separated digests, EIP-2 safe | 10 |
| `PlanetBond` | stabilisation bonds: request + **operator settlement** (a mis-click cannot destroy a claim) | 9 |

34 tests came from **our own review of the TON implementation**, where we found and fixed 10 issues — including
one that let a mint proceed against an **undefined index** (a fabricated 1.0). Those fixes are ported and each
has a regression test. That review is public in the repo.

## 4. The problem we are actually solving

The trade-finance gap is **$2.5 trillion** globally and **$74–92 billion in Africa**; in West Africa only ~25% of
trade is financed, against 60%+ in advanced economies, and the working-capital loans that replace letters of
credit average **~15% a year**. A trader with physical inventory and no bank line is exactly who an on-chain,
transferable claim helps — and nobody has built that rail properly.

## 5. Milestones (Multichain track, 2+ milestones)

| # | Milestone | Deliverable | Amount |
|---|---|---|---|
| **M1** | **Deploy + verify on Arbitrum** | Contracts live on Arbitrum (testnet → mainnet), source verified, a public read API, and a dashboard reading the index | $20k |
| **M2** | **Third-party audit + publish the report** | Audit of the five contracts; the report, scope and findings register published as a reusable template for other RWA projects on Arbitrum | $25k |
| **M3** | **One partner pilot** | A commodity trader or licensed distributor runs one instrument on the stack (their asset, their licence); documented end-to-end | $15k |

## 6. Team

**Everest Holdings Group Co., Ltd.（珠峰控股集团）** — built and shipped: the TON production stack (239 tests,
live testnet deployment, key separation, timelocked ownership), the signed multi-source oracle, the relayer, the
dashboard/API, a Telegram Mini App, and the public audit-preparation pack. Prior work is public.

## 7. Honesty section (we would rather say it than have you find it)

- The current deployment is a **testnet proof of concept**. It holds **no reserve**, is **unaudited**, and is
  explicitly **not a stablecoin** and **not fully collateralised**.
- We are **not** asking for funding to write a whitepaper; the code exists. We are asking for the audit and the
  first partner pilot, because those are the two things that cannot be faked.
- KYC: the entity is disclosed and prepared to complete the Foundation's KYC.
- **The oracle runs on one operator key today.** `PlanetCore.updatePrice` is `onlyRelayer`, and `SignedPriceOracle`
  (M-of-N, distinct-signer bitmap, EIP-2 malleability checks) **is deployed and wired** via `updatePriceSigned` —
  but its signer set is 1-of-1 with that same key, because one operator holds every key. Raising the threshold is
  a `setSigners()` call, not a redeploy. We would rather state that than let a reviewer assume a threshold that
  is not yet enforced by independent key holders.
- **Mint/redeem now works on Arbitrum** at /app, but read what the contract does: `mint(uint64 deposit)` takes a
- **Mint/redeem work on Arbitrum** at /app: `mint(uint64 deposit)` pulls the deposit from the caller via `transferFrom`
  and `redeem` pays it back out, decrementing `totalReserve`. The collateral is Circle's test USDC, so nothing here has
  value — and there is no custody, insurance or redemption guarantee behind it. That is the gap this grant would fund.

## 8. Links

- Repo: https://github.com/everest-an/planet-stablecoin
- EVM implementation: `monad/` (Solidity 0.8.24, Foundry; CI: `.github/workflows/monad-build.yml`)
- Deployed on **Arbitrum Sepolia** (chainId 421614):
  - PlanetCore — `0x65362ef75028700855E842F903FF6FBD65A97f65`
  - PLT token (ERC-20) — `0x367e62f6fd68FDe2698A65022713Ef99ca9a4c80`
  - PlanetTimelock — `0x9e8a685090704A3cd41590594BA5cf281c0b020d`
  - SignedPriceOracle — `0xFC560cB20875dB79b8bd8FBA96a1c78B5B69548e`
- Live read API (returns the on-chain index right now): https://ppppp.space/api/v1/status
- Oracle health: https://ppppp.space/api/v1/oracle?full=1
- Contact: e@ppppp.space

---

### Submission checklist

- [x] Deploy the core stack to Arbitrum Sepolia (3 contracts: PlanetCore, PLT token, Timelock)
      — PlanetBond / PlanetFund / PlanetGov are TON-only and deliberately NOT part of this deployment
- [x] Paste the deployed addresses into §8
- [ ] Verify the source on Arbiscan (addresses are live and readable via eth_call; verification not confirmed)
- [ ] Confirm the live app URL in §5
- [ ] Complete KYC
