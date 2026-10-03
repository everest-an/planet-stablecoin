//! 储备证明模块（预言机映射审计）——资产可信任的核心。
//!
//! 信任机制（Proof of Reserves）：
//! 1. 托管方（券商）在链下持有真实 ETF 篮子；
//! 2. 托管方定期发布「储备证明」：把 `Σ(每只 ETF 份额 × 预言机价格)` 映射到链上
//!    `total_value`，并对明细 holdings 做哈希存链（明细本身存 Arweave）；
//! 3. 任何人可调用 `verify_reserve` 校验：`PLT 总供应 ≤ 已验证 ETF 市值`。
//!
//! 这样用户无需信任协议口头承诺，而是信任链上可验证的储备证明。

use crate::errors::PlanetError;
use anchor_lang::prelude::*;

/// 储备证明（单一全局账户，seed = "attestation"）。
#[account]
pub struct ReserveAttestation {
    /// 托管方（券商）公钥，唯一可提交储备证明
    pub custodian: Pubkey,
    /// 已验证的 ETF 篮子总市值（USD，USD_SCALE 定点）
    pub total_value: u64,
    /// 持仓明细哈希（链下明细存 Arweave，链上存哈希供交叉核验）
    pub holdings_hash: [u8; 32],
    /// 最近一次证明时间戳（unix 秒）
    pub attested_at: i64,
    /// PDA bump
    pub bump: u8,
}

impl ReserveAttestation {
    pub const LEN: usize = 8 + 32 + 8 + 32 + 8 + 1;
}

/// 校验储备抵押充足：PLT 总供应 ≤ 已验证 ETF 总市值。
///
/// 若供应 > 市值，说明存在「无抵押增发」，立即拒绝并标记欠抵押。
pub fn verify_reserve(total_supply: u64, total_value: u64) -> Result<()> {
    require!(
        total_supply <= total_value,
        PlanetError::ReserveUndercollateralized
    );
    Ok(())
}

/// 储备抵押率（ppm，1.0 = 1_000_000 = 100% 抵押）。
/// 返回 `total_value / total_supply`（供应为 0 时返回 0）。
pub fn collateral_ratio(total_supply: u64, total_value: u64) -> u64 {
    if total_supply == 0 {
        return 0;
    }
    (total_value as u128 * 1_000_000 / total_supply as u128) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    const USD: u64 = crate::constants::USD_SCALE;

    #[test]
    fn verify_pass_when_fully_collateralized() {
        assert!(verify_reserve(1_000_000 * USD, 1_000_000 * USD).is_ok());
        assert!(verify_reserve(900_000 * USD, 1_000_000 * USD).is_ok());
    }

    #[test]
    fn verify_fail_when_undercollateralized() {
        assert!(verify_reserve(1_100_000 * USD, 1_000_000 * USD).is_err());
    }

    #[test]
    fn ratio_computation() {
        assert_eq!(collateral_ratio(1_000_000 * USD, 1_050_000 * USD), 1_050_000);
        assert_eq!(collateral_ratio(1_000_000 * USD, 1_000_000 * USD), 1_000_000);
        assert_eq!(collateral_ratio(0, 1_000_000 * USD), 0);
    }
}
