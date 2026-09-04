//! PPI（购买力指数）计算模块。
//!
//! 白皮书公式（2.3 / 3.1）：
//!   PPI_t = Σ w_i · (P_i,t / P_i,base)
//!
//! 定点整数实现（禁止 f64）：
//!   ratio_i      = P_i,t × PPI_SCALE / P_i,base   （u128 中间量防溢出）
//!   contrib_i    = w_i × ratio_i / WEIGHT_SCALE
//!   PPI          = Σ contrib_i
//!
//! 校验：若所有 ratio_i = 1（价格未变），且 Σw_i = WEIGHT_SCALE，
//! 则 PPI = WEIGHT_SCALE = 1_000_000 = 1.0。正确。

use crate::constants::*;
use crate::errors::PlanetError;
use anchor_lang::prelude::*;

/// 计算 PPI。
///
/// # 参数
/// - `weights`：各商品权重（ppm，Σ = WEIGHT_SCALE）
/// - `current_prices`：各商品实时价格（PRICE_SCALE 定点）
/// - `base_prices`：各商品基准价（PRICE_SCALE 定点）
///
/// # 返回
/// PPI（PPI_SCALE 定点），1.0 = 1_000_000。
pub fn calculate_ppi(
    weights: &[u64],
    current_prices: &[u64],
    base_prices: &[u64],
) -> Result<u64> {
    require!(
        weights.len() == current_prices.len() && weights.len() == base_prices.len(),
        PlanetError::InvalidWeights
    );
    require!(!weights.is_empty(), PlanetError::NoAssets);

    let mut ppi: u128 = 0;
    for i in 0..weights.len() {
        let w = weights[i] as u128;
        let p = current_prices[i] as u128;
        let base = base_prices[i] as u128;

        require!(base > 0, PlanetError::BasePriceNotSet);

        // ratio_i = P_i,t / P_i,base，缩放至 PPI_SCALE
        let ratio = p
            .checked_mul(PPI_SCALE as u128)
            .ok_or(PlanetError::MathOverflow)?
            .checked_div(base)
            .ok_or(PlanetError::DivisionByZero)?;

        // contrib_i = w_i × ratio_i / WEIGHT_SCALE
        let contrib = w
            .checked_mul(ratio)
            .ok_or(PlanetError::MathOverflow)?
            .checked_div(WEIGHT_SCALE as u128)
            .ok_or(PlanetError::DivisionByZero)?;

        ppi = ppi.checked_add(contrib).ok_or(PlanetError::MathOverflow)?;
    }

    Ok(ppi as u64)
}

/// 计算再平衡调仓量（RTRA，白皮书 2.3）：
///   ΔA_i = (w_i − V_i / ΣV) × T
///        = (w_i × T / WEIGHT_SCALE) − V_i
///
/// # 返回
/// 每个商品的有符号调仓量（USD，USD_SCALE 定点；正数=买入，负数=卖出）。
pub fn compute_rebalance_deltas(
    weights: &[u64],
    position_values: &[u64],
    total_reserve: u64,
) -> Result<Vec<i128>> {
    require!(
        weights.len() == position_values.len(),
        PlanetError::InvalidWeights
    );
    require!(total_reserve > 0, PlanetError::ZeroAmount);

    let mut deltas: Vec<i128> = Vec::with_capacity(weights.len());
    for i in 0..weights.len() {
        let w = weights[i] as u128;
        let v = position_values[i] as i128;

        // 目标持仓价值 = w_i × T / WEIGHT_SCALE
        let target = w
            .checked_mul(total_reserve as u128)
            .ok_or(PlanetError::MathOverflow)?
            .checked_div(WEIGHT_SCALE as u128)
            .ok_or(PlanetError::DivisionByZero)? as i128;

        let delta = target.checked_sub(v).ok_or(PlanetError::MathOverflow)?;
        deltas.push(delta);
    }

    Ok(deltas)
}

/// 判断单个商品是否需要触发再平衡。
/// 偏离度 = |w_i − V_i/ΣV|（ppm），超过 REBALANCE_THRESHOLD（0.5%）则触发。
pub fn should_rebalance(weight: u64, position_value: u64, total_reserve: u64) -> Result<bool> {
    require!(total_reserve > 0, PlanetError::ZeroAmount);

    // 实际权重（ppm）= V_i × WEIGHT_SCALE / ΣV
    let actual_weight = (position_value as u128)
        .checked_mul(WEIGHT_SCALE as u128)
        .ok_or(PlanetError::MathOverflow)?
        .checked_div(total_reserve as u128)
        .ok_or(PlanetError::DivisionByZero)? as u64;

    let deviation = if actual_weight >= weight {
        actual_weight - weight
    } else {
        weight - actual_weight
    };

    Ok(deviation > crate::constants::REBALANCE_THRESHOLD)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ppi_unchanged_prices_equals_one() {
        // 两个商品，权重 50% / 50%，价格未变 → PPI = 1.0
        let weights = vec![500_000, 500_000];
        let current = vec![100 * PRICE_SCALE, 50 * PRICE_SCALE];
        let base = vec![100 * PRICE_SCALE, 50 * PRICE_SCALE];

        let ppi = calculate_ppi(&weights, &current, &base).unwrap();
        assert_eq!(ppi, PPI_SCALE); // 1_000_000
    }

    #[test]
    fn ppi_reflects_price_change() {
        // 商品 A 涨 10%（100→110），权重 60%；商品 B 不变，权重 40%
        let weights = vec![600_000, 400_000];
        let current = vec![110 * PRICE_SCALE, 50 * PRICE_SCALE];
        let base = vec![100 * PRICE_SCALE, 50 * PRICE_SCALE];

        // ratio_A = 1.10, ratio_B = 1.00
        // PPI = 0.6*1.10 + 0.4*1.00 = 0.66 + 0.40 = 1.06
        let ppi = calculate_ppi(&weights, &current, &base).unwrap();
        assert_eq!(ppi, 1_060_000);
    }

    #[test]
    fn rebalance_deltas_correct() {
        // 两个商品各 50% 权重，总储备 $1_000_000 (USD_SCALE)
        // 实际持仓：A = $600k, B = $400k
        // 目标各 $500k → ΔA = -100k, ΔB = +100k
        let weights = vec![500_000, 500_000];
        let values = vec![600_000 * USD_SCALE, 400_000 * USD_SCALE];
        let total = 1_000_000 * USD_SCALE;

        let deltas = compute_rebalance_deltas(&weights, &values, total).unwrap();
        assert_eq!(deltas[0], -(100_000_i128 * USD_SCALE as i128));
        assert_eq!(deltas[1], 100_000_i128 * USD_SCALE as i128);
    }

    #[test]
    fn rebalance_trigger_threshold() {
        // 目标 50%，实际 50.6% → 偏离 0.6% > 0.5%，应触发
        let total = 1_000_000 * USD_SCALE;
        let pos = 506_000 * USD_SCALE; // 50.6%
        assert!(should_rebalance(500_000, pos, total).unwrap());

        // 目标 50%，实际 50.4% → 偏离 0.4% < 0.5%，不触发
        let pos2 = 504_000 * USD_SCALE;
        assert!(!should_rebalance(500_000, pos2, total).unwrap());
    }
}
