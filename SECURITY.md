# Security policy

## Status

**This is a testnet proof-of-concept.** The contracts are **unaudited**, the deployment holds **no
real reserve**, and the system must not be used with value you cannot afford to lose. Reports are
welcome regardless.

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

- Email: everest9812@gmail.com
- Or use GitHub's private *"Report a vulnerability"* (Security tab → Advisories).

Please include: the affected contract or file, a description, and a reproduction (a failing test is
ideal). We aim to acknowledge within 5 working days.

## Scope

In scope: `ton/contracts/` (the Tolk contracts), the deployment scripts, and the off-chain relayer's
signing and price-handling logic.

Out of scope: the legacy `legacy-solana/` directory (archived, unmaintained), documentation wording,
and the public testnet endpoints (which hold nothing of value).

## Known, documented issues

We publish our own findings register rather than hiding it — see `docs/contract-review.md` and
`docs/audit-prep.md`. Issues listed there as *by design* or *hardening* are already known; reports
that add new information about them are still useful.

## No bug bounty

There is no paid bounty programme yet. That is a funding decision, not a statement that reports are
unwelcome.
