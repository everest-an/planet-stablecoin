# 开源前自查清单（Grant / GitHub 公开）

> **为什么需要**：TON grant 的评审与审计**都要看代码** ✓，但仓库目前**私有** ✗。
> 公开是加分项 ✓（"公共品"叙事要求开源 ✓），但**一旦公开就无法收回** ✗ ⇒ 先过这张表。
> ⚠️ **最重要的两条在最前面** —— 其余都好补救，这两条坏了没法补救 ✗。

---

## 🔴 A. 绝对不能公开的（先处理，再谈开源）

| # | 内容 | 为什么 |
|---|---|---|
| **A1** | **`docs/sales/`（目标名单、外联邮件）** ✗✗ | 这是**你的商业策略与客户名单** ✓ —— 公开 = 把客户和话术送给竞争对手 ✗ |
| **A2** | **`docs/gtm-tech-service.md`（定价、成本、打法）** ✗✗ | 同上：**报价与毛利结构** ✗ |
| **A3** | **`docs/economics-reality-check.md` / `path-forward.md`** ⚠️ | 内容是**诚实的自我否定**（"经济模型不成立"）✓ —— 对**投资人/客户**是优点 ✓，对**猎奇者/竞对**是弹药 ✗。**建议保留但移入私有目录** ✓ |
| **A4** | **`docs/HANDOFF.md`（唯一可信状态）** ✗ | 内部交接文档（含运营细节、地址、待办）✓ —— **私有** ✓ |
| **A5** | **`docs/grants/`** ⚠️ | 申请稿本身可公开 ✓（公共品叙事 ✓），但**预算与里程碑**先按需处理 ✓ |

**做法**：把 A1–A4 移到**单独的私有仓库** ✗ 或用 `.git` 子模块 ✗ —— hmm，最简单：**开源时用一份"裁剪后的快照"** ✓（只含 `ton/`、`relayer/`、`web/`、公开文档 ✓），**不是把整个私有仓转公开** ✗✓。**推荐这个** ✓。

---

## 🔴 B. 密钥与凭据（历史里也要清 ✗）

| # | 检查项 | 怎么查 |
|---|---|---|
| B1 | **助记词 / 私钥**（`TON_WALLET_MNEMONIC`、`RELAYER_MNEMONIC`） | 全仓 + **git 历史** 搜 24 词模式 + `mnemonic` ✓ |
| B2 | **Telegram bot token** ⚠️ | **本项目曾暴露过** ✗ → **必须在 BotFather `/revoke` 换新** ✓，并确认仓库/历史里没有 ✓ |
| B3 | **TON API key** | 搜 `d09cee` / `api_key` ✓ —— 虽是**测试网** key ✓（低风险 ✓），仍建议换 ✓ |
| B4 | `.env` / `*.local` / `wallets.toml` | `git log --all --name-only \| findstr env` ✓ |
| B5 | **任何真实资金地址的私钥** | 逐条确认 ✓ |

**工具**：`gitleaks` / `trufflehog` 扫**全部历史** ✓（不只看当前文件 ✗ —— 提交过的密钥**永久留在历史里** ✗✓）。

---

## 🟡 C. 工程与合规

| # | 项 | 状态 |
|---|---|---|
| C1 | **LICENSE** | ⬜ **缺失** ✗ —— 开源必须加 ✓（建议 MIT 或 Apache-2.0 ✓；若想保留商业授权 → Apache-2.0 + NOTICE ✓）|
| C2 | **README** 明确"PoC / 无背书 / 非稳定币 / 不要用于真钱" ✓ | ✅ 已有 ✓（保留 ✓）|
| C3 | `.gitignore` 覆盖密钥/本地配置 | ✅ 已有 `assets.json` ✓ 需补 `.env` ✓ |
| C4 | CI 是否**泄露 secrets**（日志里打印助记词 ✗） | 检查 workflow 里有无 `echo ${{ secrets.* }}` ✗ |
| C5 | 第三方代码的许可（vendored TEP-74 ✓ 来自 tolk-bench ✓） | 需在 NOTICE 里**标注来源与许可** ✓ |
| C6 | 依赖漏洞（`npm audit`） | 跑一次 ✓ |
| C7 | **公开的 `web/pitch/`**（含**报价** ✗） | ⚠️ 它是 **noindex** ✓ 但**任何人都能访问** ✗ ⇒ 若不想公开报价 → 移出站点或用口令 ✓ |

---

## 🟢 D. 开源后要做的

| # | 项 |
|---|---|
| D1 | 加 `CONTRIBUTING.md` + `SECURITY.md`（漏洞如何报 ✓）|
| D2 | 用**镜像仓**开源（私有主仓 → 公开镜像 ✓），避免历史泄露 ✓✓ **推荐这个流程** ✓ |
| D3 | 在 README 顶部写清**状态标签**（PoC / testnet / 未审计 ✓）|
| D4 | 把 `audit-prep.md` 作为**公共品**发布 ✓（这正是 grant 的卖点 ✓）|

---

## ✅ 建议的最省做法（一步到位）

```
1. 建一个公开镜像仓（planet-public）
2. 只同步：ton/ · relayer/ · web/ · README · docs/{whitepaper,audit-prep,adr,deploy-runbook,contract-review,security,oracle-ton}
3. 排除：docs/{sales,grants,HANDOFF,economics-reality-check,gtm-tech-service,path-forward,positioning-v2}
4. 加 LICENSE (Apache-2.0) + NOTICE（vendor 来源）+ SECURITY.md
5. 跑 gitleaks 确认镜像仓**全历史**干净 ✓
6. grant 申请里填**镜像仓**链接 ✓
```

**这样：代码公开 ✓（满足 grant/审计 ✓）、策略保密 ✓（客户名单不外泄 ✓）、历史干净 ✓。**

---

## ⚠️ 一句话提醒

**不要"把私有仓直接转公开"** ✗ —— git 历史里的密钥、客户名单、内部判断**都会跟着一起公开** ✗✓。
**用"裁剪快照 + 干净镜像"** ✓ —— 多花 30 分钟，省掉不可逆的损失 ✓。
