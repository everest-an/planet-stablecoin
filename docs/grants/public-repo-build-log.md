# 公开仓构建记录（可复现）

> **执行时间**：2026-10-07 · **主体**：Everest Holdings Group Co., Ltd.（珠峰控股集团）
> **规格**：`docs/grants/public-repo-manifest.md`（含/除清单）
> **结论**：**构建成功并验证通过** ✓ —— 可推送为公开仓 ✓

---

## 1. 构建命令（**可复现，照抄即可**）

```bash
cd <private-repo>
git archive --format=tar -o /tmp/planet.tar HEAD        # 只含已跟踪文件
mkdir -p /tmp/planet-public && tar -xf /tmp/planet.tar -C /tmp/planet-public
```

> ⚠️ **Windows/PowerShell 陷阱（本次实际踩到）** ✗：
> **不要用 `git archive ... | tar -x`** ✗ —— PowerShell 管道**传文本不传字节** ⇒ **tar 流被破坏** ✗
> （报 `Damaged tar archive (bad header checksum)`，只解出 2 个文件 ✗）。
> **必须**先 `-o` 落盘成文件，再 `tar -xf` ✓。

---

## 2. 验证结果（本次实测）

| # | 检查 | 结果 |
|---|---|---|
| 1 | 导出文件数 | **150 个 / 1023 KB** ✓ |
| 2 | 禁区路径（13 项） | **全部 absent** ✓✓ |
| 3 | 密钥扫描（150 个文件的真实内容） | **干净** ✓ —— 命中项全为 `${{ secrets.X }}` 引用 ✓，无明文值 ✓ |
| 4 | 公开文档 | 23 份 ✓（含 `audit-prep.md` / `contract-review.md` / `WHITEPAPER.md` / ADR ✓）|
| 5 | 商业文档 | **未包含** ✓（`docs/sales` · `gtm-tech-service.md` · `GTM.md` · `HANDOFF.md` · `economics-reality-check.md` · `legacy-solana` · `web/pitch` ✓）|
| 6 | `web/pitch/` 是否被公开页链接 | **无任何链接** ✓（仅直链可达 ✓）|

**关键一条**：`ton/.secrets/testnet-wallet.json`（**24 词助记词** ✗）**未出现在导出中** ✓✓ ——
由 `.gitattributes` 的 `export-ignore` **机制保证** ✓（不依赖人工记得删 ✓）。

---

## 3. 导出后的目录结构

```
.github/   app-tg/   docs/   relayer/   ton/   tools/   web/
.gitattributes   .gitignore   LICENSE   NOTICE   README.md   SECURITY.md
```

## 4. 下一步（推公开仓）

```bash
cd /tmp/planet-public
git init && git add -A
git commit -m "Planet - on-chain commodity purchasing-power index (public mirror)"
# 建议在公开仓再加一份仓库描述与 topics（ton, rwa, commodities, oracle）
gitleaks detect --no-git=false -v     # 期望 0 命中（本地若无 gitleaks 可先跳过，但建议跑一次）
git remote add origin <新公开仓 URL> && git push -u origin main
```

然后把链接回填到：
- `docs/grants/ton-grant-application.md` 的 `**Repo:**` 一行 ✓
- TON Builders Portal 的项目页 ✓

## 5. 未解决的小事（非阻塞）

- [ ] `NOTICE` 里需要补 **vendored TEP-74 的上游许可证**（`ton-blockchain/tolk-bench` ✓ 需核实 ✓）
- [ ] `SECURITY.md` 里的安全联系邮箱还是占位符 ✓
- [ ] 建议**每年**复跑一次本构建 + 扫描（依赖/文件会变 ✓）

---

## 6. INCIDENT 2026-10-07 - wrong push target, and the rule that prevents it

**What happened.** After building the mirror I copied the PRIVATE repo's `.git` into the mirror
directory so I could commit and push it. The mirror directory therefore inherited `origin` =
`everest-an/planet-stablecoin` (private), and the "public mirror" commit was pushed **to the private
repo**. Its remote `main` briefly became the mirror tree (150 files) instead of the full private
tree (206 files).

**Impact.** Private documents disappeared from the private repo's REMOTE. No secret was exposed: the
tree that was pushed was the mirror, which had already been verified clean. The public repo was not
affected.

**Repair.** `git push --force origin <known-good-sha>:main` from the intact local clone, then verified
by file counts and by checking that `docs/HANDOFF.md` and `docs/sales/` were back.

**The rule (why it happened).** Never share or copy a `.git` directory between two repos. A `.git`
carries the remote URL, so the target of a push is decided by whatever `.git` happens to be present -
not by your intention.

**The correct procedure (now the only one to use).**

1. `git archive --format=tar -o <tmp>.tar HEAD` in the private repo (tracked files only; no `.git`).
2. Extract to a scratch directory. **Never** copy `.git` into it.
3. `git clone https://github.com/everest-an/planet.git <pub>` - clone the PUBLIC repo.
4. Copy in ONLY the files that actually changed, then `git diff --stat` to confirm the sync.
5. `git add -A && git commit && git push` - a normal fast-forward. **No --force needed.**

**Checks to run after every publish.**
- `git -C <pub> ls-files | Measure-Object` -> the expected count (149)
- `git -C <pub> ls-files | Select-String 'testnet-wallet|\.secrets|docs/sales|docs/grants|HANDOFF|\.pdf` -> must be empty
- `git -C <pub> log --oneline -1` -> confirm the commit landed on the PUBLIC repo
- `git -C <private> ls-tree -r --name-only origin/main | Measure-Object` -> the FULL private count (206)