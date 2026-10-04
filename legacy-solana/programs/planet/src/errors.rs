//! 自定义错误码。

use anchor_lang::prelude::*;

#[error_code]
pub enum PlanetError {
    /// 数学运算溢出
    #[msg("Math overflow")]
    MathOverflow,

    /// 除数为零（基准价格为 0 或 PPI 为 0）
    #[msg("Division by zero")]
    DivisionByZero,

    /// 权重之和不为 1.0（≠ 1_000_000 ppm）
    #[msg("Weights do not sum to 1.0")]
    InvalidWeights,

    /// 商品数量超出上限
    #[msg("Too many assets")]
    TooManyAssets,

    /// 商品数量为零
    #[msg("No assets configured")]
    NoAssets,

    /// 基准价格未设置（为 0）
    #[msg("Base price not set")]
    BasePriceNotSet,

    /// 资产索引越界
    #[msg("Asset index out of bounds")]
    AssetIndexOutOfBounds,

    /// 基准价格已锁定，不可修改（发行后）
    #[msg("Base prices are locked after issuance")]
    BasePriceLocked,

    /// 金额为零
    #[msg("Amount must be greater than zero")]
    ZeroAmount,

    /// 预言机价格置信区间过大（异常价格）
    #[msg("Oracle price variance too high")]
    OracleHighVariance,

    /// 预言机价格过期
    #[msg("Oracle price stale")]
    OracleStale,

    /// 未授权操作
    #[msg("Unauthorized")]
    Unauthorized,

    /// 全局风控暂停
    #[msg("Risk globally paused")]
    RiskPaused,

    /// 风控通道未配置
    #[msg("Risk channel not configured")]
    RiskNotConfigured,

    /// 单笔限额超限
    #[msg("Per-tx limit exceeded")]
    TxLimitExceeded,

    /// 窗口限额超限
    #[msg("Per-window limit exceeded")]
    WindowLimitExceeded,

    /// 储备不足（赎回金额超出储备）
    #[msg("Insufficient reserve")]
    InsufficientReserve,

    /// 储备抵押不足（PLT 供应 > 已验证储备价值）
    #[msg("Reserve undercollateralized")]
    ReserveUndercollateralized,

    /// 迁移状态非法（非向前迁移）
    #[msg("Invalid migration state transition")]
    MigrationStateInvalid,

    /// 迁移冻结中（当前状态禁止铸造）
    #[msg("Mint frozen in current migration state")]
    MigrationFrozen,
}
