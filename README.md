# Planet — 全球大宗商品购买力指数协议

> **当前部署：Arbitrum Sepolia（chainId 421614）** — Solidity + ERC-20 + Timelock + SignedPriceOracle。
> 唯一可信状态见 [`docs/HANDOFF.md`](docs/HANDOFF.md) §0；更早的实现已归档，不参与当前部署。

Planet（PLT）把一篮子全球大宗商品（能源/金属/农产品/工业原料）的真实价格聚合为链上**购买力指数 PPI**，
以 ERC-20 代币 PLT 表达。`mint()` 拉取测试 USDC 作为抵押，`redeem()` 销毁 PLT 并从储备付回测试 USDC。

> ⚠️ **版本声明**：这是**阶段一概念验证（PoC）**。抵押物是 **Circle Arbitrum Sepolia 测试 USDC**
> （无价值），**没有真实大宗商品储备，不是足额抵押稳定币**。主网/1:1 RWA 版本需托管方 + 合规 + 审计。

## 线上地址（Arbitrum Sepolia）

| 合约 | 地址 |
|---|---|
| PlanetCore | `0xE0b72e108DB58BCbc20da0b1Cd9BEB4824674E30` |
| PLT token（ERC-20） | `0x1064953820505275166E8432B12B3aF785FA1a3B` |
| PlanetTimelock | `0x2617Df906B6C42aF912dd4d4485Fcd74903a5feB` |
| SignedPriceOracle | `0xD625bE7317DE6Dbc8F630e1e11900b91c3eB00cB` |
| 抵押物（test USDC） | `0x75faf114…AA4d`（Circle，6 位小数） |

- 篮子：14 资产，`weightSum = 1,000,000`，`baseLocked = true`，单资产 ≤15%。
- PPI：约 `1.00383`（随每小时推价变化）。
- 预言机：每小时 GitHub Actions → `updatePrice`（授权 relayer）；4 个独立渠道
  （Yahoo 主源 + Sina/腾讯/东财确认，0.5% 容差，不取中位数）。`SignedPriceOracle` 已部署，
  但签名集目前为 **1-of-1**；升到 2-of-3 只需 `setSigners([a,b,c],2)`，无需重新部署。

## 产品架构（当前部署）

```
L3 稳定/风控   分档费 · 弹性曲线 · 套利返还 · 风险基金 · 暂停/偏离熔断      [已实现]
L2 适配层      CAM（设计；核心已有 volatility/liquidity/riskState 字段）    [设计]
L1 核心        PlanetCore：篮子 / 链上 PPI / 抵押铸赎 / 费率 / 预言机状态    [已实现]
L4 基金        PlanetFund（设计，未部署）                                    [设计]
L0 储备/RWA    实物/ETF 储备 + 托管 + 储备证明                               [未来]
（不自建 DEX/AMM；交易走外部场所）
```

## 仓库结构

```
monad/          Solidity 合约 + Foundry 测试（当前部署）
  src/          PlanetCore · PlanetToken · PlanetTimelock · SignedPriceOracle · PlanetBond
  script/       Deploy.s.sol · ConfigureBasket.s.sol
  test/         70 个 Foundry 测试
relayer/        EVM 推价（push-evm.mjs + sources.mjs）
web/            官网 + /dashboard + /docs + /faq + /app + /api/v1/*
docs/           HANDOFF（唯一可信状态）· 机制设计 · 审计准备 · 资助材料
ton/            早期非 EVM 实现（归档，仅作参考，不参与当前部署）
legacy-solana/  更早的 Solana/Anchor 实现（归档）
```

## 构建与测试

```bash
# 合约（需要 Foundry）
cd monad && forge test -vv          # 70 tests

# 推价（dry-run 不需要私钥）
cd relayer && npm install && node push-evm.mjs --dry-run

# 官网 / app（静态 + serverless；本地可用任意静态服务器）
cd web && python -m http.server 4174
```

CI：`.github/workflows/monad-build.yml`（build + 70 tests）、`evm-push.yml`（每小时推价）、
`oracle-monitor.yml`、`cache-warmer.yml`。

## 文档

- **状态/交接**：`docs/HANDOFF.md` §0（唯一可信状态）
- **白皮书**：`web/whitepaper.html`（v2.0，EVM 参考实现）· `docs/WHITEPAPER.md`
- **机制设计**：`docs/ppi-multiasset.md` · `commodity-cam.md` · `peg-stability.md` · `burn-linkage.md`
- **审计/安全**：`docs/audit-prep.md` · `docs/security.md` · `docs/contract-review.md`
- **资助**：`docs/grants/arbitrum-grant-application.md`

## 免责声明

本协议为技术提案与概念验证，不构成投资建议，且**未经第三方审计**。PLT 是合成指数代币；
抵押物为无价值的测试 USDC，没有实物商品兜底，市场价格可能大幅偏离理论 PPI。
不要在无法承受损失的金额上使用。
