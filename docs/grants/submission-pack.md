# 提交包（可直接粘贴）

> 用途：把「TON Builders Portal 申请」和「TonBit 折扣审计申请」写成**可直接粘贴**的文本 ✓。
> 主体：**Everest Holdings Group Co., Ltd.（珠峰控股集团）** · 公开仓：**https://github.com/everest-an/planet**
> ⚠️ 不含任何密钥 ✓；提交前确认公开仓可访问 ✓（已确认 public ✓）。

---

# ① TON Builders Portal — 项目登记 + 申请文案

**Portal**：`eco.ton.org` / `builders.ton.org`（先注册项目，再在里面提交具体支持申请 ✓）

### Project name
`Planet — commodity purchasing-power index (RWA infrastructure for TON)`

### One-liner (≤ 200 chars)
> An open-source, audit-ready stack for issuing commodity- and RWA-backed assets on TON: contracts, a signed multi-source oracle, a dashboard, and a Telegram Mini App.

### Category
`Infrastructure / Developer tooling` + `DeFi — RWAs`（官方 "Simplified DeFi" 垂直明确列入 RWAs ✓）

### Stage
`Building`（已有可运行产品 ✓、有测试覆盖 ✓、尚未有规模用户 ✓）

### Description（粘贴这段）
> **What it is.** Planet aggregates the real prices of a basket of global commodities (energy, metals,
> agriculture — 14 instruments today) into a single on-chain **purchasing-power index (PPI)**, and
> expresses it as a TEP-74 token on TON. It is a **testnet proof-of-concept**: synthetic index token,
> no reserve, unaudited, and explicitly *not* a stablecoin.
>
> **Why it is public-good infrastructure, not just a product.** Every hard part of an RWA issue on TON
> is already built and documented in the open repository, so the next team does not have to rebuild it:
> a **signed multi-source oracle** (two independent feeds, median, ed25519, on-chain M-of-N with
> distinct-signer enforcement, strictly increasing timestamps, a price-jump limit and divergence
> auto-freeze); a **timelock** so every privileged action is `propose → delay → execute`; a **findings
> register** from a self-review of 10 issues; and an **audit-preparation pack** (scope, invariants,
> trust/threat model, plus the questions we want an auditor to attack) that other TON RWA projects can
> reuse to shorten their own audits.
>
> **Status / evidence.** 239 automated tests across 19 files, coverage-gated in CI (≥90, ratchet only
> up); a deploy dry-run job that validates the deploy scripts in emulation before any funds are spent;
> and a live testnet deployment with 14 assets, locked base prices, a dedicated hot signing key
> separated from the owner key, and 14 prices written and read back identical.
>
> **Repo:** https://github.com/everest-an/planet — start with `docs/audit-prep.md`.

### What we are applying for (pick what fits the portal's menu)
1. **Development grant** — for the three milestones in §② below.
2. **Non-commercial / public-goods support** — the audit report and the reusable templates are the
   public-good output.
3. **Smart-contract audit support** — see the TonBit application in §③ (this is the one we need most).

### Roadmap / milestones (public-good deliverables)
| # | Milestone | Deliverable (open source) |
|---|---|---|
| M1 | Third-party audit + publish the report | Audit of the core contracts; the report, scope and findings register published as a reusable template for any TON RWA project |
| M2 | Oracle hardening + zero-custody adapter | Per-asset staleness, a batched multi-asset update (cuts push gas ~5–8×), and an oracle adapter that holds **no funds** — with tests |
| M3 | Developer kit + reference templates | White-label deployment template, issuer documentation, a worked "tokenise one commodity" tutorial, and the vesting/governance primitives |

### Team
**Everest Holdings Group Co., Ltd.（珠峰控股集团）** — disclosed and prepared to complete KYC with the
programme. Built and shipped the contracts, the oracle, the timelock, the dashboard/API and the
Telegram Mini App; prior work is public in the repository.

### Contact
everest9812@gmail.com · @EverestAn

---

# ② TonBit — 折扣审计申请（邮件正文）

**Subject:** `Audit application — commodity/RWA tokenisation stack on TON (public repo + audit-prep pack)`

> Hello TonBit team,
>
> We would like to apply to your audit programme for a TON/Tolk project, and we are ready to start.
>
> **What we are.** Everest Holdings Group Co., Ltd. — we have built an open-source stack for issuing
> commodity- and RWA-backed assets on TON. It is a testnet proof-of-concept and is **unaudited**; the
> whole point of this application is to change that.
>
> **Repo (public):** https://github.com/everest-an/planet
> **Start here:** `docs/audit-prep.md` — scope, invariants (I1–I10), our trust and threat model, and a
> findings register from our own review of 10 issues (each fixed with a regression test, or documented
> as accepted-by-design). `docs/contract-review.md` has the detail.
>
> **In scope:** `ton/contracts/` — PlanetCore (basket, on-chain index, mint/redeem, redemption mirror,
> fee tiers, risk limits, oracle state, governance basket ops), PlanetTimelock, PlanetGov (staking and
> pro-rata fee dividends), PlanetBond, PlanetFund, and the vendored TEP-74 jetton implementation.
>
> **Why we think this is efficient for you:** the scope, the invariants, the threat model and a list of
> the six things we most want attacked are already written down. 239 tests and a CI coverage gate exist.
> We are not asking you to discover the project — we are asking you to falsify it.
>
> **Budget / scope:** we would like to discuss the discounted ecosystem rate and agree a scope for a
> first pass. If a smaller first engagement is easier, we would rather start there than wait.
>
> Thank you — we are ready to provide anything you need.
>
> Best regards,
> Everest An · Everest Holdings Group Co., Ltd.（珠峰控股集团）
> everest9812@gmail.com · @EverestAn

---

# ③ 提交前 60 秒检查

- [ ] 公开仓可访问 ✓（`https://github.com/everest-an/planet` ✓）
- [ ] `docs/audit-prep.md` 与 `docs/contract-review.md` 在仓里 ✓（已确认 ✓）
- [ ] **没有任何密钥出现在申请文本里** ✓
- [ ] 补上 `everest9812@gmail.com` / `@EverestAn` ✓
- [ ] `NOTICE` 里 vendored TEP-74 的上游许可已核实 ✓（待办 ✓）
- [ ] 措辞检查：**不出现 "stablecoin" / "yield" / "guaranteed"** ✓（全文已符合 ✓）
