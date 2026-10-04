//! 铸造 / 赎回算法（mock，Phase 1 仅计算，不执行 SPL 转账）。
//!
//! 白皮书公式（3.1 / 3.2 / 8.2）：
//!   铸造：Minted = Deposited × (1 − f) / PPI
//!   赎回：Received = Burned × PPI × (1 − f)
//!   f = 0.5% 全局手续费

use crate::constants::*;
use crate::errors::PlanetError;
use anchor_lang::prelude::*;

/// 计算 0.5% 手续费金额（USD）。
pub fn fee_amount(usd_value: u64) -> Result<u64> {
    let fee = (usd_value as u128)
        .checked_mul(FEE_BPS as u128)
        .ok_or(PlanetError::MathOverflow)?
        .checked_div(BPS_SCALE as u128)
        .ok_or(PlanetError::DivisionByZero)?;
    Ok(fee as u64)
}

/// 计算铸造数量。
/// `deposited_usd`：存入 USDC（USD_SCALE 定点）；`ppi`：当前 PPI（PPI_SCALE 定点）。
pub fn mint_amount(deposited_usd: u64, ppi: u64) -> Result<u64> {
    require!(deposited_usd > 0, PlanetError::ZeroAmount);
    require!(ppi > 0, PlanetError::DivisionByZero);

    // net = deposited × (1 − f)
    let net = (deposited_usd as u128)
        .checked_mul((BPS_SCALE - FEE_BPS) as u128)
        .ok_or(PlanetError::MathOverflow)?
        .checked_div(BPS_SCALE as u128)
        .ok_or(PlanetError::DivisionByZero)?;

    // minted = net / ppi = net × PPI_SCALE / ppi
    let minted = net
        .checked_mul(PPI_SCALE as u128)
        .ok_or(PlanetError::MathOverflow)?
        .checked_div(ppi as u128)
        .ok_or(PlanetError::DivisionByZero)?;

    Ok(minted as u64)
}

/// 计算赎回金额。
/// `burned_plt`：销毁 PLT（USD_SCALE 定点）；`ppi`：当前 PPI（PPI_SCALE 定点）。
pub fn burn_amount(burned_plt: u64, ppi: u64) -> Result<u64> {
    require!(burned_plt > 0, PlanetError::ZeroAmount);
    require!(ppi > 0, PlanetError::DivisionByZero);

    // gross = burned × ppi（换算回 USD）
    let gross = (burned_plt as u128)
        .checked_mul(ppi as u128)
        .ok_or(PlanetError::MathOverflow)?
        .checked_div(PPI_SCALE as u128)
        .ok_or(PlanetError::DivisionByZero)?;

    // net = gross × (1 − f)
    let net = gross
        .checked_mul((BPS_SCALE - FEE_BPS) as u128)
        .ok_or(PlanetError::MathOverflow)?
        .checked_div(BPS_SCALE as u128)
        .ok_or(PlanetError::DivisionByZero)?;

    Ok(net as u64)
}

/// 手续费拆分（白皮书 8.4）：45% 回购销毁 / 30% 储备增强 / 25% 质押奖励。
/// 返回 `(burn, reserve, staking)`，三者之和恒等于 `fee`。
pub fn fee_split(fee_usd: u64) -> (u64, u64, u64) {
    let burn = (fee_usd as u128 * BURN_SHARE_BPS as u128 / BPS_SCALE as u128) as u64;
    let reserve = (fee_usd as u128 * RESERVE_SHARE_BPS as u128 / BPS_SCALE as u128) as u64;
    let staking = fee_usd - burn - reserve; // 余数归质押，保证恒等
    (burn, reserve, staking)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mint_at_parity() {
        // PPI = 1.0，存入 $1000 → 扣除 0.5% 费后得到 995 PLT
        let deposited = 1000 * USD_SCALE;
        let ppi = PPI_SCALE;
        let minted = mint_amount(deposited, ppi).unwrap();
        assert_eq!(minted, 995 * USD_SCALE);
    }

    #[test]
    fn mint_when_ppi_above_one() {
        // PPI = 1.06，存入 $1_000_000 → net = 995_000 → minted = 995_000 / 1.06
        let deposited = 1_000_000u64 * USD_SCALE;
        let ppi = 1_060_000u64;
        let minted = mint_amount(deposited, ppi).unwrap();
        let expected = 995_000u128 * USD_SCALE as u128 * PPI_SCALE as u128 / 1_060_000;
        assert_eq!(minted as u128, expected);
    }

    #[test]
    fn burn_at_parity() {
        // PPI = 1.0，销毁 1000 PLT → 赎回 995 USDC
        let burned = 1000 * USD_SCALE;
        let ppi = PPI_SCALE;
        let received = burn_amount(burned, ppi).unwrap();
        assert_eq!(received, 995 * USD_SCALE);
    }

    #[test]
    fn fee_split_sums_to_fee() {
        let fee = 5000 * USD_SCALE; // $5000 手续费
        let (burn, reserve, staking) = fee_split(fee);
        assert_eq!(burn + reserve + staking, fee);
        assert_eq!(burn, 2250 * USD_SCALE); // 45%
        assert_eq!(reserve, 1500 * USD_SCALE); // 30%
        assert_eq!(staking, 1250 * USD_SCALE); // 25%
    }
}
