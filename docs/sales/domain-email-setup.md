# 域名邮箱配置（`ppppp.space`）— 记录值可直接粘贴

> **目标**：让外联信从 **`everest@ppppp.space`**（而不是 Gmail 地址）发出 ✓
> **为什么值得**：① **国际送达率** ② **可信度** —— 收件人是 Tokinvest（VARA 持牌、CEO 是前 DLA Piper 合伙人 ✓）和 DMCC 生态总监 ✓，用 Gmail 地址谈**掉一档** ✗
> **现状**（已核实 ✓）：域名在**阿里云**注册 ✓；**DNS 也在阿里云** ✗（Vercel 显示 Nameservers = "Third Party"，且 Vercel 无 DNS 记录 ✓）⇒ **记录要在阿里云 DNS 控制台加** ✓

---

## 0. 选哪家（**不是腾讯** ✗）

| 方案 | 价格 | 国际送达 | 建议 |
|---|---|---|---|
| **Google Workspace** ⭐ | ~$6–7/人/月 | **最好** ✓ | **推荐** ✓；顺带解决"应用专用密码"问题（Workspace 用 OAuth，不需要应用专用密码 ✓） |
| **Zoho Mail** | **免费**（1 用户）✓ | 良好 ✓ | 想要零成本就选它 ✓ |
| **腾讯企业邮箱 / 阿里云邮箱** | 免费档 ✓ | **国际机构收件人偏弱** ✗ | **不推荐** ✗ —— 冷外联的第一印象就靠发信域 ✓ |
| Microsoft 365 | ~$6/人/月 | 很好 ✓ | 与 Workspace 同级 ✓（若你更熟 Outlook ✓） |

> ⚠️ **别在阿里云顺手开"阿里云邮箱"** ✗ —— 你在阿里只是**注册域名** ✓，不必用它做邮局 ✓。

---

## 1. 【推荐】Google Workspace —— 要加的 DNS 记录

**在阿里云**：控制台 → **域名** → `ppppp.space` → **解析设置** → 添加记录 ✓
（⚠️ **不要动现有的 A / CNAME 记录** ✗ —— 那是网站解析 ✓）

| # | 主机记录 | 记录类型 | 记录值 | 优先级 | 说明 |
|---|---|---|---|---|---|
| 1 | `@` | TXT | `google-site-verification=…` | — | **Google 后台给你的**（每账号不同 ✓ 必须用它给的 ✓）|
| 2 | `@` | MX | `smtp.google.com` | **1** | 收信（Google 现行推荐就是单条 ✓）|
| 3 | `@` | TXT | `v=spf1 include:_spf.google.com ~all` | — | **SPF**（防伪造发信 ✓）|
| 4 | `google._domainkey` | TXT | `v=DKIM1; k=rsa; p=…` | — | **DKIM** —— **必须用 Google 后台生成的那串** ✓（很长 ✓，复制完整 ✓）|
| 5 | `_dmarc` | TXT | `v=DMARC1; p=none; rua=mailto:everest9812@gmail.com; fo=1` | — | **DMARC**：先 `p=none` **只观察不拦截** ✓（稳定后再收紧 ✓）|

### ⚠️ 一个必须注意的坑（很容易踩 ✗）
**SPF 只能有一条** ✗ —— 如果 `@` 上**已经存在 TXT 记录**（比如 Google 的域名验证 ✓、或其他服务的验证 ✓），
**不能再加一条 SPF** ✗✓ ⇒ 要么**合并成一条** TXT，要么把 SPF 放到**独立的一条** TXT 里 ✓
（域名验证的 TXT 和 SPF 的 TXT **可以是两条** ✓，但**两条 SPF 会失效** ✗✓ —— 加完请让我验一遍 ✓）

---

## 2. 【免费】Zoho Mail —— 要加的 DNS 记录

| # | 主机记录 | 类型 | 记录值 | 优先级 |
|---|---|---|---|---|
| 1 | `@` | TXT | `zoho-verification=…`（Zoho 给的 ✓）| — |
| 2 | `@` | MX | `mx.zoho.com` | 10 |
| 3 | `@` | MX | `mx2.zoho.com` | 20 |
| 4 | `@` | MX | `mx3.zoho.com` | 50 |
| 5 | `@` | TXT | `v=spf1 include:zoho.com ~all` | — |
| 6 | `zmail._domainkey` | TXT | Zoho 后台生成的 DKIM 值 ✓ | — |
| 7 | `_dmarc` | TXT | `v=DMARC1; p=none; rua=mailto:everest9812@gmail.com; fo=1` | — |

---

## 3. 步骤（以 Workspace 为例）

```
1  注册 Google Workspace（要付款 + 验证域名所有权 ✓）—— ★ 这一步必须你本人做 ✗（涉及支付与身份 ✓）
2  创建一个用户：everest@ppppp.space（另可加 hello@ / contact@ 作为别名 ✓）
3  在 Workspace 后台 → 应用 → Gmail → 验证 → 生成 DKIM 密钥（复制那串 ✓）
4  在【阿里云 DNS】把上面 5 条记录加进去 ✓
5  回 Workspace 后台点"验证"→ 通过 ✓
6  在 Workspace 的 Gmail 里正常发信即走你的域名 ✓（不需要应用专用密码 ✓）
```

**可选（更省事的混合用法 ✓）**：如果不想换邮箱客户端 ✓，可以在你**现有 Gmail**里
「设置 → 账号 → 用其他地址发信（Send mail as）」添加 `everest@ppppp.space` ✓ —— 但这需要 Workspace 的 SMTP 凭据 ✓，且**送达率仍算 Workspace** ✓。

---

## 4. 分工（我能做的 vs 必须你做的）

| 事项 | 谁 |
|---|---|
| 给出**逐条 DNS 记录值**（本文件 ✓）| ✅ **我** |
| 配置完成后**验证** MX / SPF / DKIM / DMARC 是否正确（我跑 DNS 查询核对 ✓）| ✅ **我** |
| 检查 SPF 是否**重复**（那是最常见的失败原因 ✗✓）| ✅ **我** |
| 把发信地址更新进**外联信 + one-pager + grant 稿** | ✅ **我** |
| 注册邮箱服务（**要付款 + 验证所有权**）| ❌ **必须你**（我没有你的支付/账号 ✓）|
| 在**阿里云 DNS 控制台**粘贴记录 | ❌ **必须你**（我没有阿里云权限 ✓，已核实 DNS 不在 Vercel ✗）|

---

## 5. ⚠️ 两件并行的要紧事

1. **Gmail 应用专用密码 `xsib…ccat` 请确认已删除** ✗ —— `myaccount.google.com` → 安全性 → 应用专用密码 → 删除 ✓
   （**IMAP 权限 = 能读你整个邮箱** ✗；而**邮箱是所有账号的万能钥匙** ✗✓ —— 这比 bot token 严重得多 ✓）
   若你要走 Workspace ✓，**新邮箱不需要应用专用密码** ✓ ⇒ 泄露面直接消失 ✓✓
2. **在外联信发出前，把签名换成 `everest@ppppp.space`** ✓ —— 我用一条命令就能全改 ✓（**你说一声** ✓）

---

## 6. 配置好之后（我来做）
```bash
# 我会跑这些核对，并把结果给你
nslookup -type=MX  ppppp.space          # 收信是否指向新邮局
nslookup -type=TXT ppppp.space          # SPF 是否唯一且正确
nslookup -type=TXT google._domainkey.ppppp.space   # DKIM 是否生效
nslookup -type=TXT _dmarc.ppppp.space   # DMARC 是否存在
```
**全部通过后再发外联信** ✓ —— 否则第一封就进垃圾箱 ✓，那五个目标就浪费了 ✓。
