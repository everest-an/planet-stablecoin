# 上架材料包（DefiLlama / Dune / Arbitrum 生态）

原则：**没有 LP 之前，别提交需要 TVL/成交量的列表**——会被拒或长期挂零。先准备好，LP 到位当天就能提交。

## 一、通用提交信息（复制粘贴用）

```
Name:            Planet
Category:        Indexes / Perpetuals
Chains:          Arbitrum One (42161)
Website:         https://ppppp.space
Index page:      https://ppppp.space/ppi
Docs:            https://ppppp.space/methodology
GitHub:          https://github.com/everest-an/planet-stablecoin
Description:     A 14-asset on-chain commodity purchasing-power index with machine-readable
                 data-quality states, plus a perpetual market on that index. 2-of-3 signed pull
                 oracle; single-relayer path disabled on mainnet.
Contracts:       core 0x61de052af7cb7dc957a07b1e6298152bb851cbbb
                 perp 0x99e6ba49d2dff95e69b671d6f0945daee544ac8c
                 oracle 0x0daf541ef7e41402070bc549f91475ab368d1824
                 timelock 0xa1fdb9f95210af1d968872f6fc86f623a3e3017c
```

## 二、DefiLlama

- 提交方式：在 `DefiLlama/DefiLlama-Adapters` 提 PR，新增 `projects/planet/index.js`，或走他们的 listing 表单（defillama.com 底部 "List your protocol"）。
- 需要提供：TVL 计算方式（我们的 TVL = perp `poolAssets` 链上读取）、链、合约、官网。
- **现实**：当前 poolAssets = 0，提交会挂零且无人看。**等第一笔 LP 入金当天再提。**
- 前置脚本：可在 `relayer/` 下写 `llama-tvl.mjs`，读出 `poolAssets` 并输出 DefiLlama adapter 需要的 JSON 形状（等 LP 到位我再加）。

## 三、Dune

1. 先把合约提交给 Dune 解码（dune.com → Contracts → Submit contract）。需要提交：
   - `PlanetCore` 0x61de…cbbb（事件 `PriceUpdated(uint256,uint64,uint64,uint64)`）
   - `PPIPerp` 0x99e6…ac8c（事件 `PoolDeposit`、`PoolWithdraw`、`Opened`、`Closed`、`Liquidated`）
2. 解码完成后，三张查询（保存到 Planet 仪表盘）：

```sql
-- Q1: PPI 历史（每次推价后的指数值）
SELECT evt_block_time AS t, ppi / 1e6 AS ppi
FROM planet_core_arbitrum.evt_priceupdated
ORDER BY 1;

-- Q2: 池子 TVL（当前）
SELECT (poolAssets) / 1e6 AS tvl_usdc
FROM planet_perp_arbitrum.evt_pooldeposit
ORDER BY evt_block_time DESC LIMIT 1;

-- Q3: 成交量（开仓名义额累计，按日）
SELECT date_trunc('day', evt_block_time) AS d, SUM(ABS(size)) / 1e6 AS notional
FROM planet_perp_arbitrum.evt_opened
GROUP BY 1 ORDER BY 1;
```

3. **发布纪律**：Q3 必须同时展示"独立交易者数"，否则等于替刷量背书：
```sql
SELECT COUNT(DISTINCT who) AS traders FROM planet_perp_arbitrum.evt_opened;
```

## 四、Arbitrum 生态目录

- 提交入口：arbitrum.io 生态页 → "Submit your project"（需填官网、GitHub、类别、描述）。
- 材料直接用上面的通用块；先提交**指数**（已上线、可验证），perp 等 LP 后再补。

## 五、提交顺序（LP 到位后 24 小时内）

1. Arbitrum 生态目录（最快，纯展示）
2. Dune（提交解码 → 1–2 天后仪表盘上线）
3. DefiLlama（TVL > 0 当天提交）
4. 同步发 X：指数 + 仪表盘 + 首个 LP 收据
