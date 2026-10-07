# TON Grant Application — Commodity / RWA Tokenisation Stack

> **Draft.** Fill the ⟨bracketed⟩ fields, then submit through the current TON Foundation grant form.
> **Strategy note:** grants favour **public goods**. This submission is therefore framed as *"an open-source,
> audit-ready RWA/commodity tokenisation stack for TON"* — not as "fund our company", even though the
> milestones happen to be exactly what the roadmap needs.

---

## 1. One-liner

**An open-source, audit-ready stack for issuing commodity- and RWA-backed assets on TON** — contracts,
a signed multi-source oracle, a reference dashboard and a white-label kit — with a working deployment
already live on testnet.

## 2. Category

☑ Infrastructure / Developer tooling · ☑ RWA / DeFi primitives · ☐ Consumer app

## 3. The problem

- Real-world-asset issuance on TON is still bespoke: every team rebuilds issuance, NAV accounting,
  redemption, oracle verification and governance — each with its own security mistakes.
- Commodity-tokenisation frameworks are being built elsewhere with real momentum — **DMCC and VARA
  (Dubai) signed a framework for tokenised commodities in October 2025 and issued their first instrument
  in September 2026** — and those instruments are landing on **EVM chains**, not TON.
- TON's unique asset is **distribution**: Telegram's ~1 billion users. An RWA stack native to TON +
  Telegram reaches a market that EVM-only stacks structurally cannot.

## 4. The solution (what already exists)

A deployed, tested stack — **not a plan**:

| Component | State |
|---|---|
| Core contracts: weighted index, mint/redeem, redemption mirror, fee tiers, risk limits | ✅ implemented, **239 tests / 19 files**, 95.9% line coverage, CI-gated |
| **Signed multi-source oracle** — two independent feeds, median, ed25519, on-chain M-of-N with distinct-signer enforcement, strictly-increasing timestamps, price-jump limit, divergence auto-freeze | ✅ implemented |
| Timelock governance — `propose → delay → execute`, ownership changes only through the delay | ✅ implemented + verified on-chain |
| TEP-74 token (minter, wallet, burn mirror) | ✅ implemented |
| Dashboard, public read API (versioned, health endpoint), monthly reports | ✅ live |
| Telegram Mini App front end | ✅ live |
| Deployment runbook + **audit-preparation pack** (scope, invariants, trust/threat model, findings register) | ✅ published |

**Live demo:** `https://ppppp.space/dashboard` · **Whitepaper:** `https://ppppp.space/whitepaper`
**Repo:** ⟨GitHub URL⟩

## 5. Why TON specifically

1. **Telegram distribution is the differentiator** — the same stack becomes reachable by ~1B users
   through a Mini App, which no EVM-only RWA stack can offer.
2. The contracts are already **Tolk/TON** (not a port) — including TON-specific work the ecosystem
   repeatedly gets wrong: integer-only fixed point, cell-size discipline, bounce handling,
   state-before-send.
3. **Complements, rather than duplicates**, the wallets/launchpads TON already has: it targets
   *asset-backed* issuance, where the hard part is the oracle and the governance, not the token.

## 6. What the grant funds (public-good deliverables)

| # | Milestone | Deliverable (all open source) | Amount | Timeline |
|---|---|---|---|---|
| **M1** | **Third-party audit + publish the report** | Audit of the core contracts; the report, the scope and the findings register published as a reusable template for any TON RWA project | **$30k** | Month 1–3 |
| **M2** | **Oracle hardening + upgradeable zero-custody adapter** | Per-asset staleness, a batched multi-asset price update (cutting push gas ~5–8×), and an oracle adapter that holds **no funds** — plus tests and coverage | **$25k** | Month 3–5 |
| **M3** | **Developer kit + reference templates** | White-label deployment template, issuer documentation, a worked "tokenise one commodity" tutorial, and the vesting/governance contracts (PLTG-style) as reusable primitives | **$25k** | Month 5–7 |
| | **Total** | | **$80k** | 7 months |

**Cost discipline note:** the stack already runs on a scheduled cron with a measured gas budget
(~0.0023 TON per price update); the grant is for **audit, hardening and documentation**, not for
infrastructure burn.

## 7. Milestone acceptance criteria

- **M1** — audit report published; every finding either fixed with a regression test or documented as
  accepted-by-design; coverage gate still ≥90%.
- **M2** — per-asset staleness enforced on-chain; batched update reduces a 14-asset push to one message;
  adapter holds no funds (verifiable); tests + CI green.
- **M3** — a third party can deploy a branded instance from the docs alone; the tutorial reproduces
  end-to-end on testnet.

## 8. Team & track record

⟨Name / handle / location⟩ — built and shipped: the contracts (239 tests, CI-gated), the signed
multi-source oracle, the timelock, the live dashboard/API, the Telegram Mini App, and the deployment
runbook. Prior work is public in the repository.

## 9. Sustainability (beyond the grant)

The grant funds the **public goods**. The commercial path is **B2B technical partnership**:
commodity traders, funds and licensed distributors keep their asset, their licence and their clients,
while we supply the technology (integration fee + platform fee + revenue share). The first target
market is **Dubai/DMCC's commodity ecosystem** serving **African and South/Southeast Asian SME traders**,
where the trade-finance gap is **$74–92bn** and only ~25% of West African trade is financed.

## 10. Alignment with TON's ecosystem goals

- Adds a **reusable RWA primitive** the ecosystem currently lacks.
- Brings **real-world, asset-backed** use cases to TON instead of another memecoin.
- Produces **public documentation and an audit template** that reduce the cost of the *next* RWA
  project on TON.
- Leverages Telegram for distribution — the one advantage TON has that no other chain can copy.

## 11. Risks & honesty

- The current live deployment is a **testnet proof-of-concept** with **no real reserve**, is
  **unaudited**, and is explicitly *not* a stablecoin and *not* fully collateralised.
- Regulatory treatment of tokenised commodities varies by jurisdiction and remains with the
  issuer/licensed partners; nothing here is legal advice.
- ⟨Anything you want to add or omit.⟩

---

### Naming / messaging checklist before submitting

- Lead with **"open-source stack for TON RWA"**, never "stablecoin".
- Emphasise **public goods** (audit report, docs, templates, reusable primitives).
- Cite the **DMCC–VARA** framework as market validation and as the reason a **TON-native** option matters.
- Never promise returns, yields or price stability.
