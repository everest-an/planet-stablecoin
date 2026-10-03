# Planet — 会话交接（HANDOFF）

> 目的：让下一个会话（或另一位协作者）能在**不重读历史**的情况下继续。
> 仓库即持久记忆；本文档 + `docs/*` 是唯一可信来源。

---

## 0. 一句话 + 链接

Planet（PLT）= 全球大宗商品购买力指数协议；当前实现为 **TON 上的合成指数代币 + TEP-74 代币 + 铸赎骨架**。
仓库：`github.com/everest-an/planet-stablecoin`（**private**），分支 `main`。
最后验证：分支 `feat/ton-coverage-gate-and-jetton-mint`，CI 全绿（45 测试，覆盖率 89.6%）。合并进 `main` 后此处改为 `main` HEAD。

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
  whitepaper-extracted.md   白皮书全文（18页，Node pdf-parse 抽取）
  GTM.md                    定位/获客/Telegram 链限制/多链
  PLAN-TON.md               TON 迁移计划（Tolk/Acton/预言机/组件）
  TON-MAPPING.md            Solana→TON 映射 + 设计决策
  AUDIT.md                  可信任/审计清单（无主体信任模型）
  oracle-ton.md             RedStone/DIA TON 接入调研 + oracle seam 设计
  HANDOFF.md                本文档
ton/
  Acton.toml                项目清单（[package]/[toolchain]/[contracts]/[import-mappings]/[wrappers.tolk]）
  contracts/planet_core.tolk    核心：PPI/铸赎/风控/费率45-30-25/RTRA/Jetton 接线
  contracts/planet_basket.tolk  组合注册表：assetCount()/assetAt(i)
  contracts/oracle_state.tolk   预言机状态（ref cell，避开 1023-bit 限制）
  contracts/jetton/*.tolk       PLT TEP-74（vendored 自 ton-blockchain/tolk-bench 01_jetton）
  contracts/tests/planet_core.test.tolk      纯数学 / 不变量
  contracts/tests/planet_core_flow.test.tolk PlanetCore 管理/暂停/费率/赎回
  contracts/tests/integration.test.tolk     部署 PlanetCore 集成
  contracts/tests/jetton_mint.test.tolk     全链路 mint / burn / transfer
  contracts/tests/jetton_minter_admin.test.tolk minter 管理路径 + TEP-89
  contracts/tests/oracle.test.tolk           预言机接缝（set / push / 重放）
  contracts/tests/planet_basket.test.tolk     组合注册表（assetCount/assetAt/SetAsset）
  README.md                 构建说明（WSL/Acton + Tact PoC）
app-tg/                     Telegram Mini App（Vite+React+TON Connect）
  src/App.tsx               读 PlanetCore + 篮子表 + mint UI + burn UI
.github/workflows/ton-build.yml   3 job：Tolk(Acton) / TG Mini App / Tact PoC
legacy-solana/              Solana/Anchor 遗留实现 + 原 README（算法参考，非主线）
```

---

## 3. 当前验证状态（可核对）

- **CI 3 job 全绿**：`Tolk (Acton)`（build + wrapper + test --coverage）、`TG Mini App`（vite build）、`Tact PoC`。
- **45 个测试（7 文件）**：纯数学/不变量 + **大额溢出回归** + 集成 + 全链路（mint/burn/transfer）+ PlanetCore 管理/暂停/费率/赎回 + minter 管理/TEP-89 + **预言机接缝** + **PlanetBasket 组合注册表**。
- **触发路径**：`.github/workflows/ton-build.yml` 监听 `ton/**` 与 `app-tg/**`。
- **覆盖率（基线棘轮）**：All files **89.6% score**（行 94.4% / 分支 78.0%）；`planet_core.tolk` 96.0%、`planet_basket.tolk` 90.9%、JettonWallet 85.5%、JettonMinter 83.0%。门禁 `ton/Acton.toml [test.coverage] minimum-percent = 89`，**只升不降**（门禁已实证生效：测试编译失败时曾以 70.4% 拦下 CI）。
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
- `PlanetBasket`：链上组合注册表 + getter。
- **PLT TEP-74 Jetton**（minter + wallet，vendored）。
- TG 小程序：读 PPI/储备/供应 + **链上篮子表** + **mint UI** + **burn UI**（TEP-74 AskToBurn）。
- 45 测试 + 覆盖率（89.6% score，门禁 89）+ CI 门禁（棘轮，只升不降）。
- 文档：GTM / PLAN-TON / TON-MAPPING / AUDIT。

---

## 6. 待办 + 精确下一步 + 阻塞

| 优先级 | 任务 | 状态 / 阻塞 |
|---|---|---|
| ✅ | **Mint→Jetton 全链路集成测试**（emulator 部署 Minter+Wallet，发 Mint，断言 PLT 余额） | ✅ 完成（`contracts/tests/jetton_mint.test.tolk`，CI 绿） |
| ✅ | **覆盖率门禁（目标 80%）** | ✅ 超额达成：All files **89.6%**，门禁 `minimum-percent = 89`（起点 29.8% → 89.6%） |
| P2 | **RedStone 预言机接入** | 🟡 接缝已就绪并测试（`planet_core.tolk` + `oracle.test.tolk`，见 `docs/oracle-ton.md`）；仅剩外部：**已部署 adapter 地址 + feed_id 清单**。注：RedStone TON connector 为 legacy/unmaintained（FunC），需评估 DIA 备选 |
| P2 | **测试网部署 + `acton verify`** | ❌ 阻塞：需 **有资金的 TON 钱包**（外部） |
| P3 | 多签 + 时间锁迁移（owner 权限点：SetPaused/SetJettonMinter/SetAsset/UpdatePrice） | 部署后配置 |
| P3 | 第三方审计（Halborn/Certora）、漏洞赏金、形式化验证 | 外部机构 |

**下一步最顺（纯代码）**：覆盖率已 89.6%；可选补 JettonWallet 反弹/零值边界；再接 RedStone/DIA（需外部 adapter 地址+feed_id）或测试网部署（需有资金钱包）。

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

> "读 `docs/HANDOFF.md`。仓库已整理（主线 `ton/`+`app-tg/`，Solana 归档 `legacy-solana/`）。45 测试全绿，覆盖率 89.6%（门禁 89，只升不降）；预言机接缝已就绪（见 `docs/oracle-ton.md`）。下一步：接入 RedStone/DIA（需 adapter 地址 + feed_id）或测试网部署（需有资金钱包）。改动保持 CI 绿。"

---

## 10. 上下文管理教训（给 Agent）

- **别把大文档整页抓进主上下文**：用 `task` 派子智能体读 TON docs/大文件，只回收结论。
- **CI 日志用 grep 抓关键行**，别整段 dump。
- **中间结果写进仓库文件**（`docs/*`），让持久状态在磁盘而非上下文。
- 一次 2 万 token 的抓取 ≈ 几十轮对话；节流就是续命。
