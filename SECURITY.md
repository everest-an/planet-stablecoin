# Security policy

## Status

The Arbitrum One index is live; the perpetual market is **beta** and the metal router is live.
The contracts are **not externally audited**. The system must not be used with value you cannot
afford to lose. Reports are welcome regardless.

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

- Email: e@ppppp.space
- Or use GitHub's private *"Report a vulnerability"* (Security tab → Advisories).

Please include: the affected contract or file, a description, and a reproduction (a failing test
is ideal). We aim to acknowledge within 5 working days.

## Scope

In scope: `monad/src/` (PlanetCore, PlanetToken, PlanetTimelock, SignedPriceOracle, PlanetBond),
the deployment and operations scripts in `relayer/`, the public API in `web/api/`, and the
signing/price-handling logic.

Out of scope: `legacy-solana/` (archived, unmaintained), documentation wording, and testnet
endpoints (which hold nothing of value).

## Known, documented issues

We publish our own findings rather than hiding them — see `docs/audit-scope-2026-10.md`,
`docs/self-audit-2026-10.md`, `docs/attack-matrix-2026-10-31.md`, and
`docs/network-security-audit-2026-10-31.md`. Issues listed there as *by design* or *hardening*
are already known; reports that add new information are still useful.

## No bug bounty

There is no paid bounty programme yet. That is a funding decision, not a statement that reports
are unwelcome.