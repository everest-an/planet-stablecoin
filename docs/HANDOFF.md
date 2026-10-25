# Planet — 会话交接（HANDOFF）

> 目的：让下一个会话（或另一位协作者）能在**不重读历史**的情况下继续。
> 仓库即持久记忆；本文档 + `docs/*` 是唯一可信来源。

---

## 0. 当前状态（2026-10-25，**以此为准**）

> 本节覆盖下文所有更早的描述。下文（§1 起）是 **TON 时代**的记录，保留作设计依据，但不代表当前部署。

| 项 | 值 |
|---|---|
| 读链 | Arbitrum Sepolia（chainId 421614） |
| PlanetCore | `0x65362ef75028700855E842F903FF6FBD65A97f65` |
| PLT token（ERC-20） | `0x367e62f6fd68FDe2698A65022713Ef99ca9a4c80` |
| Timelock | `0x9e8a685090704A3cd41590594BA5cf281c0b020d` |
| 篮子 | 14 资产 · `weightSum = 1,000,000` · `baseLocked = true` |
| PPI | `1.003830`（2026-10-25 推送后，手算与链上一致） |
| 预言机 | 每小时 GitHub Actions（`.github/workflows/evm-push.yml`）→ `updatePrice` |
| 预言机信任级 | **1-of-1**；两条路径（`updatePrice` onlyRelayer / `updatePriceSigned`）**都已接线**，`SignedPriceOracle` 已部署，但 signer set 是 1-of-1（一个运营方持有全部密钥）|
| 站点 | 已切 EVM 只读：`/api/v1/status`、`/api/v1/oracle`、dashboard、landing ticker |
| 铸赎 UI | **`/app` 已上线**（零依赖、注入式钱包直连 Core）；TON Mini App 仍在 |
| PriceOracle | `0xFC560cB20875dB79b8bd8FBA96a1c78B5B69548e` |
| 抵押 | Circle 测试 USDC `0x75faf114…AA4d`（6 位）；`mint` 用 `transferFrom` 拉取，`redeem` 付回并减少 `totalReserve` |
| 价格渠道 | **4 个独立渠道**：Yahoo（主）/ Sina / 腾讯 / 东财；实测 34 次渠道读取、12/14 资产有 2+ 渠道。规则是「主源 + 确认数（0.5% 容差）」，**不取中位数**；无确认 → `riskState=1`。可查：`/api/v1/sources` |
| 未部署 | PlanetBond / PlanetFund / PlanetGov / PLTG —— 仅存在于 `ton/` |
| 审计 | 无 |

### 本轮实际完成的（都有验证）

1. **EVM 读层**：`web/api/_evm.js` 零依赖（硬编码 selector + 静态字解码），`status`/`oracle`/dashboard/ticker 全部改读 EVM；一次批量 `eth_call` ≈ 330ms（原 TON 约 20s）。线上已验证 `ppi=1.00383`。
2. **预言机**：`relayer/push-evm.mjs` + 每小时 workflow；14 资产实推、0 失败、PPI 与手算一致。
3. **天然气数据修正**：`hf_NG` 报的是**更晚到期月**（3.502 vs 前月 3.05，差 14.8%），不是错号；已改为 Yahoo 单源，链上已由 3.276 纠正为 3.05。
4. **文案**：`index/docs/faq/methodology/openapi` 不再声称"链上验证 ed25519 签名"或"M-of-N"——EVM 核根本没有签名验证。

### 仍未做（下一会话从这里接）

- `web/whitepaper.html`：**27 处 TON 引用未处理**（§2 架构 / §7 oracle / §12 证据 / 附录 C 代码 / 附录 F 部署 / 地址）。**§3 PPI、§4 费率、§5 稳定、§9 治理、§10 代币经济不要动** —— 这些机制没变。
- **M-of-N 提高到 2-of-3**：合约与 oracle 都已就位，剩下的只是 `setSigners([a,b,c], 2)` + 把密钥分散到不同人手里。不需要重新部署。
- ~~合约级缺陷~~ **已修（2026-10-25 重新部署到新地址）**：`Asset.lastUpdate` 逐资产 + `mint` 看 `oldestActiveUpdate()`；`forcePrice()` 提供 >50% 的 timelock 旁路；`setRiskState()` 可冻结死掉的源。
- ~~铸赎 UI 迁到 EVM~~ **已做**：`web/app.html`（`/app`）零依赖直连，含 `approve` 两步流程。**`mint()` 现在通过 `transferFrom` 拉取测试 USDC**（Circle Arbitrum Sepolia `0x75faf114…AA4d`）；`redeem` 从储备付出并**减少** `totalReserve`（旧代码只付不减，背书被永久高估）。

### 页面已声明的诚实边界

站点现在明确写着：Arbitrum 部署**只读**、铸赎仍在 TON、预言机是**单个 relayer 地址**、`PlanetBond/Fund/Gov/PLTG` **未在 Arbitrum 部署**。不要为了好看把这几句改回去。

---

## 0. 一句话 + 链接

Planet（PLT）= 全球大宗商品购买力指数协议；当前实现为 **TON 上的合成指数代币 + TEP-74 代币 + 铸赎骨架**。
仓库：`github.com/everest-an/planet-stablecoin`（**private**），分支 `main`。
最后验证：`main`（TON 主线：合成指数 + TEP-74 PLT + 铸赎骨架 + 稳定机制 A/C1/C2/C3a+C3b + CAM + 签名预言机（多源 M-of-N，支持 M>2）+ 价格护栏 + 跨合约 `onBouncedMessage` + 域分离 + `SetOwner`/`PlanetTimelock` 时间锁 + **PlanetFund（ETF 基金：两阶段申购 + 托管 M-of-N 确认按 NAV 铸 + 赎回，含 TEP-74 份额收款/burn 的**无信任赎回**）+ 测试网 live**），本地 Acton 全绿（**252 测试 / 20 文件**，All files 96.1% 行 / 85.2% 分支 / 92.0% 评分；门禁 90 只升不降；待 push 后 CI 复核）。

---

## 1. 决策链（为什么是现在这样）

1. **目标**：发行即获客，早期无资金、**无主体（no legal entity）**、纯链上，优先服务"被市场挡住的人"。
2. **入口 = Telegram** → Telegram 官方《Blockchain Guidelines》硬性要求 Mini App 只能用 **TON + TON Connect** → **协议上 TON**（见 `GTM.md`）。
3. **语言 = Tolk**（TON 官方推荐；**Tact 已弃用**），工具链 **Acton**（不支持 Windows 原生，需 WSL/Linux/Docker）。
4. **预言机 = RedStone（主）+ DIA（备）**：**Pyth Core 已于 2026-08-26 停止支持 TON**。
5. **PLT 供应量以 JettonMinter 为唯一真相源**；赎回走 Phase 1 授权放款（见 `TON-MAPPING.md`）。
6. **多链**：暂缓，后期 hub-and-spoke（TON 枢纽 + BSC 镜像）。

详见：`GTM.md`、`PLAN-TON.md`、`TON-MAPPING.md`、`AUDIT.md`、`whitepaper-extracted.md`。

---

## 2. 仓库结构（关键文件）

```
docs/
  whitepaper-extracted.md   白皮书全文（18页，Node pdf-parse 抽取，v1）
  WHITEPAPER.md             白皮书 v1.5 工程增补正文（区分已实现/设计；含 CAM 隔离）
  PRODUCT-DESIGN.md         产品设计 v2（分层架构 L0–L4 + 架构稳健性分析）
  PRD.md                    产品需求 v0.2（TON 主线）
  peg-stability.md          稳定机制（借 AMM 设计，不自建 DEX）
  GTM.md                    定位/获客/Telegram 链限制/多链
  PLAN-TON.md               TON 迁移计划（Tolk/Acton/预言机/组件）
  TON-MAPPING.md            Solana→TON 映射 + 设计决策
  AUDIT.md                  可信任/审计清单（无主体信任模型）
  security.md               安全设计：威胁模型 + 加固（护栏/双签/多签 owner）
  oracle-ton.md             RedStone/DIA TON 接入调研 + oracle seam 设计
  burn-linkage.md           赎回链路（Core.Burn 与钱包 AskToBurn 脱节）设计方案
  ppi-multiasset.md         多资产 PPI 链上计算设计方案
  commodity-cam.md          Commodity Adapter Module（解耦 + 多维风控）设计稿
  HANDOFF.md                本文档
ton/
  Acton.toml                项目清单（[package]/[toolchain]/[contracts]/[import-mappings]/[wrappers.tolk]）
  contracts/planet_core.tolk    核心：链上 PPI（篮子 + computePpi）/铸赎/风控/费率/RTRA/Jetton/赎回镜像
  contracts/planet_basket.tolk  组合注册表：assetCount()/assetAt(i)
  contracts/oracle_state.tolk   预言机状态（ref cell，避开 1023-bit 限制）
  contracts/burn_mirror.tolk    赎回镜像消息（minter → Core，共享类型）
  contracts/planet_bond.tolk    稳定债券账本（open/subscribe/redeem；独立合约）
  contracts/jetton/*.tolk       PLT TEP-74（vendored 自 ton-blockchain/tolk-bench 01_jetton）
  contracts/tests/planet_core.test.tolk      纯数学 / 不变量
  contracts/tests/planet_core_flow.test.tolk PlanetCore 管理/暂停/费率/赎回
  contracts/tests/integration.test.tolk     部署 PlanetCore 集成
  contracts/tests/jetton_mint.test.tolk     全链路 mint / burn / transfer
  contracts/tests/jetton_minter_admin.test.tolk minter 管理路径 + TEP-89
  contracts/tests/oracle.test.tolk           预言机接缝（set / push / 重放）
  contracts/tests/planet_basket.test.tolk     组合注册表（assetCount/assetAt/SetAsset）
  contracts/tests/stability.test.tolk         稳定机制：分档费/限额/熔断
  contracts/tests/cam.test.tolk               CAM：SetCam/CamUpdate + 风险数据
  contracts/tests/signed_oracle.test.tolk     签名预言机：SetSigner/SignedPriceUpdate
  contracts/tests/bond.test.tolk             稳定债券：open/subscribe/redeem
  scripts/deploy.tolk       部署整套（core+minter+basket）；emulation 可跑，--net 上测试网
  README.md                 构建说明（WSL/Acton + Tact PoC）
app-tg/                     Telegram Mini App（Vite+React+TON Connect）
  src/App.tsx               读 PPI/储备/供应 + 篮子（权重条/涨跌/隐含 PPI）+ mint/burn UI
.github/workflows/ton-build.yml   3 job：Tolk(Acton) / TG Mini App / Tact PoC
legacy-solana/              Solana/Anchor 遗留实现 + 原 README（算法参考，非主线）
```

---

## 3. 当前验证状态（可核对）

- **CI 3 job 全绿**：`Tolk (Acton)`（build + wrapper + test --coverage + **deploy 脚本 emulation 冒烟**）、`TG Mini App`（vite build）、`Tact PoC`。
- **252 个测试（20 文件）**：纯数学/不变量 + 大额溢出 + 分档费 + 费率斜率/非对称赎回 + 套利返利 + 风险自适应 RTRA + 集成 + 全链路（mint/burn/transfer）+ 赎回镜像 + 链上多资产 PPI + CAM（+frozen 隔离）+ **多源预言机（阈值签名 2-of-N）** + **价格跳变护栏** + 风险基金 + 稳定债券 + **稳定债券↔Core 自动联动（0.95/0.97 滞回 + `PayBond` 风险基金扣付）** + **owner 迁移（SetOwner）** + 限额/熔断 + minter 管理/TEP-89 + PlanetBasket + **PlanetTimelock（延迟所有权）** + **M>2 多源（`SignedPriceUpdateN`，去重）**。
- **触发路径**：`.github/workflows/ton-build.yml` 监听 `ton/**` 与 `app-tg/**`。
- **覆盖率（基线棘轮）**：All files **92.0% score**（行 96.1% / 分支 85.2%）；门禁 `ton/Acton.toml [test.coverage] minimum-percent = 90`，**只升不降**。
- 近期提交：见分支 `feat/ton-coverage-gate-and-jetton-mint`（仓库整理 · 覆盖率棘轮 29→47→73→80 · mint tonAmount 修复 + 全链路/预言机测试）。

---

## 4. 如何构建与测试

**本地（推荐，快）**——需 WSL2 发行版（本机 WSL 已装但**无 distro**）：
```bash
wsl --install -d Ubuntu          # 一次性
# 在 WSL 内：
curl -LsSf https://github.com/ton-blockchain/acton/releases/latest/download/acton-installer.sh | sh
cd ton && acton build && acton wrapper --all && acton test --coverage
```
**不装 WSL**：靠 GitHub Actions（push 即编译，产物在 run artifact）。

**TG 小程序**（Node 本机可用）：
```bash
cd app-tg && npm install && npm run build
```

---

## 5. 已完成（Phase 0 + Phase 1 前端/合约）

- 白皮书全文归档。
- TON 合约：`PlanetCore`（PPI、铸赎、风控、暂停、**费率 30/50/20 + 10% 风险基金**、**RTRA 再平衡**、**mint→JettonMinter `MintNewJettons` 接线**、`setJettonMinter`）。
- **预言机接缝**：`SetOracle`/`OracleUpdatePrice`（仅注册 oracle 可推价 + 时间戳单调防重放；状态存 ref cell）。
- **溢出修复**：PPI 数学（mint/burn/fee/drift）中间量改用 257-bit `int`，消除 int64 在 ~$9M 存款 / ~920 万 PLT / 大额持仓处的静默溢出。
- **部署脚本** `ton/scripts/deploy.tolk`：部署 PlanetCore + PLT Minter + 接线 + PlanetBasket；emulation 可跑、CI 冒烟验证、`--net testnet` 可上链（需钱包）。
- **CAM 适配层（Phase A）**：每 index 注册 CAM（`SetCam`）；CAM 推标准化 `price/volatility/liquidity/riskState`（`CamUpdate`，时间戳单调）入 `CoreAsset`；**frozen 资产被排除出 PPI**（`computePpi` 按活跃资产重归一化）；新增**风险自适应 RTRA** `shouldRebalanceRisk`（frozen 不调仓、高波动/低流动性抬阈值）。
- **签名预言机接缝**：owner 设 ed25519 公钥（`SetSigner`）；relayer 发 `SignedPriceUpdate`（签名 R‖S + payload），Core 链上 `isSignatureValid` 验签 → 接真实数据源只需**一个公钥**。
- **风险基金（C3a）**：每笔手续费 10%（`RISK_SHARE_BPS`）从储备桶划入 `riskFund`；owner 可 `CoverDeficit` 回补储备（不足则拒绝）。
- **安全加固**：**价格跳变护栏**（>50% 拒，`116`）+ **多源预言机（M-of-N 阈值签名）**（`SetSigner`/`SetThreshold`；M≤2 用 `SignedPriceUpdate`，M>2 用 `SignedPriceUpdateN`；需 M 个不同来源，`117`）+ **`SetOwner`**（owner 迁移到多签钱包）+ **`PlanetTimelock`**（独立合约：Propose→delay→Execute，Core 零改动）+ `docs/security.md`。
- **稳定债券（C3b）**：独立 `PlanetBond` 合约（Core 存储 ref 已满）——`SetOpen`/`SetPremium`/`Subscribe`（face=principal×(1+premium)）/`Redeem`；mock 记账。
- **稳定债券 ↔ Core 自动联动（本次）**：
  - `Limits` ref cell 新增 `bond` / `bondOpen` / `bondPaid`（主 storage 仍是 4 refs，不超限）。
  - `PlanetCore.SetBond(bond)`（owner）：登记债券；`bondOpen=false` 复位，下一次 PPI 更新重新同步。
  - 每次 PPI 重算（`UpdatePrice` / `CamUpdate` / `OracleUpdateAssetPrice` / 签名路径）调用 `bondSync`：
    `PPI<0.95` 且当前关闭 → 发 `SetOpen(true)`；`PPI≥0.97` 且当前打开 → 发 `SetOpen(false)`。
    **边沿触发**（`bondOpen`）避免每次推价都发消息；2% 滞回避免阈值抖动；`PPI=0`（全冻结）不开售。
  - Bond 的 `SetOpen` 接受 **owner 或部署时写入的 core 地址**（自动触发权限）。
  - `SettleRedeem` 后 Bond → Core `PayBond(face)`；Core 从 `riskFund` **扣付上限=余额**
    （不足不抛错——真实付款已在链下完成，不能因记账不足回滚结算），累计 `bondPaid`。
  - 新消息：`SetBond` `0x10000019`、`PayBond` `0x20000015`；共享结构在 `contracts/bond_messages.tolk`。
  - 测试：`contracts/tests/bond_link.test.tolk`（13 个：wiring/清空、0.95 开、0.96 滞回、0.97 关、
    恰好 0.95 不开、pre-lock 路径、PPI=0 守卫、CAM 路径、签名路径、全额/封顶扣付、未接线/非 Bond 拒绝）。
- **稳定机制**：A（分档费 / 单笔限额 / >15% 冻结铸币）；**C1**（>5% 费率斜率 + 非对称赎回费）；**C2**（套利返利）；**C3a**（风险基金）。
- **链上多资产 PPI**：Core 存篮子（`map<int64,CoreAsset>`），oracle 推单资产价 → 链上 `computePpi`；`SetBasketAsset`/`OracleUpdateAssetPrice`/`LockBasePrices`；删 `OracleUpdatePrice`。
- **赎回链路打通**：钱包 `AskToBurn` → minter 减供应 → minter 镜像 `BurnMirror`(0x10000008) → Core 同步减 `totalSupply`/`totalReserve`（净额）；移除会双算的旧 `core.Burn`。
- `PlanetBasket`：链上组合注册表 + getter。
- **PLT TEP-74 Jetton**（minter + wallet，vendored）。
- TG 小程序：读 PPI/储备/供应 + **链上篮子**（权重条 + vs base 涨跌 + **篮子隐含 PPI 与链上 PPI 对照**）+ **mint UI** + **burn UI**（TEP-74 AskToBurn）。
- 107 测试 + 覆盖率（90.2% score，门禁 90）+ CI 门禁（棘轮，只升不降）+ 测试网 **mint/burn 端到端**验证。
- 文档：GTM / PLAN-TON / TON-MAPPING / AUDIT。

---

## 6. 待办 + 精确下一步 + 阻塞

| 优先级 | 任务 | 状态 / 阻塞 |
|---|---|---|
| ✅ | **Mint→Jetton 全链路集成测试**（emulator 部署 Minter+Wallet，发 Mint，断言 PLT 余额） | ✅ 完成（`contracts/tests/jetton_mint.test.tolk`，CI 绿） |
| ✅ | **覆盖率门禁（目标 80%）** | ✅ 超额达成：All files **90.2%**，门禁 `minimum-percent = 90`（起点 29.8% → 90%+） |
| ✅ | **安全：owner 多签 + 时间锁**（S2，`docs/security.md`） | ✅ 完成：`SetOwner` + **`PlanetTimelock`**（Propose→delay→Execute；其 owner 设为 TON 多签钱包 = M-of-N + 延迟） |
| ✅ | **多源预言机**（S1） | ✅ 完成：阈值签名集 **M-of-N**（`SetSigner`/`SetThreshold`；M≤2 `SignedPriceUpdate`，M>2 `SignedPriceUpdateN` + 去重 bitmask） |
| ✅ | **多源预言机交叉验证**（S3） | ✅ 完成：relayer 取 **Yahoo + Sina** 双独立源 → **中位数**推送，偏差异常则 `riskState=frozen`。链上实测 spread 0.04–0.10%。 |
| P2 | **真实数据源接入**（RedStone/DIA） | 🟡 ②签名式（`SetSigner`+`SignedPriceUpdate`）已达**双源交叉验证**（Yahoo+Sina）；接 RedStone/DIA 只需其 endpoint/key（本环境不可达）。①注册式 CAM/`SetCam` 接缝亦就绪。 |
| ✅ | **赎回链路打通**（Core 与钱包 burn 脱节） | ✅ 完成：minter 镜像 `BurnMirror` → Core（`docs/burn-linkage.md` 方案 A）；旧 `core.Burn` 已移除 |
| ✅ | **多资产 PPI 计算**（按篮子权重链上算，替代单值 `currentPpi`） | ✅ 完成（`docs/ppi-multiasset.md` 方案 (i)；前端读 Core；未做 Basket 镜像） |
| P2 | **CAM 插件层**（每商品独立适配器 → 标准化 价格/波动率/流动性/风险；解耦+隔离） | 🟡 设计稿就绪 `docs/commodity-cam.md`；建议先做 **Phase A**（MockCam + 风险自适应 RTRA，纯代码可验证），**待批复** |
| ✅ | **CAM 插件层（Phase A）** | ✅ 完成：`SetCam`/`CamUpdate` + 每资产风险数据 + 风险自适应 RTRA（`cam.test.tolk`）；真实 CAM 数据源仍待外部 |
| ✅ | **协议稳定机制** | A ✅ + C1 ✅ + C2 ✅ + C3a ✅（风险基金）+ **C3b ✅（稳定债券 + Core 自动触发 + 风险基金结算扣付）**。剩余：真实付款、到期阶梯、`BOND_CAP`（mock 记账阶段） |
| ✅ | **测试网部署** | ✅ 已上线 TON testnet（`ton-deploy.yml`）；地址见 §11；数据源 `relayer-push.yml` |
| P3 | 多签 + 时间锁迁移（owner 权限点：SetPaused/SetJettonMinter/SetAsset/UpdatePrice） | 部署后配置 |
| P3 | 第三方审计（Halborn/Certora）、漏洞赏金、形式化验证 | 外部机构 |

**下一步最顺（纯代码）**：核心合约能力已较完整（链上 PPI / 赎回 / 预言机接缝 / 部署脚本）；可继续 A5 前端打磨，或接 RedStone/DIA（需外部 adapter 地址+feed_id）与测试网部署（需有资金钱包）。

---

## 7. Tolk 踩坑速查（**重要**，省下重复试错）

- **类型必须定宽**才能序列化：字段/message 不能用 `int`，用 `int64`/`uint64`/`coins`。
- **存储**：`fun Storage.load() { return Storage.fromCell(contract.getData()) }` + `fun Storage.save(self) { contract.setData(self.toCell()) }`；用 `var storage = lazy Storage.load()` 改后 `storage.save()`。
- **message**：`struct (0x........) Name { ... }` 必须有 32 位 opcode；联合 `type AllowedMessage = A | B`。
- **入口** `fun onInternalMessage(in: InMessage)`；`in.senderAddress`/`in.valueCoins` 只在入口可见，辅助函数要显式传参。
- **map 取值**：`m.get(k)` 返回 `MapLookupResult<V>`（用 `isFound` + `loadValue()`）；直接取用 **`m.mustGet(k)`**。空 map 字面量 `[]`。
- **三元**两个分支类型必须一致（`-int64` 可能变 `int` → 报错）；避免 `? :` 混类型。
- **空 slice / forwardPayload**：`beginCell().endCell().beginParse()`。
- **类型转换**：`x as uint64` / `x as coins`。
- **wrapper getter 是 camelCase**：`get_jetton_data`→`getJettonData()`、`get_wallet_address`→`getWalletAddress(owner)`、`get_wallet_data`→`getWalletData()`；契约 code cell 用 **`build("ContractName")`** 取。
- **Jetton mint 必须给 `MintNewJettons.tonAmount > 0`**（minter 用它给新钱包部署+gas）；否则钱包不被充值。PlanetCore 用 `MINT_FORWARD_TON = ton("0.05")`。
- **测试部署顺序**：先 `testing.treasury()` → 部署 PlanetCore（jettonMinter 先占位）→ 部署 Minter（admin=PlanetCore 地址）→ `SetJettonMinter` 接线（绕过地址循环依赖）。
- **int64 静默溢出**：纯函数里 `a * b / c` 当 a、b 为 int64 会静默溢出（如 `net * PPI_SCALE` 在 ~$9M 存款处）；中间量改 `x as int`（257-bit），最后 `as int64` 收回。
- **跨合约共享 message 的字段类型**：TEP-74 侧是 `uint64`/`coins`，Planet 侧是 `int64`；共享结构（如 `BurnMirror`）统一设 `int64`，在 TEP-74 侧显式 `as int64` 转换。
- **顶层类型名冲突**：同一编译单元内两个合约各定义 `AllowedMessage` 会 `redefinition of symbol`（尤其一个文件 import 多个 wrapper 时）。各合约 message 联合用唯一名（本仓：basket 用 `BasketMessage`）。
- **`println`**：需 `import "@acton/io"`（`lib/io.tolk`）；脚本用 `@acton/emulation/scripts`（测试用 `@acton/emulation/testing`）。
- **存储 ≤ 1023 bits**：Storage 字段超限会编译报错（2 地址 + 6×int64 已 ~919bit）。超限就把子结构放进 **ref cell**（字段类型 `cell`，用 `Sub.fromCell(x)`/`x.toCell()` 读写；测试里用 `Sub { ... }.toCell()` 构造初始值）。
- **测试引用具名 struct**：需 `import` 其定义模块（如 `@contracts/oracle_state`）；**本项目无 `@contracts/types`**。跨文件共享类型抽成独立 `.tolk` 模块，避免与 wrapper 同名 struct 冲突。
- **构建**：`acton build` → `acton wrapper --all` → `acton test --coverage`。

---

## 8. 需外部输入（给下个会话的清单）

1. RedStone/DIA 在 TON 上**已部署的 adapter 地址**（`price_manager`/`price_feed`）+ 篮子对应的 **feed_id 清单**（详见 `docs/oracle-ton.md`）。
2. 一个**有资金的 TON 测试网钱包**（地址或 `wallets.toml`）。
3. （可选）WSL Ubuntu 安装（让合约测试秒级迭代）。

---

## 9. 下一次开局的推荐指令

> "读 `docs/HANDOFF.md`。仓库已整理（主线 `ton/`+`app-tg/`，Solana 归档 `legacy-solana/`）。**252 测试全绿**，覆盖率 96.1% 行 / 85.2% 分支 / 92.0% 评分（门禁 90，只升不降）；链上 PPI/赎回/稳定机制 A/C1/C2/C3a+C3b（**债券已与 Core 自动联动**）/CAM+隔离/签名预言机（M-of-N 多源，支持 M>2）/价格护栏/`SetOwner`+`PlanetTimelock` 时间锁 **+ PlanetFund（ETF 基金：两阶段申购 + 托管 M-of-N 确认按 NAV 铸 + 赎回，含 TEP-74 份额收款/burn 的无信任赎回）** 均已就绪，TON 测试网 live + mint/burn 端到端验证；白皮书 v1.5 + `docs/security.md`。下一步：真实数据源接入 / 外部审计 / 1:1（RWA 托管 + 合规）或前端完善。改动保持 CI 绿。"

---

## 10. 上下文管理教训（给 Agent）

- **别把大文档整页抓进主上下文**：用 `task` 派子智能体读 TON docs/大文件，只回收结论。
- **CI 日志用 grep 抓关键行**，别整段 dump。
- **中间结果写进仓库文件**（`docs/*`），让持久状态在磁盘而非上下文。
- 一次 2 万 token 的抓取 ≈ 几十轮对话；节流就是续命。

---

## 11. 测试网部署（LIVE，TON testnet）

已在 TON 测试网部署并跑通「真实行情 → 链上验签 → 链上 PPI」：

| 合约 | 地址 |
|---|---|
| **PlanetCore** | `kQBUIDOcKIQZS_AMXjOL3usH69c3HIo0YudLoo_49eE0X2NJ`（v1.7 代码：SetOwner + M-of-N 签名集 + M>2 + 治理级篮子管理 + **铸赎新鲜度护栏 MAX_ORACLE_AGE=6h**） |
| **PLT Minter** | `kQC6zZ83qploNLCy0MdUNhKkBD9Tx25N-xWF7iDHkd3IJ2k3`（admin = Core） |
| **PLTG Minter**（治理代币） | `kQDF0ixGco8WW4fqPB3XNdrNJ8vikFNkkyzKbz8hNJiFZ7OD`（固定供应 **1e9 PLTG** 已铸给部署钱包；已实测 `totalSupply=1e15`） |
| **PlanetGov**（质押/投票） | `kQAK5XcQdykCOrA2-uFraTxq9CFD1NNdK5W4QrwCexNcBYJ3`（质押 + **按份额分红**（对应费用桶）+ **按质押量投票**；已接 PLTG minter + `SetGovWallet`） |
| **PlanetBasket** | `kQAfGKn_UrUW8LQd92ZWy0h0BrCA_QTBhMqDA1M-PZtyv-r_` |
| **PlanetBond**（稳定债券） | `kQDMxJXroCmuxBw9Sw7oj9LhO9Y0mLxdPS3Tr4vY-sdq65hz`（isOpen=false, premium=5%；2026-10-19 链上复核 exit=0） |
| **PlanetFund**（ETF 基金） | `kQAYbx_u7I7yhcYU8yxeewWdh3gnS067IgaWeV8UlYItug1o`（两阶段申购 + 托管 M-of-N 确认按 NAV 铸 + 赎回；含 TEP-74 份额收款/burn 的无信任赎回） |
| **Fund JettonMinter** | `kQCSnnMlGUIEJvlI_NLG_x0wg-_ZX74AYFIxuLU4YpFeg1sk`（admin = PlanetFund） |
| **Core / Fund owner 时间锁** | `kQC_j4CrhPvbAX19_4C-PAoGNWBsaxj4GN5v6mIhGb7ctxQ1`（delay=**60s**；**`PlanetCore.owner` 已迁移至此**（实测 owner hash=`68d37e39…`）+ `PlanetFund.owner` 同址）→ 特权操作需 `Propose → 60s → Execute` |
| **PlanetTimelock**（24h，生产用） | `kQDc_iZ7Y8lQ1r_TxXhOXrhKVrjShyyOgp5c2pUwtGGGJGDe`（delay=86400） |
| **PlanetTimelock**（demo 0s / tl2） | `kQCMwDVPftkUbRWPMzJGCjoC4YXnFGfN3myTJ1rbeCuSdPAt` / `kQAwMedJ1wWbt-zKqw06Ssb7vdeLW_FIbAQd0NmAPjC5v2Mr` |
| 部署钱包 | `0QBW4GNM-XpAIuIzwrupQKqVOLILHfP6lnD_Xk04L9Yx6Qol`（v4r2；私钥 `ton/.secrets/`，已 gitignore） |
| **relayer 热钱包（密钥已分离）** | `0QC-PU0nxNjX1f1PVPb68Pg_oou-A7AHvFbTTgjdDWJ6_wp-`（v4r2；**与 owner/部署钱包分离**，只做推价签名；已注资 1 TON） |
| **预言机签名者** | `signerAt(0) = 0x75bc1c11697f7f2bbb61fd37fdde3dcc9ebdb20a05d3bc27f740cddc53d5c8dc`（= 上面的热钱包；**旧的 owner 密钥已从签名集合移除**） |

- **链上状态**：**篮子已扩到 14 个商品**（WTI/Brent/NatGas/Gold/Silver/Copper/Wheat/Corn/Soybean/Coffee/Lumber/Lithium/Water/Carbon，权重各 ≤15%、合计 100%），`assetCount=14`、**14/14 价格已上链并校验**、`signerAt(0)=0x9471…0f8f`（relayer 公钥，`threshold=1`）、`lastOracleUpdate` 持续更新、**`ppi≈1.000077`（随行情动态变化；基准=建仓价）**。**Core owner = 时间锁（60s）** → 改篮子/费率等特权操作需 `Propose→60s→Execute`。
- **治理级篮子管理（v1.6）**：`GovernanceAddAsset`（追加新商品，仅追加不覆盖）与 `GovernanceSetWeight`（改权重、**不动 basePrice**）——**在 `baseLocked` 之后仍可调整**，对齐白皮书「权重由 DAO 季度调整」。单类权重上限 `MAX_ASSET_WEIGHT=15%`。
- **真实推价已上链（含 bug 修复）**：relayer 双源（Yahoo+Sina）**中位数** → `SignedPriceUpdate` → Core 重算 PPI。**修复**：push body 此前仍是旧内联 `(sigR,sigS,payload)` 格式，而合约已改为 `SignedPriceUpdate{sig1: cell, sig2: cell, payload: cell}` → 推价从未生效（`lastOracleUpdate` 恒 0、PPI 恒 1.0、前端把 base 当 Now）。现 `lastOracleUpdate>0`、`assetAt(i).current` = 中位数、`risk=0`。
- **mint/burn 端到端**：`.github/workflows/e2e-test.yml`（`gh workflow run e2e-test.yml`）→ 铸 1.0 USDC 得 0.995 PLT，`AskToBurn` 0.5 → Core `supply` 995000→495000，链上实测通过。
- **时间锁**：`PlanetTimelock` 已部署（24h prod = `kQDc_iZ7...`，0s demo = `kQCMwDV...`）。
  - ✅ **propose→execute 投递** 链上验证（`tl2.delay=777`）；模拟器端到端亦有测试（`timelock.test.tolk`）。
  - ✅ **Core SetOwner 往返（链上验证）**：`SetOwner(Core, demo)` → demo timelock propose+execute `SetOwner(Core, deployer)` → Core 侧出现 **demo 来源交易**（`lt=100906097000012`）→ `core.owner` 恢复 = 部署钱包、`demo.hasPending=0`。**时间锁成功门控 Core owner 变更**。
  - ⚠️ 事故与修复：曾因**部署钱包 gas 耗尽（0.0116 TON）**导致所有发送静默失败（`warn: no seqno confirmation`）；已加 **`relayer.mjs check` gas 预检（低于 0.2 TON 直接报错）+ 每日 `relayer-check.yml` 告警**。充值后 `timelock-node.yml` 一次通过。
- **PlanetFund（ETF 基金）**：`ton/contracts/planet_fund.tolk` + `ton/contracts/tests/fund.test.tolk`。存储受 TON 硬限（内联 ≤1023 bits、序列化 ≤4 refs）约束，故 `orders`+`redeems` 合并进**一个** `ordersStore: cell`（`OrdersStore{mints,redeems}`），基金自身 jetton 钱包地址进 `fundWallet: cell`（`FundWalletRef`），owner 用 `SetFundWallet` 登记。
  - **无信任赎回（③ TEP-74）**：订阅者 `RequestRedeem` → 把 PLT 份额转到**基金自己的 jetton 钱包**（携带 `queryId == redeem orderId`）→ 钱包发 `TransferNotificationForRecipient` → 基金校验 `sender == fundWallet`（否则 `ERR_NOT_FUND_WALLET=213`）、把该 redeem 标记 `funded` 并 `AskToBurn` 销毁份额 → 之后 `ConfirmRedeem`（要求 `funded`，否则 `ERR_NOT_FUNDED=214`）才放款。**份额没真正离开用户就不能放款**。
  - **踩坑**：① 旧 `FundStorage` 4 refs，新增字段后内联 1255 bit 超 1023 → 必须合并 refs 且新地址走 ref；② Tolk **struct 是值语义**——把 `storage` 传进辅助函数修改**无效**（改的是副本），必须**就地赋值** `storage.x = …` 再 `save()`（曾因此 `SetFundWallet` 不生效）。
  - 部署：`.github/workflows/fund-deploy.yml`；owner→时间锁：`.github/workflows/fund-owner.yml`（**脚本内 Fund 地址为硬编码，redeploy 后须同步更新**）。
- **部署**：`.github/workflows/ton-deploy.yml`（`gh workflow run ton-deploy.yml`）。
- **数据源**：`.github/workflows/relayer-push.yml`（`gh workflow run relayer-push.yml`）→ `relayer/` 取 **Yahoo Finance** 行情（`CL=F`/`GC=F`/`HG=F`）→ 签 `PricePayload` → 发 `SignedPriceUpdate`（Core 链上 `isSignatureValid` 验签）→ 重算 PPI。
- **重要经验**：本机/公共 IP 对 toncenter 的 `sendBoc` 会被 **429 限流**；**部署与 relayer 都放在 CI 跑**（runner IP 不限），relayer 内置 429 重试即可。
- **前端对接**：把 `app-tg` 的 `VITE_PLANET_ADDRESS` / `VITE_PLT_MINTER_ADDRESS` 设为上表地址即可读真实状态。
- **前端已验证**：`app-tg` 浏览器实测读到真实篮子（WTI/Gold/Copper）与 PPI（修了 `Buffer` polyfill + RPC 429 重试）。
- **自动刷新**：`relayer-push.yml` 带**每日 cron**；`configure`/`register` 已**幂等**（已配置则跳过），只刷新价格。
- **gas 预算**：relayer 钱包 ~2 TON；每次 push ≈0.15 TON，用尽需重新注资。

## v1.8 rebuild (2026-10-07) - single address set after the contract-review fixes

The 10 contract-review fixes ship as NEW deployments (contracts are immutable; see
docs/adr/0001-immutable-core-upgradeable-oracle-adapter.md and docs/deploy-runbook.md).

| Contract | Address |
|---|---|
| PlanetCore | kQBUIDOcKIQZS_AMXjOL3usH69c3HIo0YudLoo_49eE0X2NJ |
| PLT Minter (admin = Core) | kQC6zZ83qploNLCy0MdUNhKkBD9Tx25N-xWF7iDHkd3IJ2k3 |
| PlanetTimelock (60s, Core owner) | kQC_j4CrhPvbAX19_4C-PAoGNWBsaxj4GN5v6mIhGb7ctxQ1 |
| PlanetGov | kQAK5XcQdykCOrA2-uFraTxqCFD1NNdK5W4QrwCexNcBYJ3 |
| PlanetBond | kQDMxJXroCmuxBw9Sw7oj9LhO9Y0mLxdPS3Tr4vY-sdq65hz (live; verified 2026-10-19; the kQDYY… entry is uninitialized on testnet) |
| PLTG Minter | kQDF0ixGco8WW4fqPB3XNdrNJ8vikFNkkyzKbz8hNJiFZ7OD (UNCHANGED address) |
| PlanetFund owner | kQBo0345y-RGi49-7WWaWAHyyNtiWe-JrT44iO3G9Cyom6YK (older timelock; Fund was not redeployed) |

Superseded (kept only as history / API fallback): Core kQAwzh3O-52-QBtB8JFFTjtNaKFhw-uJMkd-zdnoHoGibzcU,
PLT minter kQAMXsJdK0tklNy5x3Q8Jhw1dAkB6pw6ubREVprusamUcpbq, Gov kQD4eBl68N4Udu4YPEFrKSKL99mx0To1ihGd-DQP7b1EpaUV,
Basket kQAfGKn_UrUW8LQd92ZWy0h0BrCA_QTBhMqDA1M-PZtyv-r_ (deprecated, BK-1).

Verified on-chain: assetCount=14, baseLocked=true, signerCount=1/threshold=1, signerAt(0)=the hot key
(0x75bc1c11...), owner=the new Timelock, 14 prices pushed + verified. Live /api/v1/oracle: healthy=true, fresh=true, maxAgeSeconds=93600 (26h SLA).

Two real bugs were found and fixed during the rebuild:
1. relayer register would OVERWRITE an existing signer with the owner key (the daily push step would
   clobber the hot key and every push would fail ERR_BAD_SIG). Now it never overwrites; rotation goes
   through the timelock (setsigner). Commit d84649a.
2. deploy_gov.tolk minted the PLTG genesis supply unconditionally; the PLTG minter address is
   deterministic, so a re-run reused it and DOUBLED the supply (1e15 -> 2e15). Now guarded on
   totalSupply == 0. Commit 8ac3c6c. A cleanup burn (relayer burnjetton) can restore 1e15 exactly.
---

## v1.9 bond link (2026-10-19) �� redeploy note

Core and Bond code changed, and contracts are immutable (ADR-0001), so the live testnet
addresses in ��11 do **not** include this feature yet. A redeploy must follow the runbook:

1. Deploy the Core stack (`ton-deploy.yml`) and configure the basket/signers.
2. Migrate `PlanetCore.owner` to the timelock (`core-owner.yml`).
3. Deploy the Bond (`bond-deploy.yml` �� `scripts/deploy_bond.tolk`). The script bakes the
   live Core into `BondStorage.core` and, when the deployer is still the Core owner, calls
   `SetBond`; otherwise it prints the timelock body.
4. Wire Core �� Bond through the timelock: `SetBond(queryId=0, bond=<NEW_BOND>)`, op
   `0x10000019`, then `Propose �� delay �� Execute`.
5. Verify: `PlanetCore.bond() == <NEW_BOND>`, `PlanetBond.core() == <CORE>`,
   `PlanetCore.bondOpen() == false`, `PlanetCore.bondPaid() == 0`.

Storage stays legal: the three new fields live in the existing `limitsState` ref cell, so
`PlanetCore` remains at 4/4 refs and below 1023 bits.

Known remaining hardening: `PlanetBond` has no `SetOwner`, so its owner is the deployer key.
Add `SetOwner` (zero-address guarded) before production, or deploy the Bond with a multisig
as owner.

---

## v1.9 frontend polish (2026-10-19)

- `app-tg/`: oracle-age cell + 6h stale banner (mint is blocked on-chain when stale), PPI vs peg
  line, stability panel (bond sale/premium/face + risk fund), manual refresh, top error banner,
  first-load state, English copy, 320px no-overflow.
- `web/dashboard.html`: risk-fund + bond strip, stale oracle styling, responsive table (drops
  `#`/`BASE` ��640px, `��` ��360px; horizontal wrapper retained).
- `web/api/v1/status.js`: additive `bond: { open, paid }` when the Core getters exist (omitted on
  the live v1.8 Core, so the dashboard shows "��").
- Live Bond address corrected after on-chain verification: `kQDMxJXroCmuxBw9Sw7oj9LhO9Y0mLxdPS3Tr4vY-sdq65hz`
  (exit=0, premium 5%, totalIssued 0). The `kQDYY��` entry in the v1.8 rebuild table is uninitialized.
