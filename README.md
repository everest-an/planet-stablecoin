# Planet — 链上大宗商品指数与代币化金属

> **当前部署：Arbitrum One（chainId 42161）** — 14 商品 PPI 指数、PPI 永续（beta）、金属路由前端。
> 状态文档见 [`docs/HANDOFF.md`](docs/HANDOFF.md)。

Planet 把 14 个全球大宗商品（能源、贵金属、工业金属、农产品）的价格聚合为链上**购买力指数 PPI**，
用 2-of-3 签名拉取式预言机更新；在指数之上运行一个 **LP 池做对手盘的永续市场**（beta），
并提供 `/metals` 读取 PAXG / XAUT / KAG / VNXAU / KAU 的跨钱包余额、比较五条链的报价。

> **边界**：这是**未外部审计**的协议；指数本身不是稳定币、不是足额抵押、没有商品储备。
> 主网 `mint/redeem` 已禁用（index-only）；永续是 beta，池子在首笔 LP 之前为空。
> 不要使用无法承受损失的金额。

## 线上合约（Arbitrum One）

| 合约 | 地址 |
|---|---|
| PlanetCore（PPI 指数） | `0x61de052af7cb7dc957a07b1e6298152bb851cbbb` |
| PlanetToken（PLT） | `0xee270802969f0689e3085331d47679bdc5bf4512` |
| PPIPerp v2（永续） | `0x99e6ba49d2dff95e69b671d6f0945daee544ac8c` |
| PPIPriceSource v2（TWAP） | `0xbf8651b58afd832e1b72edbf9df368c0516dea9e` |
| SignedPriceOracle（2-of-3） | `0x0daf541ef7e41402070bc549f91475ab368d1824` |
| PlanetTimelock（6h） | `0xa1fdb9f95210af1d968872f6fc86f623a3e3017c` |
| 抵押品（原生 USDC） | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` |

- 核心合约源码已在 Arbiscan 验证；owner 是 6 小时 timelock。
- 预言机是 **2-of-3 签名拉取式**：消费者在自己的交易里提交签名喂价并支付 gas；主网单钥路径已禁用。

## 现在能用的

- **14 商品 PPI**：权重和 `1,000,000`，单资产 ≤15%，base 锁定；每个资产带 `riskState`（normal / caution / frozen）和自己的 `lastUpdate`。
- **PPIPerp v2**：LP 池做对手盘，真实 USDC；10 bps 开平仓费；OI ≤ 2× 池；3x 杠杆 / 10% 维持保证金；TWAP 清算门；guardian 单向急停。
- **`/metals`**：五个代币、四个发行方；只读、不托管；现货 vs 链上市场价；五链比价（Arbitrum / Base / Optimism / Polygon / Ethereum）；两步路由可断点续传。
- **公开 API**：`/api/v1/ppi`、`/api/v1/perp`、`/api/v1/price-signed`、`/api/v1/sources`、`/api/metals`、`/api/quote`。
- **安全控制**：2-of-3 oracle、6h timelock、guardian 单向暂停、签名喂价 8 次/分、读接口 30 次/分。

## 仓库结构

```
monad/          Solidity 0.8.24 + Foundry（当前部署）
  src/          PlanetCore · PlanetToken · PlanetTimelock · SignedPriceOracle · PlanetBond
  test/         70 个 Foundry 测试
relayer/        EVM 推价、签名、perp keeper、timelock 队列
web/            官网 + /dashboard + /docs + /faq + /app + /metals + /api/v1/*
docs/           状态/交接、机制、审计、资助材料
scripts/        运维脚本
tools/          报告生成工具
legacy-solana/  更早的 Solana/Anchor 原型（归档，不参与当前部署）
```

## 构建与测试

```bash
# 合约（需要 Foundry）
cd monad && forge test -vv          # 70 tests

# 推价（dry-run 不需要私钥）
cd relayer && npm install && node push-evm.mjs --dry-run

# 官网 / app（静态 + serverless；本地用任意静态服务器）
cd web && python -m http.server 4174
```

CI：`.github/workflows/monad-build.yml`（build + 70 tests）、`evm-push.yml`、`oracle-monitor.yml`、
`index-refresh-mainnet.yml`、`perp-keeper-mainnet.yml`、`cache-warmer.yml`。

## 文档

- **状态/交接**：`docs/HANDOFF.md`
- **白皮书**：`web/whitepaper.html`（v2.0）· `web/methodology.html`
- **方法论**：`docs/ppi-methodology-v1.md`
- **审计/安全**：`docs/audit-scope-2026-10.md` · `docs/self-audit-2026-10.md` · `docs/attack-matrix-2026-10-31.md` · `docs/network-security-audit-2026-10-31.md`
- **资助**：`docs/grants/arbitrum-grant-application.md`

## 免责声明

本协议未经第三方审计。PLT 是合成指数代币；主网没有商品储备，`mint/redeem` 已禁用。
永续市场为 beta，池子可能为空。商品价格可能大幅下跌，任何代币化金属都存在发行方、托管、
司法辖区、流动性与赎回风险。本仓库不构成投资建议、要约或招揽。
## ??(agent / ??)

- npm MCP server: `protocolbank-mcp` � `npx -y protocolbank-mcp`(get_index / get_asset / get_risk_level / get_perp_market)
- ???: Hugging Face `EverestAn/planet-ppi`(? risk_state ?)
- ????: https://ppppp.space/history
- ????: /llms.txt � /openapi.json � /api/v1/ppi
