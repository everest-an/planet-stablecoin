# Planet — 会话交接（HANDOFF）

> 当前版本：2026-11。本文只描述 **EVM / Arbitrum** 这一条主线；`legacy-solana/` 是归档原型，不参与当前部署。
> 仓库即持久记忆；`README.md` + 本文 + `docs/` 是当前状态的来源。

## 0. 当前状态（以此为准）

| 项 | 值 |
|---|---|
| 网络 | Arbitrum One（chainId 42161） |
| PlanetCore（PPI） | `0x61de052af7cb7dc957a07b1e6298152bb851cbbb` |
| PlanetToken（PLT） | `0xee270802969f0689e3085331d47679bdc5bf4512` |
| PPIPerp v2 | `0x99e6ba49d2dff95e69b671d6f0945daee544ac8c` |
| PPIPriceSource v2（TWAP） | `0xbf8651b58afd832e1b72edbf9df368c0516dea9e` |
| SignedPriceOracle（2-of-3） | `0x0daf541ef7e41402070bc549f91475ab368d1824` |
| PlanetTimelock（6h） | `0xa1fdb9f95210af1d968872f6fc86f623a3e3017c` |
| 抵押品 | 原生 USDC `0xaf88d065e77c8cc2239327c5edb3a432268e5831` |
| PPI | `0.999013`（2026-11-01 15:17 UTC 快照；14 资产，权重和 1,000,000） |
| 预言机 | 2-of-3 · pull · 单钥路径已禁用 |
| 永续 | beta；poolAssets = 0；riskLevel = 1（caution）；3x / 10% |
| 金属路由 | PAXG / XAUT / KAG / VNXAU / KAU；4 个可买；5 条支付链 |
| 审计 | 无第三方审计；自审 + 70 Foundry 测试 + 900 步不变量 |

**主网是 index-only**：没有设置 deposit token，`mint/redeem` 是禁用的；不要向任何人声称 PLT
有商品储备或可按 1:1 赎回。永续持有真实 USDC，但在首笔 LP 之前池子为空，属于 beta。

## 1. 现在能做什么

- **PPI 指数**：14 个商品（能源 / 贵金属 / 工业金属 / 农产品），链上计算；每个资产有独立
  `lastUpdate` 和 `riskState`（0 normal / 1 caution / 2 frozen）。
- **拉取式预言机**：`/api/v1/price-signed` 签发 14 条 payload；消费者在自己的交易里调用
  `updatePriceSigned` 并支付 gas。签名集是 2-of-3，domain-separated，不能跨 core/chain 重放。
- **永续 v2**：LP 池做对手盘；10 bps 开平仓费；OI ≤ 2× 池；3x 杠杆 / 10% 维持保证金；
  TWAP 清算门（现价与时间加权价同时击穿才可强平）；guardian 只能暂停、不能解禁。
- **金属前端**：`/metals` 读取五个代币的跨钱包余额（只读、不签名），现货 vs 链上市场价，
  五链比价，两步路由断点续传；中文/英文；MiCA 与赎回门槛写在页面上。
- **公开 API**：`/api/v1/ppi`、`/api/v1/perp`、`/api/v1/price-signed`、`/api/v1/sources`、
  `/api/metals`、`/api/quote`。读 30 次/分；签名喂价 8 次/分。

## 2. 现在不能做什么

- 主网 `mint/redeem`：禁用。
- 永续：池子为空，不能承诺流动性；`riskLevel = 1` 时按 caution 处理。
- 外部审计：没有；只能引用自审和测试证据。
- 1:1 实物/ETF 储备：不存在；这是未来需要托管方、合规和审计的产品。

## 3. 仓库结构

```
monad/          Solidity 0.8.24 + Foundry
  src/          PlanetCore · PlanetToken · PlanetTimelock · SignedPriceOracle · PlanetBond
  test/         70 个 Foundry 测试
relayer/        EVM 推价/签名、perp keeper、timelock 队列、部署与验证脚本
web/            静态站 + dashboard + docs + faq + app + metals + API
docs/           状态、机制、审计、资助材料
scripts/        运维脚本
tools/          报告工具
legacy-solana/  更早的 Solana/Anchor 原型（归档，不参与当前部署）
```

## 4. 构建与测试

```bash
cd monad && forge test -vv          # 70 tests

cd relayer && npm install
node push-evm.mjs --dry-run         # no key needed
node push-evm.mjs                   # submit the signed batch (consumer pays gas)

cd web && python -m http.server 4174
```

CI：`monad-build.yml`（build + 70 tests）、`evm-push.yml`、`oracle-monitor.yml`、
`index-refresh-mainnet.yml`、`perp-keeper-mainnet.yml`、`cache-warmer.yml`。

## 5. 数据与链接

- 实时指数：`https://ppppp.space/api/v1/ppi`
- 永续状态：`https://ppppp.space/api/v1/perp`
- 签名喂价：`https://ppppp.space/api/v1/price-signed`
- 通道审计：`https://ppppp.space/api/v1/sources`
- 金属读数：`https://ppppp.space/api/metals?address=0x…`
- 报价：`https://ppppp.space/api/quote?symbol=PAXG&from=ARBITRUM&amount=100`
- 白皮书：`https://ppppp.space/whitepaper`
- 方法论：`https://ppppp.space/methodology`

## 6. 安全与审计

- 2-of-3 signed pull oracle；单 key 路径已禁用；signer 集可经 timelock 轮换。
- 6 小时 timelock；参数、keeper、treasury、guardian 全部排队执行。
- guardian 单向暂停（只能暂停，不能解禁）。
- 70 个 Foundry 测试；900 步不变量 fuzz；攻击矩阵与网络审计公开在 `docs/`。
- **没有第三方审计**。对外只能说“自审公开”，不能说“已审计”。

## 7. 已知缺口

1. 外部审计未做（预算内）。
2. 永续池子为空；首笔 LP 之前不能把“可对冲”当卖点。
3. 资金费仍是 keeper 参数，不是 mark-index 机制。
4. 金属路由依赖 Rango；两步路线可能桥接，客户需要保持页面打开。
5. PAXG 在欧盟受 MiCA 限制；KAG/VNXAU 链上流动性薄。
6. 指数超过 6 小时无消费者提交会变旧；页面显示 age，永续转 close-only。

## 8. 文档

- 白皮书：`web/whitepaper.html`
- 方法论：`docs/ppi-methodology-v1.md`
- 审计：`docs/audit-scope-2026-10.md` · `docs/self-audit-2026-10.md` · `docs/attack-matrix-2026-10-31.md` · `docs/network-security-audit-2026-10-31.md`
- 部署：`docs/deployments.md` · `docs/launch-runbook-2026-10.md`
- 资助：`docs/grants/arbitrum-grant-application.md`