# Network & infrastructure security audit — 2026-10-31

Scope: everything OUTSIDE the contracts — the web app, the API, CI/CD, the key topology, supply
chain, and the local machine that holds the keys. Method: live checks against the actual files,
secrets and workflows. Verdicts as in the contract audit.

## 1. CI/CD (GitHub Actions)

| Check | Result | Verdict |
|---|---|---|
| Workflow triggers | only `schedule`, `workflow_dispatch`, and one `pull_request` (ton-build) | SAFE |
| pull_request_target / issue_comment / workflow_run | absent — no pwn-request surface on the public repo | SAFE |
| Secrets echoed in workflow logs | zero matches | SAFE |
| Repo write access | single account; an account compromise = workflows edited to exfiltrate all secrets | MITIGATED (unavoidable with Actions) |
| Action dependencies | checkout@v4, setup-node@v4 — pinned to majors | SAFE |

## 2. API layer (Vercel serverless)

| Check | Result | Verdict |
|---|---|---|
| User input into RPC calls | only `?full=1` (a flag) — no address/amount input reaches the RPC | SAFE |
| Injection/SSRF surface | contract addresses are constants in the code | SAFE |
| Rate limiting | **NONE on any endpoint.** `/api/v1/price-signed` generates signatures with two keys and runs upstream price fetches per call — a hammerer can burn Vercel invocations and the upstream source quotas | FINDING N1 |
| Error envelopes | 503 + Retry-After on RPC outage; consistent error shape | SAFE |
| price-signed exposure | public by design (pull oracle); the feed being public is what F0 was about, now closed at the trade layer | ACCEPTED |

## 3. Key topology

| Key | Location | Verdict |
|---|---|---|
| Operator EOA (owner of everything) | GitHub secret + **`E:\Protocol Bank\.env.local` in plaintext** | FINDING N2 (the big one) |
| Oracle signer keys (2-of-3) | Vercel env + GitHub secrets | FINDING N3 (duplicated, not split) |
| Guardian key | GitHub secret only (new) | SAFE |
| `.env.local` inventory | ~70 secrets in one plaintext file: MNEMONIC, operator key, FUNDING_WALLET, RELAYER, ASSET_DISTRIBUTOR, Stripe, Supabase service-role, Privy, Reown, Rango, Postgres, Redis, X, BSKY, TG, DeepSeek, OpenRouter, VERCEL_OIDC_TOKEN | FINDING N2 |

## 4. Supply chain

| Check | Result | Verdict |
|---|---|---|
| relayer deps | viem ^2.21.0, @ton/* — lockfile present | SAFE |
| npm audit | 3 high on first run; `npm audit fix` cleared one → 2 remain, one chain via zod with no fix | FINDING N4 (assessed below) |

## Findings

### N1 — No rate limiting on the public API (MEDIUM)
The signed-feed endpoint is the expensive one: every call fetches live sources and signs 14
payloads. Unmetered, it is a cost-amplification and quota-exhaustion vector (Vercel invocations +
Yahoo/Sina/Tencent/Eastmoney source quotas, which the whole index depends on). Fix: an in-memory
token bucket in the Vercel function (cheap, per-IP, ~10 req/min) + a longer cache on the feed.

### N2 — The entire key estate sits in plaintext on a consumer Windows box (HIGH)
`.env.local` holds the operator key, a mnemonic, funding/relayer/distributor keys and third-party
service secrets. This machine is the single point of failure of everything: one infostealer, one
sync/backup slip, one shared-file leak = the index, the perp, the bot and the business accounts.
Fix (do before any more money): move the operator key to a hardware wallet / cold key, delete the
private keys from `.env.local`, keep only what local dev strictly needs, and rotate everything
that has ever lived there once the move is done.

### N3 — Oracle signer keys are duplicated across vendors, not split (LOW, previously F4)
Both keys exist in Vercel AND GitHub. Two vendors make leak windows ADDITIVE, not protective. The
guardian split showed the pattern that works; the signer split needs a co-signing relay (the feed
endpoint must produce both signatures, so one vendor must hold both — accept this and compensate
with monitoring, or build the split signer). Accepted for the beta, documented.

### N4 — 2 high advisories in the relayer tree (LOW for this project)
The remaining advisories sit in the `@ton/*` test/legacy tree (zod chain), which the Arbitrum
prod paths do not execute. Lockfile updated by `npm audit fix`; the no-fix one is monitored.
Not exploitable against the live system, but it will keep flagging CI if we add a scanner.

## Bottom line

The network perimeter is in good shape where it can be audited from here: CI/CD is clean, the API
has no injection surface, the repo holds no keys in history, and the guardian split is real. The
two things that matter are both on the machine next to you: N2 (everything in one plaintext file)
and N1 (an unmetered signing endpoint). Fix N2 first — it is the cheapest and the highest-leverage
security improvement available, and it does not need any code.
