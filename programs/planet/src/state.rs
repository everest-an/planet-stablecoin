//! 账户状态定义：储备状态与商品资产配置。

use crate::constants::{MAX_ASSETS, MAX_NAME_LEN};
use anchor_lang::prelude::*;

/// 单个商品资产配置。
///
/// 定点数约定（见 constants.rs）：
/// - `weight`：权重，ppm，Σweight = 1_000_000
/// - `base_price`：基准日价格，PRICE_SCALE 定点
/// - `current_price`：实时价格，PRICE_SCALE 定点
/// - `position_value`：当前持仓价值，USD_SCALE 定点
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy)]
pub struct Asset {
    /// 商品名称（固定 16 字节，如 "WTI" / "XAU"）
    pub name: [u8; MAX_NAME_LEN],
    /// 权重（ppm）
    pub weight: u64,
    /// 基准日价格
    pub base_price: u64,
    /// 实时价格（由预言机更新）
    pub current_price: u64,
    /// 当前持仓价值（USD）
    pub position_value: u64,
}

impl Asset {
    pub const LEN: usize = MAX_NAME_LEN + 4 * 8;
}

/// 协议储备状态（单一全局账户）。
#[account]
pub struct ReserveState {
    /// 授权管理员（可更新价格 / 触发再平衡）
    pub authority: Pubkey,
    /// 总储备规模（USD，USD_SCALE 定点）
    pub total_reserve: u64,
    /// PLT 当前总供应量（USD_SCALE 定点）
    pub total_supply: u64,
    /// 当前 PPI 指数（PPI_SCALE 定点，1.0 = 1_000_000）
    pub current_ppi: u64,
    /// 基准价是否已锁定（发行后锁定，禁止修改 base_price）
    pub base_price_locked: bool,
    /// 迁移状态（合成指数 → 足额 ETF 储备的渐进演进）
    pub migration_state: MigrationState,
    /// 当前商品数量
    pub asset_count: u8,
    /// 商品资产列表
    pub assets: Vec<Asset>,
    /// PDA bump
    pub bump: u8,
}

impl ReserveState {
    /// 计算账户所需空间（8 字节 Anchor discriminator + 字段 + MAX_ASSETS 个资产）。
    pub const LEN: usize =
        8 + 32 + 8 + 8 + 8 + 1 + 1 + 1 + 4 + (MAX_ASSETS * Asset::LEN) + 1;
}

/// 迁移状态机（对标 XStablePUSD 的 Bridged -> Native 演进）：
/// `Normal -> FreezeMint -> Migration -> NativeOnly`，仅允许前进。
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum MigrationState {
    /// 正常：铸造与赎回均开放
    Normal,
    /// 冻结铸造：禁止新铸造，赎回仍开放
    FreezeMint,
    /// 迁移中：对账与托管权交接期
    Migration,
    /// 仅原生：合成铸造路径永久关闭
    NativeOnly,
}

impl MigrationState {
    /// 仅允许向前迁移（next == current + 1）。
    pub fn can_transition_to(self, next: MigrationState) -> bool {
        (next as u8) == (self as u8) + 1
    }
}

/// 铸造 / 赎回事件（模拟，仅记录算法结果）。
#[event]
pub struct MintEvent {
    pub deposited_usd: u64,
    pub minted_plt: u64,
    pub fee_usd: u64,
    pub ppi: u64,
}

#[event]
pub struct BurnEvent {
    pub burned_plt: u64,
    pub received_usd: u64,
    pub fee_usd: u64,
    pub ppi: u64,
}

#[event]
pub struct PpiComputedEvent {
    pub ppi: u64,
    pub timestamp: i64,
}

#[event]
pub struct PriceUpdatedEvent {
    pub asset_index: u8,
    pub old_price: u64,
    pub new_price: u64,
}

#[event]
pub struct ReserveVerifiedEvent {
    pub total_supply: u64,
    pub total_value: u64,
    pub ratio: u64,
}

#[event]
pub struct AttestationSubmittedEvent {
    pub total_value: u64,
    pub attested_at: i64,
}
