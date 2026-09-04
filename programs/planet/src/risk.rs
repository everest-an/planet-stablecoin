//! 风控模块（RiskManager）：通道级限额 + 全局暂停。
//!
//! 对标 XStablePUSD 的 RiskManager.sol：
//! - `max_per_tx`：单笔交易上限
//! - `max_per_window`：滚动窗口总上限
//! - `window_size`：窗口长度（秒）
//! - `globally_paused`：紧急全局暂停开关
//!
//! 每一笔铸造/赎回在动账前必须先 `consume_risk` 扣减风控预算，
//! 确保没有任何 mint/release 绕过风控记账。

use crate::errors::PlanetError;
use anchor_lang::prelude::*;

/// 风控状态（单一全局账户，seed = "risk"）。
#[account]
pub struct RiskState {
    /// 风控管理员（可配置限额 / 触发暂停）
    pub authority: Pubkey,
    /// 单笔交易上限（USD，USD_SCALE 定点）
    pub max_per_tx: u64,
    /// 滚动窗口总上限（USD，USD_SCALE 定点）
    pub max_per_window: u64,
    /// 窗口长度（秒）
    pub window_size: u64,
    /// 当前窗口起始时间戳（unix 秒）
    pub window_start: i64,
    /// 当前窗口已扣减金额
    pub amount_in_window: u64,
    /// 全局暂停开关
    pub globally_paused: bool,
    /// PDA bump
    pub bump: u8,
}

impl RiskState {
    pub const LEN: usize = 8 + 32 + 8 + 8 + 8 + 8 + 8 + 1 + 1;
}

/// 扣减风控预算（铸造/赎回前调用）。
///
/// 逻辑（等价 RiskManager.consume）：
/// 1. 未暂停
/// 2. 已配置（window_size > 0）
/// 3. 单笔 ≤ max_per_tx
/// 4. 窗口滚动：超出窗口则重置
/// 5. 窗口累计 ≤ max_per_window
pub fn consume_risk(risk: &mut RiskState, amount: u64, now: i64) -> Result<()> {
    require!(!risk.globally_paused, PlanetError::RiskPaused);
    require!(risk.window_size > 0, PlanetError::RiskNotConfigured);
    require!(amount <= risk.max_per_tx, PlanetError::TxLimitExceeded);

    if risk.window_start == 0 || now >= risk.window_start + risk.window_size as i64 {
        risk.window_start = now;
        risk.amount_in_window = 0;
    }

    let updated = risk
        .amount_in_window
        .checked_add(amount)
        .ok_or(PlanetError::MathOverflow)?;
    require!(updated <= risk.max_per_window, PlanetError::WindowLimitExceeded);
    risk.amount_in_window = updated;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base_state() -> RiskState {
        RiskState {
            authority: Pubkey::default(),
            max_per_tx: 100_000 * crate::constants::USD_SCALE,
            max_per_window: 1_000_000 * crate::constants::USD_SCALE,
            window_size: 3600,
            window_start: 0,
            amount_in_window: 0,
            globally_paused: false,
            bump: 0,
        }
    }

    #[test]
    fn consume_within_limits() {
        let mut s = base_state();
        consume_risk(&mut s, 50_000 * crate::constants::USD_SCALE, 1_000).unwrap();
        assert_eq!(s.amount_in_window, 50_000 * crate::constants::USD_SCALE);
    }

    #[test]
    fn consume_over_tx_limit_rejected() {
        let mut s = base_state();
        assert!(consume_risk(&mut s, 200_000 * crate::constants::USD_SCALE, 1_000).is_err());
    }

    #[test]
    fn consume_over_window_limit_rejected() {
        let mut s = base_state();
        // 分 10 次每次 100_000 达到窗口上限 1_000_000
        for _ in 0..10 {
            consume_risk(&mut s, 100_000 * crate::constants::USD_SCALE, 1_000).unwrap();
        }
        // 第 11 次超窗口上限
        assert!(consume_risk(&mut s, 100_000 * crate::constants::USD_SCALE, 1_000).is_err());
    }

    #[test]
    fn window_rolls_over() {
        let mut s = base_state();
        // 第一窗口消费 1_000_000（达到上限）
        for _ in 0..10 {
            consume_risk(&mut s, 100_000 * crate::constants::USD_SCALE, 1_000).unwrap();
        }
        // 窗口滚动后（+3600 秒）可再次消费
        consume_risk(&mut s, 100_000 * crate::constants::USD_SCALE, 1_000 + 3600).unwrap();
        assert_eq!(s.amount_in_window, 100_000 * crate::constants::USD_SCALE);
    }

    #[test]
    fn paused_rejects_consume() {
        let mut s = base_state();
        s.globally_paused = true;
        assert!(consume_risk(&mut s, 1, 1_000).is_err());
    }
}
