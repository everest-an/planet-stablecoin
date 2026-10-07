# 公开仓清单（给 TON 看的那一份）

> **主体**：**珠峰控股集团（Everest Holdings Group）** —— 对 TON/grant/审计均可披露 ✓。
> **目标**：给 TON 生态、审计方、技术伙伴看**代码与公开文档** ✓；**不给**看商业策略与客户名单 ✗。
> **生成方式**：**必须用 `git archive`（只含已跟踪文件）** ✗✓ —— **不要复制工作目录** ✗。

---

## 🔴 0. 生成前必读（三条铁律）

1. **用 `git archive` / `git ls-files` 导出** ✓ —— 工作目录里有 `ton/.secrets/testnet-wallet.json`
   （**含 24 词助记词** ✗）和 `relayer/assets.json` 等**已 gitignore 文件** ✗。**复制目录 = 泄露助记词** ✗✗。
2. **公开仓的历史必须干净** ✗ —— 即使当前文件没问题，**曾经提交过的东西永久留在历史里** ✓。
   新建仓（n 个初始 commit ✓）而不是转公开 ✗；导出后跑 **gitleaks** 扫全历史 ✓。
3. **`.pdf` 与 `whitepaper-extracted.md` 不公开** ✗ —— 含**不实的 Certora/Halborn 审计声明** ✗（见下 §3）✓。

---

## ✅ 1. 公开（INCLUDE）

| 路径 | 为什么可以公开 |
|---|---|
| **`ton/`**（全部已跟踪文件）| 合约 + 测试 + 脚本 —— **这正是要给 TON 看的东西** ✓ |
| **`relayer/`** | 预言机 relayer（`assets.example.json` 是脱敏样例 ✓，真配置已 gitignore ✓）|
| **`app-tg/`** | Telegram Mini App ✓ |
| **`web/`**（**排除 `web/pitch/`** ✗）| 站点源码 + 报告 ✓ |
| **`.github/workflows/`** | CI（用 `secrets.*` ✓，无明文密钥 ✓；含的钱包地址本就是公开信息 ✓）|
| **`tools/`** | 月度报告 / oracle 监控脚本 ✓ |
| **`README.md`** | 已含 PoC/非稳定币声明 ✓ |
| **公开文档**：`audit-prep.md` ⭐ · `contract-review.md` ⭐ · `adr/0001-*.md` · `deploy-runbook.md` · `security.md` · `oracle-ton.md` · `ppi-multiasset.md` · `peg-stability.md` · `commodity-cam.md` · `burn-linkage.md` · `fund-contract-design.md` · `tokenized-etf-fund.md` · `design-pltg-governance.md` · `TON-MAPPING.md` · `PLAN-TON.md` · `PRODUCT-DESIGN.md` · `PRD.md` · `real-asset-1to1.md` · `custodian.md` · `compliance-checklist.md` · `competitive-comparison.md` · `mainnet-readiness.md` · `WHITEPAPER.md` | ⭐ `audit-prep.md` 与 `contract-review.md` 是**最强公共品** ✓（grant 的卖点就在这 ✓）|

**要新增**：`LICENSE`（建议 **Apache-2.0** ✓）· `NOTICE`（标注 vendored TEP-74 来源 ✓）· `SECURITY.md` · `CONTRIBUTING.md`

---

## ❌ 2. 不公开（EXCLUDE）

| 路径 | 为什么 |
|---|---|
| **`docs/sales/`** ✗✗ | **客户名单 + 外联话术** —— 公开 = 把客户送给竞对 ✗ |
| **`docs/gtm-tech-service.md`** ✗✗ | **定价 / 成本 / 打法** ✗ |
| **`docs/GTM.md`** ✗ | 零售 GTM 策略（内部 ✓）|
| **`docs/HANDOFF.md`** ✗ | 内部唯一可信状态（运营细节 ✓）|
| **`docs/grants/`** ✗ | 申请稿与清单（TON 是通过 portal 看 ✓，不需要放公开仓 ✓）|
| **`docs/economics-reality-check.md`** ✗ | 诚实的自我否定（**对审计是优点 ✓，对公众是弹药 ✗**）→ 建议私有 ✓ |
| **`docs/path-forward.md`** ✗ | 同上（含"现在不能对外发行"等内部判断 ✓）|
| **`docs/positioning-v2.md`** ✗ | 定位重构（含"v1 说不清客户为何赚钱"✓）|
| **`docs/hack-analysis.md`** ✗ · **`docs/AUDIT.md`** ✗ · **`docs/audit-report.md`** ✗ | 内部审计分析（其中可能含不实审计说法 ✗）|
| **`docs/PLAN.md`** ✗ | 早期内部计划（历史 ✓，不必公开 ✓）|
| **`Planet Stablecoin White Paper.pdf`** ✗✗✗ | **含虚假审计/形式化验证声明**（见 §3）✗ |
| **`docs/whitepaper-extracted.md`** ✗✗ | 同上（是那份 PDF 的文本 ✗）|
| **`legacy-solana/`** ✗ | 969 KB 死代码（Solana 遗留 ✓）→ 私有归档 ✓ |
| **`web/pitch/`** ✗ | **含报价** ✗（⚠️ 但它**已经在线上了** ✗ —— 见 §3）|
| 品牌 PNG（planet-v3/v4/v5）| 可选 ✗（品牌资产，非技术 ✓）|

---

## 🔴 3. 三件必须你拍板的事

| # | 问题 | 我的建议 |
|---|---|---|
| **3.1** | **PDF + `whitepaper-extracted.md` 含不实声明**：「已通过 **Certora** 形式化验证」「审计报告见 Planet_Audit_Report_v1.0.pdf」—— **从未发生** ✗ | **不公开** ✓；若要保留历史 → **先加显著更正页** ✓（"本文为早期版本，其中提到的审计/形式化验证**并未进行**" ✓）|
| **3.2** | **`ppppp.space/pitch/` 已公开**（含**你的报价** ✗） | 要么**撤下** ✓，要么**接受报价公开** ✓（做 B2B 技术输出，公开报价其实也能当"明码标价"✓ —— 但你就**没法对客户差别定价** ✗）|
| **3.3** | `ton/.secrets/testnet-wallet.json` 明文放在工作目录 | 建议**移到仓库外**（如密码管理器 ✓）—— 它是**测试网**钱包 ✓（风险低 ✓），但**绝不可用于主网** ✗（明文落盘 = 视为已泄露 ✓）|

---

## 🛠 4. 生成公开仓（可直接跑，我来做也行）

```bash
# 1) 建一个干净目录，只用 git 跟踪的文件（关键：不会带上 .secrets / assets.json）
git archive --format=tar HEAD | (mkdir -p ../planet-public && tar -x -C ../planet-public)

# 2) 移出不该公开的（上面 §2 的清单）
cd ../planet-public
rm -rf legacy-solana web/pitch
rm -f  "Planet Stablecoin White Paper.pdf"
rm -rf docs/sales docs/grants
rm -f  docs/{HANDOFF,GTM,economics-reality-check,path-forward,positioning-v2,hack-analysis,AUDIT,audit-report,PLAN,gtm-tech-service,whitepaper-extracted}.md
rm -f  planet-v*-*.png

# 3) 加许可证与安全策略
#    LICENSE=Apache-2.0, NOTICE(vendor 来源), SECURITY.md, CONTRIBUTING.md

# 4) 建新仓（新历史，不是转公开！）并扫一遍
cd ../planet-public && git init && git add -A && git commit -m "Planet — commodity index protocol (public mirror)"
gitleaks detect --no-git=false -v        # 必须 0 命中

# 5) 推到公开仓（新仓！），把链接填进 grant 申请
```

**验证清单**（推之前逐条确认）：
- [ ] `find . -name "*.json" | xargs grep -l mnemonic` **无结果** ✓
- [ ] 没有 `.secrets/`、`wallets.toml`、`assets.json`（真配置）✓
- [ ] `git log --all --diff-filter=A --name-only | grep -i secret` **无结果** ✓
- [ ] gitleaks **0 命中** ✓
- [ ] 没有客户名单 / 报价 ✓
- [ ] 没有 PDF / whitepaper-extracted ✓

---

## 5. 给 TON 看的"门面"建议

在公开仓 README 顶部放**四行**（他们最先看这个 ✓）：

```
Planet — an on-chain commodity purchasing-power index (TON, Tolk).
Maintainer: Everest Holdings Group (珠峰控股集团).
Status: testnet PoC · unaudited · synthetic index token · NOT a stablecoin · no reserve.
Read: docs/audit-prep.md (scope, invariants, trust model) · docs/contract-review.md (findings register)
```
> 一句话逻辑：**把"我们很诚实 + 我们工程扎实"直接摆在门口** ✓ —— 这正是 grant 评审和审计方最想看的 ✓。
