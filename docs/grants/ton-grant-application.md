# TON Grant Application — Commodity / RWA Tokenisation Stack

> **Draft.** Applicant entity: **Everest Holdings Group（珠峰控股集团）**. Submit through the TON Builders Portal — see the appendix for the verified 2026 route.
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
**Repo:** a curated public mirror of the code and public docs — see `docs/grants/public-repo-manifest.md` for exactly what is included (link to be filled after publishing).

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

**Everest Holdings Group（珠峰控股集团）** — built and shipped: the contracts (239 tests, CI-gated), the signed
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
- The maintainer entity (Everest Holdings Group，珠峰控股集团) is disclosed and prepared to complete KYC with the programme.

---

### Naming / messaging checklist before submitting

- Lead with **"open-source stack for TON RWA"**, never "stablecoin".
- Emphasise **public goods** (audit report, docs, templates, reusable primitives).
- Cite the **DMCC–VARA** framework as market validation and as the reason a **TON-native** option matters.
- Never promise returns, yields or price stability.

---

# ⚠️ 附：真实申请路径（2026-10 查证，覆盖上文 §"submit through the current form"）

> 上文正文作为**内容素材**仍然可用 ✓；但**投递路径**必须按下面来，否则投错门 ✓。

## A. 机制现状（已核实）

1. **TON Foundation 已不再运行传统的开放 Grant 项目** ✗。一切从 **TON Builders Portal**（eco.ton.org / uilders.ton.org）**注册**开始 —— **注册是强制第一步** ✓。
2. 两条轨：
   - **Champion**：高触达（Vertical Lead 带教 + **grants** + **合约审计** + 流量包）——**无公开申请** ✗，靠生态活跃度被识别 ✓。
   - **Emerging**：经 Portal 申请各支持项目 ✓（优先级随评分而定 ✓）。
3. ⭐ **一条专门的"非商业轨"持续支持开源工具 / 公共品 / 基础基础设施** ✓ —— **本项目的最佳落点** ✓。
4. **Simplified DeFi** 垂直的官方描述**点名 RWAs** ✓ —— 与我们的定位直接吻合 ✓。
5. 评分维度（类 VC）：垂直契合 · 生态影响 · 团队 · **资金与收入** · 产品成熟度 ·  traction ⇒ **"已有可运行产品 + 有营收"能显著加分** ✓（我们的 B2B 收费模式正好补这一项的短板 ✓）。

## B. 立刻可申请的"伙伴资源"（比 grant 更快见效 ✓）

| 资源 | 提供方 | 对我们的价值 |
|---|---|---|
| **折扣合约审计** ⭐ | **TonBit** | **直接覆盖 M1（ 审计）的大部分成本** ✓✓ |
| AWS 最高 **** credits | AWS | 基础设施成本 → 0 |
| TON API / RPC credits | TON API | 运行成本 → 0 |
| 钱包集成 + 联合营销 | SafePal | 分发 |
| **最高  USDT** | **STON.fi grants**（滚动申请） | 小额现金流 ✓ |

## C. 行动顺序（建议）

1. **注册 TON Builders Portal** ✓（强制第一步；把仓库、demo、白皮书、Grant 稿内容填进项目页）。
2. **提交"非商业轨 / 公共品"申请** ✓（用上文 M1–M3：审计 + 预言机加固 + 开发者套件）。
3. **同时单独申请 TonBit 的折扣审计** ✓（这是**最快能拿到实质资源**的一条 ✓）。
4. 领取 **AWS / TON API credits** ✓（立刻降低烧钱 ✓）。
5. 持续参与生态（Hubs / Demo Days / 开发者频道）→ 争取被识别为 **Champion** ✓。

## D. ⚠️ 一个前置阻塞项（必须先解决）

**仓库目前是私有（private）** ✗ —— 而 grant 评审与审计**都要看代码** ✓。
⇒ 必须先决定：**① 开源**（推荐 ✓ —— "公共品"叙事本身要求开源 ✓，且这是加分项 ✓）或 **② 只读快照/受限访问**（可接受但弱 ✓）。
未决定前，申请无法真正投递 ✓。