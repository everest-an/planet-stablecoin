# Planet — 全球大宗商品购买力指数协议

> **当前主线：TON**（Tolk 合约 + TEP-74 PLT 代币 + Telegram Mini App）。
> Solana/Anchor 实现已归档为**算法参考**，见 [`legacy-solana/`](legacy-solana/)。
> 会话交接与「唯一可信状态」见 [`docs/HANDOFF.md`](docs/HANDOFF.md)。

Planet（PLT）把一篮子全球大宗商品（能源/金属/农产品/工业原料）的真实价格聚合为链上**购买力指数 PPI**，
以合成指数代币 PLT 表达。

> ⚠️ **版本声明**：当前为**阶段一概念验证（PoC）** —— 链上**合成指数代币** + TEP-74 代币 + 铸赎骨架；
> **不含真实链下大宗商品储备，不是足额抵押稳定币**。白皮书完整版「1:1 大宗商品储备算法稳定币」
> 需对接 RWA 托管方 + 合规背书后方可实现。

## 产品架构（分层）

> 仅 **L1 核心已实现**；L2/L3/L4 为**设计**（详见 [`docs/PRODUCT-DESIGN.md`](docs/PRODUCT-DESIGN.md)）。

```
L3 稳定/风控   分档费 · 弹性铸赎曲线 · 套利入口 · 稳定债券 · 风险基金 · 熔断   [设计]
L2 适配层      CAM：每商品标准化 价格/波动率/流动性/风险                     [设计]
L1 核心        PlanetCore：篮子 / 链上 PPI / 铸赎 / 费率 / RTRA / 赎回镜像    [已实现]
L0 储备/RWA    实物/ETF 储备 + 托管 + 储备证明                               [未来]
（不自建 DEX/AMM；交易走外部场所）
```

## 主线（TON）

- **合约**：`ton/contracts/`（Tolk，Acton 工具链）
  - `planet_core.tolk` — **链上多资产 PPI**（篮子 + `computePpi`）/ 铸赎 / **赎回镜像** / 风控 / 费率 45-30-25 / RTRA / Jetton 接线
  - `planet_basket.tolk` — 链上组合注册表（`assetCount()` / `assetAt(i)`）
  - `jetton/*.tolk` — PLT TEP-74（minter + wallet，vendored 自 `ton-blockchain/tolk-bench`）
- **前端**：`app-tg/`（Telegram Mini App，Vite + React + TON Connect）
- **测试 / CI**：`ton/contracts/tests/`；`.github/workflows/ton-build.yml`
  （Acton 只能运行在 Linux/WSL/Docker，**CI 即编译环境**）

### 构建与测试

TON（Acton 不支持 Windows 原生，需 WSL/Linux/Docker，或直接走 CI）：
```bash
cd ton && acton build && acton wrapper --all && acton test --coverage
```

TG 小程序（本机 Node 可跑）：
```bash
cd app-tg && npm install && npm run build
```

## 文档（唯一可信来源）

- **状态/交接**：`docs/HANDOFF.md`（唯一可信状态）
- **产品/架构**：`PRODUCT-DESIGN.md`（v2 分层架构 + 稳健性）、`PRD.md`、`GTM.md`、`PLAN-TON.md`、`TON-MAPPING.md`
- **机制设计**：`ppi-multiasset.md`（链上 PPI）、`commodity-cam.md`（CAM）、`peg-stability.md`（稳定机制，借 AMM 设计，不自建 DEX）、`burn-linkage.md`（赎回）
- **调研/审计**：`oracle-ton.md`（RedStone/DIA）、`AUDIT.md`
- **白皮书**：`WHITEPAPER.md`（v1.5 工程增补正文）、`whitepaper-extracted.md`（v1 抽取）

## 仓库结构

```
ton/            TON / Tolk 合约 + 测试（主线）
app-tg/         Telegram Mini App（主线）
docs/           白皮书与设计文档
.github/        CI（TON build）
legacy-solana/  Solana / Anchor 遗留实现（算法参考，非主线）
```

## 遗留：Solana（`legacy-solana/`）

早期 Solana/Anchor 版（`programs/planet`、`scripts/`、`tests/`、`app/`）保留作算法参考，**不再维护**。
原 Solana README 见 [`legacy-solana/README.md`](legacy-solana/README.md)。

## 免责声明

本协议为技术提案，不构成投资建议。大宗商品价格波动可能导致 PLT 短期偏离锚定。
早期 PLT-index 无底层实物兜底，市场价可能大幅偏离理论 PPI。
稳定机制（借鉴 AMM 设计）与 CAM 适配层仅为**设计**，尚未实现；Planet **不自建 DEX**。切勿据此预期已具备稳定机制。
