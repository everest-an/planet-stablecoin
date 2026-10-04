# Planet — 会话交接（HANDOFF）

> 目的：让下一个会话（或另一位协作者）能在**不重读历史**的情况下继续。
> 仓库即持久记忆；本文档 + `docs/*` 是唯一可信来源。

---

## 0. 一句话 + 链接

Planet（PLT）= 全球大宗商品购买力指数协议；当前实现为 **TON 上的合成指数代币 + TEP-74 代币 + 铸赎骨架**。
仓库：`github.com/everest-an/planet-stablecoin`（**private**），分支 `main`。
最后验证：`main`（PR #1 + 稳定机制 A/C1/C2/C3a + CAM + 签名预言机），CI 全绿（85 测试，覆盖率 90.5%）。

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
- **85 个测试（10 文件）**：纯数学/不变量 + 大额溢出 + 分档费 + 费率斜率/非对称赎回 + 套利返利 + 风险自适应 RTRA + 集成 + 全链路（mint/burn/transfer）+ 赎回镜像 + 链上多资产 PPI + CAM（+frozen 隔离）+ 签名预言机 + **风险基金** + 限额/熔断 + minter 管理/TEP-89 + PlanetBasket。
- **触发路径**：`.github/workflows/ton-build.yml` 监听 `ton/**` 与 `app-tg/**`。
- **覆盖率（基线棘轮）**：All files **90.5% score**（行 96.1% / 分支 79.0%）；`planet_core.tolk` **92.9%**、`planet_basket.tolk` 90.9%、JettonWallet 85.5%、JettonMinter 84.3%。门禁 `ton/Acton.toml [test.coverage] minimum-percent = 90`，**只升不降**（门禁已实证生效：测试编译失败时曾以 70.4% 拦下 CI）。
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
- TON 合约：`PlanetCore`（PPI、铸赎、风控、暂停、费率 45/30/25、**RTRA 再平衡**、**mint→JettonMinter `MintNewJettons` 接线**、`setJettonMinter`）。
- **预言机接缝**：`SetOracle`/`OracleUpdatePrice`（仅注册 oracle 可推价 + 时间戳单调防重放；状态存 ref cell）。
- **溢出修复**：PPI 数学（mint/burn/fee/drift）中间量改用 257-bit `int`，消除 int64 在 ~$9M 存款 / ~920 万 PLT / 大额持仓处的静默溢出。
- **部署脚本** `ton/scripts/deploy.tolk`：部署 PlanetCore + PLT Minter + 接线 + PlanetBasket；emulation 可跑、CI 冒烟验证、`--net testnet` 可上链（需钱包）。
- **CAM 适配层（Phase A）**：每 index 注册 CAM（`SetCam`）；CAM 推标准化 `price/volatility/liquidity/riskState`（`CamUpdate`，时间戳单调）入 `CoreAsset`；**frozen 资产被排除出 PPI**（`computePpi` 按活跃资产重归一化）；新增**风险自适应 RTRA** `shouldRebalanceRisk`（frozen 不调仓、高波动/低流动性抬阈值）。
- **签名预言机接缝**：owner 设 ed25519 公钥（`SetSigner`）；relayer 发 `SignedPriceUpdate`（签名 R‖S + payload），Core 链上 `isSignatureValid` 验签 → 接真实数据源只需**一个公钥**。
- **风险基金（C3a）**：每笔手续费 10%（`RISK_SHARE_BPS`）从储备桶划入 `riskFund`；owner 可 `CoverDeficit` 回补储备（不足则拒绝）。
- **稳定机制**：A（分档费 / 单笔限额 `SetLimits` / >15% 冻结铸币）；**C1**（>5% 费率斜率 + 下行非对称赎回费）；**C2**（opt-in 套利铸币返利 `SetArb`）。
- **链上多资产 PPI**：Core 存篮子（`map<int64,CoreAsset>`），oracle 推单资产价 → 链上 `computePpi`；`SetBasketAsset`/`OracleUpdateAssetPrice`/`LockBasePrices`；删 `OracleUpdatePrice`。
- **赎回链路打通**：钱包 `AskToBurn` → minter 减供应 → minter 镜像 `BurnMirror`(0x10000008) → Core 同步减 `totalSupply`/`totalReserve`（净额）；移除会双算的旧 `core.Burn`。
- `PlanetBasket`：链上组合注册表 + getter。
- **PLT TEP-74 Jetton**（minter + wallet，vendored）。
- TG 小程序：读 PPI/储备/供应 + **链上篮子**（权重条 + vs base 涨跌 + **篮子隐含 PPI 与链上 PPI 对照**）+ **mint UI** + **burn UI**（TEP-74 AskToBurn）。
- 85 测试 + 覆盖率（90.5% score，门禁 90）+ CI 门禁（棘轮，只升不降）。
- 文档：GTM / PLAN-TON / TON-MAPPING / AUDIT。

---

## 6. 待办 + 精确下一步 + 阻塞

| 优先级 | 任务 | 状态 / 阻塞 |
|---|---|---|
| ✅ | **Mint→Jetton 全链路集成测试**（emulator 部署 Minter+Wallet，发 Mint，断言 PLT 余额） | ✅ 完成（`contracts/tests/jetton_mint.test.tolk`，CI 绿） |
| ✅ | **覆盖率门禁（目标 80%）** | ✅ 超额达成：All files **90.5%**，门禁 `minimum-percent = 90`（起点 29.8% → 90.5%） |
| P2 | **真实数据源接入**（RedStone/DIA） | 🟡 两条接缝**已就绪并测试**：①注册 CAM/报告者地址（`SetCam`）；②**签名更新**（`SetSigner`+`SignedPriceUpdate`，链上 ed25519 验签）。外部只需**一个公钥**或 adapter 地址 + feed_id |
| ✅ | **赎回链路打通**（Core 与钱包 burn 脱节） | ✅ 完成：minter 镜像 `BurnMirror` → Core（`docs/burn-linkage.md` 方案 A）；旧 `core.Burn` 已移除 |
| ✅ | **多资产 PPI 计算**（按篮子权重链上算，替代单值 `currentPpi`） | ✅ 完成（`docs/ppi-multiasset.md` 方案 (i)；前端读 Core；未做 Basket 镜像） |
| P2 | **CAM 插件层**（每商品独立适配器 → 标准化 价格/波动率/流动性/风险；解耦+隔离） | 🟡 设计稿就绪 `docs/commodity-cam.md`；建议先做 **Phase A**（MockCam + 风险自适应 RTRA，纯代码可验证），**待批复** |
| ✅ | **CAM 插件层（Phase A）** | ✅ 完成：`SetCam`/`CamUpdate` + 每资产风险数据 + 风险自适应 RTRA（`cam.test.tolk`）；真实 CAM 数据源仍待外部 |
| P2 | **协议稳定机制** | A ✅ + C1 ✅ + C2 ✅ + **C3a 风险基金 ✅**；**C3b 稳定债券 待做**（需独立 `PlanetBond` 合约：Core 存储 ref 已用满 4/4 且无真实 USDC 托管） |
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

> "读 `docs/HANDOFF.md`。仓库已整理（主线 `ton/`+`app-tg/`，Solana 归档 `legacy-solana/`）。85 测试全绿，覆盖率 90.5%（门禁 90，只升不降）；链上多资产 PPI、赎回镜像、稳定机制 A/C1/C2/C3a（风险基金）、CAM+隔离、签名预言机验签均已就绪；白皮书 v1.5 见 `docs/WHITEPAPER.md`。下一步：C3b 稳定债券（独立合约）或接真实数据源（只需公钥）。改动保持 CI 绿。"

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
| **PlanetCore** | `kQAyzbletVLCFV7IsR1Vik6hxYVLIANZ7oBYE9wRJPGKnQBV` |
| **PLT Minter** | `kQCTx3uopuVKTfSOqbtgQpJk18whlfPUyTVYYmwsIFASl0vj`（admin = Core） |
| **PlanetBasket** | `kQAfGKn_UrUW8LQd92ZWy0h0BrCA_QTBhMqDA1M-PZtyv-r_` |
| 部署钱包 | `0QBW4GNM-XpAIuIzwrupQKqVOLILHfP6lnD_Xk04L9Yx6Qol`（v4r2；私钥 `ton/.secrets/`，已 gitignore） |

- **链上状态**：`assetCount=3`、`signerKey=0x9471…0f8f`（relayer 公钥）、`ppi=1.0`（基准=建仓价）。
- **部署**：`.github/workflows/ton-deploy.yml`（`gh workflow run ton-deploy.yml`）。
- **数据源**：`.github/workflows/relayer-push.yml`（`gh workflow run relayer-push.yml`）→ `relayer/` 取 **Yahoo Finance** 行情（`CL=F`/`GC=F`/`HG=F`）→ 签 `PricePayload` → 发 `SignedPriceUpdate`（Core 链上 `isSignatureValid` 验签）→ 重算 PPI。
- **重要经验**：本机/公共 IP 对 toncenter 的 `sendBoc` 会被 **429 限流**；**部署与 relayer 都放在 CI 跑**（runner IP 不限），relayer 内置 429 重试即可。
- **前端对接**：把 `app-tg` 的 `VITE_PLANET_ADDRESS` / `VITE_PLT_MINTER_ADDRESS` 设为上表地址即可读真实状态。
- **前端已验证**：`app-tg` 浏览器实测读到真实篮子（WTI/Gold/Copper）与 PPI（修了 `Buffer` polyfill + RPC 429 重试）。
- **自动刷新**：`relayer-push.yml` 带**每日 cron**；`configure`/`register` 已**幂等**（已配置则跳过），只刷新价格。
- **gas 预算**：relayer 钱包 ~2 TON；每次 push ≈0.15 TON，用尽需重新注资。
