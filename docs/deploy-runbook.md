# 部署 / 迁移 Runbook（TON testnet → mainnet）

> 合约**不可原地升级**（见 `docs/adr/0001-immutable-core-upgradeable-oracle-adapter.md`），
> 因此**唯一**合法的变更路径就是本 runbook：**重新部署 + 迁移 + 全量地址刷新**。
> 任何"悄悄换 code"的做法都被 ADR-0001 否决。

## 0. 前置条件（缺一不可）

- [ ] **部署钱包有足够 TON**。实测：整套重建需 **~0.5–1.0 TON**（含 gas + 存储租金 + 时间锁往返）。
      ⚠️ **附带值会被永久困在合约里**（不可退回）—— 今天旧 Core 里就压着 **1.63 TON**。
      所以**不要沿用历史的大额附带**（0.2/0.15/0.12），用下面的精简值。
      测试网领水：`@testgiver_ton_bot` → 发给部署钱包地址。
      部署钱包：`0QBW4GNM-XpAIuIzwrupQKqVOLILHfP6lnD_Xk04L9Yx6Qol`
- [ ] 目标 commit 的 **CI 全绿**（`ton-build.yml`：Acton 测试 + 覆盖率 ≥90）。
- [ ] 记下**旧地址全集**（迁移后要保留为 fallback / 写进历史，不要覆盖丢失）。

## 1. 精简附带值（已改在脚本里）

| 步骤 | 脚本 | 附带值 |
|---|---|---|
| Core 部署 | `scripts/deploy.tolk` | `0.08` |
| PLT minter 部署 | `scripts/deploy.tolk` | `0.05` |
| Core → minter 接线 | `scripts/deploy.tolk` | `0.05` |
| 时间锁部署 | `scripts/deploy_core_owner.tolk` | `0.08` |
| Core owner 迁移 | `scripts/deploy_core_owner.tolk` | `0.05` |
| Gov / PLTG / genesis | `scripts/deploy_gov.tolk` | `0.05` / `0.15` |
| Bond | `scripts/deploy_bond.tolk` | `0.08` |

> `PlanetBasket` **已弃用（BK-1）**，不再部署（Core 自带篮子）。

## 2. 执行顺序

> Acton **只能在 CI 跑**（原生 Windows 不支持）⇒ 每步都是 `gh workflow run …`，然后从日志里取地址。
> **顺序不可颠倒**：必须在 owner 迁移到时间锁**之前**完成篮子配置 / 签名者注册（那几个是 owner 动作，之后就得走时间锁往返）。

```powershell
# ① Core + PLT minter + 接线   → 日志取 <NEW_CORE> / <NEW_PLT_MINTER>
gh workflow run ton-deploy.yml

# ② 配 14 资产篮子 + 注册热密钥签名者（owner 私钥 = TON_WALLET_MNEMONIC）
#    先把 relayer-push.yml 的 PLANET_CORE 指到 <NEW_CORE>，或给该 workflow 加 PLANET_CORE 输入
gh workflow run relayer-push.yml          # configure + register 使用 owner key；push 使用 hot key

# ③ 新时间锁 + Core owner 迁移 → 先把 deploy_core_owner.tolk 里的 Core 地址改成 <NEW_CORE>
gh workflow run core-owner.yml            # 日志取 <NEW_TIMELOCK>

# ④ Gov + PLTG（含 genesis 分配）
gh workflow run gov-deploy.yml            # 日志取 <NEW_GOV> / <NEW_PLTG_MINTER>

# ⑤ Bond（BD-1/2/3 修复）
gh workflow run bond-deploy.yml           # 日志取 <NEW_BOND>

# ⑥ 首次推送真实价格（hot key），确认 PPI 更新
gh workflow run relayer-push.yml
```

**跳过**：`Fund`（本次审查未改动）、`Basket`（已弃用）。

## 3. 地址刷新清单（**必须全部更新**）

- [ ] `relayer-push.yml` → `PLANET_CORE`
- [ ] `web/api/v1/status.js` → `CORE`（+ `CORE_FALLBACK` = 旧 Core，保留兜底）
- [ ] `web/api/v1/oracle.js` → `CORE`（+ `CORE_FALLBACK`）
- [ ] `web/api/tg-webhook.js` / `web/api/*.js` → 任何写死的 Core
- [ ] `web/index.html`（合约表）、`web/dashboard.html`
- [ ] `app-tg/`（若地址经 `VITE_*` 注入 → Vercel 环境变量）
- [ ] `docs/HANDOFF.md`（唯一可信状态：完整地址表 + 版本号）
- [ ] `docs/mainnet-readiness.md`（部署验证章节）

## 4. 验证清单（部署后逐条核对）

链上 get-method：

- [ ] `PlanetCore.assetCount() == 14`
- [ ] `PlanetCore.ppi()` 合理（≈1.0，非 0）
- [ ] `PlanetCore.baseLocked() == true`
- [ ] `PlanetCore.signerCount() == 1`、`signerAt(0) == 热钱包 pubkey`、`threshold() == 1`
- [ ] `PlanetCore.owner() == <NEW_TIMELOCK>`
- [ ] `PlanetTimelock.tlOwner() == 部署钱包`、`delay() == 60`
- [ ] `JettonMinter.adminAddress() == <NEW_CORE>`

线上：

- [ ] `https://ppppp.space/api/v1/status` 返回新 `core`、`assetCount=14`、`partial=false`
- [ ] `https://ppppp.space/api/v1/oracle` → `healthy=true`、`fresh=true`、`weightsValid=true`、`baseLocked=true`
- [ ] 站点各页 200（`/`、`/dashboard`、`/reports`、`/docs`、`/methodology`、`/faq`）
- [ ] TG bot `/status` 显示新数据

## 5. 已知风险 / 注意

- **owner 迁移后再改任何 owner 参数都要走时间锁**：`Propose → 等 delay(60s) → Execute`（参考 `relayer.mjs setsigner|settimelockowner`）。
- **陈旧度是全局的**（非 per-asset）：更新任一资产即刷新全局时间戳 —— 按需推送前须先修（见 ADR-0001 后续工作）。
- **附带 TON 不可退回**：宁少勿多；主网前给合约加 owner 扫出路径。
- **回滚**：旧 Core 保留为 `CORE_FALLBACK`（只读兜底）；若新栈验证失败，把 API 指回旧 Core，不要删除旧地址记录。

## 6. 幂等性陷阱（本次重建实际踩到）

合约地址由 **code + storage** 共同决定，因此：

- **代码改过的合约**（Core / Timelock / Gov / Bond）⇒ 地址必然变化 ⇒ 正常重新部署 ✓
- **代码与 storage 都没变的合约** ⇒ **地址完全相同** ✗ ⇒ `deploy()` 退化成 **no-op** ✗ ——
  此时脚本里任何**无条件的副作用**都会**重复发生** ✗✗

**本次实际发生**：`deploy_gov.tolk` 的 genesis 铸造是**无条件**的 ✗，而 PLTG minter 地址未变 ✗
⇒ **PLTG 供应从 1e15 变成 2e15（1e9 → 2e9 PLTG）** ✗。
已修：铸造前先读 `totalSupply`，非 0 则跳过 ✓。

**规则**：部署脚本里的每一次 mint / 转账 / 配置，都必须**先读链上状态再决定** ✓。