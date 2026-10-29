# Threat model — Planet from an attacker's perspective (2026-10-29)

Written by looking at the system the way an attacker would: what is worth stealing, what is the
cheapest path to it, and what is already closed. Ranked by real exploitability today, not by
theoretical severity.

## 0. What an attacker actually wants here

Today there is **no money in the protocol**: the contracts are on Sepolia, PLT supply is 0, and the
on-chain "crown jewels" are worth nothing. What an attacker can actually get today, in order of
value:

1. The **affiliate wallet** (0x3d0ab5…23B) — will accumulate 0.1% of flow; today near-zero.
2. The **test wallet** (0xBf0D…768C) — ~\$20 of metal.
3. **Keys that become valuable later**: the GitHub Actions deploy/relayer key (MONAD_DEPLOY_KEY),
   which becomes protocol control the day this moves to mainnet.
4. **Our service itself** (ppppp.space availability) — the only thing that has business value now.

So the honest framing: today's highest-value attack is DoS; tomorrow's is the GitHub secret.

## 1. Current exposures, ranked

### 1.1 (Medium, now) No rate limiting on the money endpoints

`/api/quote` is edge-cached (s-maxage=20) so identical-URL spam is absorbed, but `/api/execute`
(confirm/create, POST, uncached) can be hammered. Every call hits Rango with our API key — enough
spam burns the key's quota and takes the whole product down. Cheap, anonymous, no skill needed.

Fix: per-IP rate limit on /api/execute (in-memory per instance is enough to blunt brute spam;
Upstash later).

### 1.2 (Medium, now) The Rango API key has been exposed and is not rotated

The key was pasted in plaintext in chat during development and lives in local .env files. What an
attacker can do with it: burn quota, impersonate our app's API calls. What they cannot do: touch
user funds (users sign their own transactions) or redirect the affiliate (wallet comes from our
server env). Still: rotate it. This is a one-command fix with zero downside.

### 1.3 (High, tomorrow) GitHub write access = the whole protocol

`evm-push.yml` runs on every push to main with `MONAD_DEPLOY_KEY` in the environment. Anyone who
can push — collaborators, or a stolen personal access token — can edit the workflow to print the
key. That key pushes prices AND (per the audit's L-04/M-05) overlaps with admin capability:
one key → false prices → protocol control. Nothing is worth stealing today, but this exact
structure is how protocols get drained after mainnet.

Fix before any mainnet move: split deployer / relayer / timelock-owner into three secrets held by
different people or a multisig, restrict repo write access, and require a hardware key on the
GitHub account. Fork-PR exfiltration is already blocked (GitHub withholds secrets from fork PRs;
no workflow uses pull_request_target).

### 1.4 (Low, now) The affiliate wallet is the owner's personal wallet

As revenue accumulates, a well-known address becomes a phishing target. Cosmetic today; consider a
dedicated treasury keypair later.

### 1.5 (Low, now) CORS `*` on API endpoints

Any website can call /api/execute. Worst case: a malicious site drives a victim through our API to
construct a swap — which the victim must still sign and visually confirm in their own wallet.
Damage is bounded by the wallet's own UX. Tighten to the canonical origin when convenient.

## 2. What is already closed (verified this session)

- XSS: all third-party-derived strings (Rango errors, symbol/chain names) go through esc() before
  innerHTML — /metals and /app.
- Protocol Bank mock fabrication in production: gated on ALLOW_RANGO_MOCKS + non-production build;
  the missing-key branch returns 503. The failure mode that could show a user a price that does
  not exist is closed.
- Secrets in git: .env/.env.local ignored in both repos; history scan found only public
  transaction hashes, no private keys committed.
- Telegram webhook: secret-authenticated, no model, no free-form text.
- localStorage failures (WeChat private mode) can no longer break a swap.
- On-chain: the critical (EOA-owner) and high (redeem freshness) findings from the simulated
  audit are fixed in the assessed version; supply 0 means nothing to steal regardless.

## 3. The contract layer, honestly

For the Sepolia deployment the attack surface is economically empty. Before any mainnet use the
blockers are the ones the simulated audit already named: oracle signer set 1-of-1 (M-05),
key-overlap (L-04), a 60-second timelock, and no verified source on the explorer. None of these
are secrets or code bugs to hunt — they are decisions to make before value exists.

## 4. The three things to do, in order

1. **Rotate the Rango API key** (now — it was in plaintext chat).
2. **Add a per-IP rate limit on /api/execute** (now — DoS is the only attack with real damage today).
3. **Split and harden the GitHub secrets before any mainnet deployment** (later, but structural).
