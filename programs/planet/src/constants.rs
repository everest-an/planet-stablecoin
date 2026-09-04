//! 全局常量：定点数缩放与手续费参数。
//!
//! 关键设计：Solana 链上程序（BPF）不支持 f64 浮点运算，白皮书里的
//! `f64` 公式必须全部转换为定点整数实现。本模块统一所有缩放因子。

/// 权重缩放：权重以百万分之一（ppm）表示，1.0 = 1_000_000，Σweight = 1_000_000。
pub const WEIGHT_SCALE: u64 = 1_000_000;

/// 价格缩放：价格以 6 位小数定点表示，1.0 USD = 1_000_000。
pub const PRICE_SCALE: u64 = 1_000_000;

/// PPI 缩放：购买力指数以 6 位小数定点表示，PPI = 1.0 对应 1_000_000。
pub const PPI_SCALE: u64 = 1_000_000;

/// 美元金额缩放：所有 USD 计价金额以 6 位小数表示。
pub const USD_SCALE: u64 = 1_000_000;

/// 基准点缩放（basis points）。
pub const BPS_SCALE: u64 = 10_000;

/// 全局手续费 0.5% = 50 basis points（应用于铸造/赎回/转账）。
pub const FEE_BPS: u64 = 50;

/// 手续费分配（白皮书 8.4）：
/// - 45% → 回购销毁 PLT（通缩压力）
/// - 30% → 注入储备池（增强抵押率）
/// - 25% → PLTG 质押奖励
pub const BURN_SHARE_BPS: u64 = 4500;
pub const RESERVE_SHARE_BPS: u64 = 3000;
pub const STAKING_SHARE_BPS: u64 = 2500;

/// 再平衡触发阈值：单商品实际权重偏离目标权重 > 0.5%（白皮书 2.3）。
/// 0.5% × WEIGHT_SCALE = 5000（ppm）。
pub const REBALANCE_THRESHOLD: u64 = 5000;

/// 稳定性区间（白皮书 3.3）：PPI ∈ [0.97, 1.03] 维持现状。
pub const PPI_LOWER_BAND: u64 = 970_000; // 0.97
pub const PPI_UPPER_BAND: u64 = 1_030_000; // 1.03

/// 极端波动阈值（白皮书 3.3）：
pub const PPI_OVERHEAT: u64 = 1_050_000; // > 1.05 提高铸造费
pub const PPI_DEFLATE: u64 = 950_000; // < 0.95 开启稳定债券

/// 组合商品数量上限（用于账户空间计算）。
pub const MAX_ASSETS: usize = 32;

/// 商品名称最大长度（字节，固定长度便于账户空间计算）。
pub const MAX_NAME_LEN: usize = 16;
