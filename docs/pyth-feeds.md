# Pyth 喂价盘点与集成方案（阶段一 T1 任务）

> 状态：待执行。本文档是阶段一第 1 步的交付物模板，含正确 API、覆盖盘点方法与集成代码。

## 1. 关键事实

1. **白皮书 API 已过时**：白皮书附录用的 `load_price_feed_from_account` 是旧名。当前正确 API 为 `pyth_sdk_solana::load_price_feed_from_account_info`。
2. **喂价覆盖不足**：白皮书称「Pyth 支持 100+ 大宗商品」，实际 Pyth 主要覆盖加密 / 美股 / 外汇 / 贵金属（XAU/XAG）与少数能源。组合中以下品种大概率无 Pyth feed：
   - 水权 NQH2O（Nasdaq Veles 加州水指数）
   - 咖啡 KC、木材 LBS、橡胶 TSR20、锂 LITH
   - 部分农产品（小麦 ZW / 玉米 ZC / 大豆 ZS）

## 2. 盘点方法

用 Pyth Hermes API 查询商品 feed（无需链上交互）：

```bash
# 查询黄金 XAU/USD
curl "https://hermes.pyth.network/v2/price_feeds?query=XAU&asset_type=crypto"
# 查询原油
curl "https://hermes.pyth.network/v2/price_feeds?query=oil&asset_type=crypto"
```

或在 https://pyth.network/developers/price-feed-ids 检索「XAU / XAG / CL / NG」等。

**产出**：`docs/pyth-feeds.md` 附一张表，列出「可用 feed 的 feed_id + 商品名 + 实际可用性」。

| 商品 | Pyth feed_id | 可用性 |
|------|-------------|--------|
| 黄金 XAU/USD | `0x...` | ✅ |
| 白银 XAG/USD | `0x...` | ✅ |
| WTI 原油 | `0x...` | ⚠️ 待确认 |
| 天然气 | `0x...` | ⚠️ 待确认 |
| 咖啡 KC | — | ❌ 无，用替代品/剔除 |

> 策略：阶段一把 PPI 组合**降级到 Pyth 真实覆盖的 N 种**，其余标「目标覆盖」，绝不伪造价格。

## 3. 集成方案

阶段一当前 `update_price` 指令是管理员手动喂价（Static 源）。接入 Pyth 后，新增一个指令 `update_price_from_pyth`，由 keeper 或用户传入 Pyth 价格账户，合约读价并写回 `current_price`。

### 3.1 正确读价代码（参考）

```rust
use pyth_sdk_solana::load_price_feed_from_account_info;

pub fn update_price_from_pyth(
    ctx: Context<UpdatePriceFromPyth>,
    asset_index: u8,
) -> Result<()> {
    let state = &mut ctx.accounts.reserve;
    let feed = load_price_feed_from_account_info(&ctx.accounts.price_feed)?;

    let clock = Clock::get()?;
    let staleness: u64 = 60; // 秒
    let price = feed
        .get_price_no_older_than(clock.unix_timestamp, staleness)
        .ok_or(PlanetError::OracleStale)?;

    // 置信区间校验：偏离 > 5% 视为异常价格，拒绝
    let conf = price.conf as u64;
    let px = price.price as u64;
    require!(
        conf <= (px * 5 / 100),
        PlanetError::OracleHighVariance
    );

    // Pyth 价格是 a × 10^expo 定点，需归一到 PRICE_SCALE(1e6)
    let normalized = normalize_pyth_price(px, price.expo)?;

    let asset = &mut state.assets[asset_index as usize];
    asset.current_price = normalized;
    Ok(())
}

fn normalize_pyth_price(price: u64, expo: i32) -> Result<u64> {
    let target_expo = 6; // PRICE_SCALE = 10^6
    if expo < 0 {
        // price × 10^(-expo) → 缩小
        let factor = 10u64.pow((-expo) as u32);
        let scaled = price as u128 * 10u128.pow(target_expo as u32) / factor as u128;
        Ok(scaled as u64)
    } else {
        let factor = 10u64.pow(expo as u32);
        let scaled = price as u128 * 10u128.pow(target_expo as u32) / factor as u128;
        Ok(scaled as u64)
    }
}
```

### 3.2 依赖

```toml
pyth-sdk-solana = "0.10"   # 以 cargo 实际可解析的最新版为准
```

> 阶段一初始构建**不引入** Pyth 依赖（避免版本解析阻塞「跑通算法」），待 T1 盘点确认 feed 后，再以「可选 feature」或直接依赖方式引入。

## 4. 兜底

- **无 Pyth feed 的品种**：从组合剔除，或等 Chainlink（Solana 上部分 feed）补充。
- **价格异常 / 过期**：`OracleHighVariance` / `OracleStale` 拒绝更新，保留上一次有效价格。
