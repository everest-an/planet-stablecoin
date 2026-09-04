//! Planet 协议 —— 全球大宗商品购买力指数协议（成品合约）。
//!
//! 模块职责：
//! - `constants`：定点数缩放与手续费参数
//! - `errors`：错误码
//! - `state`：储备状态、商品资产、迁移状态机
//! - `ppi`：PPI 计算与再平衡算法（纯函数）
//! - `mint_burn`：铸造/赎回算法（纯函数）
//! - `risk`：风控（限额/暂停）
//! - `attestation`：储备证明（预言机映射审计）
//!
//! 对标 XStablePUSD 的成品能力：
//! - 真实 SPL（Token-2022）铸造/赎回，替代 PoC 的 mock 记账
//! - RiskManager 通道限额 + 全局暂停
//! - 储备证明（托管方签名 + 预言机映射校验）
//! - 迁移状态机（Normal → NativeOnly，仅向前）

use anchor_lang::prelude::*;
use anchor_lang::solana_program::instruction::{AccountMeta, Instruction};
use anchor_lang::solana_program::program::{invoke, invoke_signed};

pub mod attestation;
pub mod constants;
pub mod errors;
pub mod mint_burn;
pub mod ppi;
pub mod risk;
pub mod state;

use attestation::*;
use constants::*;
use errors::PlanetError;
use risk::*;
use state::*;

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

#[program]
pub mod planet {
    use super::*;

    // ============ 初始化 ============

    pub fn initialize(ctx: Context<Initialize>, authority: Pubkey) -> Result<()> {
        let state = &mut ctx.accounts.reserve;
        state.authority = authority;
        state.total_reserve = 0;
        state.total_supply = 0;
        state.current_ppi = PPI_SCALE;
        state.base_price_locked = false;
        state.migration_state = MigrationState::Normal;
        state.asset_count = 0;
        state.assets = Vec::new();
        state.bump = ctx.bumps.reserve;
        msg!("Planet reserve initialized, authority: {}", authority);
        Ok(())
    }

    pub fn set_assets(ctx: Context<Admin>, assets: Vec<AssetInit>) -> Result<()> {
        let state = &mut ctx.accounts.reserve;
        require!(!state.base_price_locked, PlanetError::BasePriceLocked);
        require!(!assets.is_empty(), PlanetError::NoAssets);
        require!(assets.len() <= MAX_ASSETS, PlanetError::TooManyAssets);

        let weight_sum: u64 = assets.iter().map(|a| a.weight).sum();
        require!(weight_sum == WEIGHT_SCALE, PlanetError::InvalidWeights);

        for a in &assets {
            require!(a.base_price > 0, PlanetError::BasePriceNotSet);
        }

        state.assets = assets
            .iter()
            .map(|a| Asset {
                name: name_to_bytes(&a.name),
                weight: a.weight,
                base_price: a.base_price,
                current_price: a.base_price,
                position_value: a.position_value,
            })
            .collect();

        state.asset_count = state.assets.len() as u8;
        state.total_reserve = state.assets.iter().map(|a| a.position_value).sum();
        state.total_supply = state.total_reserve;

        msg!(
            "Assets set: count={}, total_reserve={}",
            state.asset_count,
            state.total_reserve
        );
        Ok(())
    }

    pub fn update_price(ctx: Context<Admin>, asset_index: u8, new_price: u64) -> Result<()> {
        let state = &mut ctx.accounts.reserve;
        require!(
            (asset_index as usize) < state.assets.len(),
            PlanetError::AssetIndexOutOfBounds
        );
        require!(new_price > 0, PlanetError::ZeroAmount);

        let asset = &mut state.assets[asset_index as usize];
        let old_price = asset.current_price;
        asset.current_price = new_price;

        emit!(PriceUpdatedEvent {
            asset_index,
            old_price,
            new_price,
        });
        Ok(())
    }

    pub fn compute_ppi(ctx: Context<ComputePpi>) -> Result<()> {
        let state = &mut ctx.accounts.reserve;
        require!(!state.assets.is_empty(), PlanetError::NoAssets);

        let weights: Vec<u64> = state.assets.iter().map(|a| a.weight).collect();
        let current_prices: Vec<u64> = state.assets.iter().map(|a| a.current_price).collect();
        let base_prices: Vec<u64> = state.assets.iter().map(|a| a.base_price).collect();

        let ppi = ppi::calculate_ppi(&weights, &current_prices, &base_prices)?;
        state.current_ppi = ppi;

        let clock = Clock::get()?;
        emit!(PpiComputedEvent {
            ppi,
            timestamp: clock.unix_timestamp,
        });
        msg!("PPI computed: {}", ppi);
        Ok(())
    }

    pub fn simulate_rebalance(ctx: Context<ComputePpi>) -> Result<()> {
        let state = &ctx.accounts.reserve;
        require!(!state.assets.is_empty(), PlanetError::NoAssets);
        require!(state.total_reserve > 0, PlanetError::ZeroAmount);

        let weights: Vec<u64> = state.assets.iter().map(|a| a.weight).collect();
        let values: Vec<u64> = state.assets.iter().map(|a| a.position_value).collect();

        let deltas = ppi::compute_rebalance_deltas(&weights, &values, state.total_reserve)?;

        let mut triggered: usize = 0;
        for (i, asset) in state.assets.iter().enumerate() {
            let delta = deltas[i];
            let should =
                ppi::should_rebalance(asset.weight, asset.position_value, state.total_reserve)?;
            if should {
                triggered += 1;
            }
            let action = if delta > 0 { "BUY" } else { "SELL" };
            msg!(
                "asset[{}] {}: delta={} USD ({}), trigger={}",
                i,
                bytes_to_name(&asset.name),
                delta,
                action,
                should
            );
        }
        msg!(
            "Rebalance simulation complete: {} / {} assets trigger rebalance",
            triggered,
            state.assets.len()
        );
        Ok(())
    }

    // ============ 风控 ============

    pub fn init_risk(
        ctx: Context<InitRisk>,
        authority: Pubkey,
        max_per_tx: u64,
        max_per_window: u64,
        window_size: u64,
    ) -> Result<()> {
        let risk = &mut ctx.accounts.risk;
        risk.authority = authority;
        risk.max_per_tx = max_per_tx;
        risk.max_per_window = max_per_window;
        risk.window_size = window_size;
        risk.window_start = 0;
        risk.amount_in_window = 0;
        risk.globally_paused = false;
        risk.bump = ctx.bumps.risk;
        msg!("Risk initialized: tx={} window={} size={}", max_per_tx, max_per_window, window_size);
        Ok(())
    }

    pub fn configure_risk(
        ctx: Context<RiskAdmin>,
        max_per_tx: u64,
        max_per_window: u64,
        window_size: u64,
    ) -> Result<()> {
        let risk = &mut ctx.accounts.risk;
        require!(window_size > 0, PlanetError::RiskNotConfigured);
        require!(max_per_tx > 0, PlanetError::ZeroAmount);
        require!(max_per_window >= max_per_tx, PlanetError::WindowLimitExceeded);
        risk.max_per_tx = max_per_tx;
        risk.max_per_window = max_per_window;
        risk.window_size = window_size;
        msg!("Risk configured: tx={} window={} size={}", max_per_tx, max_per_window, window_size);
        Ok(())
    }

    pub fn set_global_pause(ctx: Context<RiskAdmin>, paused: bool) -> Result<()> {
        let risk = &mut ctx.accounts.risk;
        risk.globally_paused = paused;
        msg!("Global pause: {}", paused);
        Ok(())
    }

    // ============ 储备证明（预言机映射审计）============

    pub fn init_attestation(ctx: Context<InitAttestation>, custodian: Pubkey) -> Result<()> {
        let att = &mut ctx.accounts.attestation;
        att.custodian = custodian;
        att.total_value = 0;
        att.holdings_hash = [0u8; 32];
        att.attested_at = 0;
        att.bump = ctx.bumps.attestation;
        msg!("Attestation initialized, custodian: {}", custodian);
        Ok(())
    }

    pub fn submit_attestation(
        ctx: Context<SubmitAttestation>,
        total_value: u64,
        holdings_hash: [u8; 32],
    ) -> Result<()> {
        let att = &mut ctx.accounts.attestation;
        require!(total_value > 0, PlanetError::ZeroAmount);

        att.total_value = total_value;
        att.holdings_hash = holdings_hash;

        let clock = Clock::get()?;
        att.attested_at = clock.unix_timestamp;

        emit!(AttestationSubmittedEvent {
            total_value,
            attested_at: att.attested_at,
        });
        msg!("Attestation submitted: total_value={}", total_value);
        Ok(())
    }

    pub fn verify_reserve(ctx: Context<VerifyReserve>) -> Result<()> {
        let reserve = &ctx.accounts.reserve;
        let att = &ctx.accounts.attestation;

        let ratio = attestation::collateral_ratio(reserve.total_supply, att.total_value);
        emit!(ReserveVerifiedEvent {
            total_supply: reserve.total_supply,
            total_value: att.total_value,
            ratio,
        });

        attestation::verify_reserve(reserve.total_supply, att.total_value)?;
        msg!(
            "Reserve verified: supply={} value={} ratio={}",
            reserve.total_supply,
            att.total_value,
            ratio
        );
        Ok(())
    }

    // ============ 迁移状态机 ============

    pub fn set_migration_state(ctx: Context<Admin>, new_state: MigrationState) -> Result<()> {
        let state = &mut ctx.accounts.reserve;
        require!(
            state.migration_state.can_transition_to(new_state),
            PlanetError::MigrationStateInvalid
        );
        state.migration_state = new_state;
        msg!("Migration state -> {:?}", new_state);
        Ok(())
    }

    pub fn lock_base_prices(ctx: Context<Admin>) -> Result<()> {
        let state = &mut ctx.accounts.reserve;
        require!(!state.assets.is_empty(), PlanetError::NoAssets);
        state.base_price_locked = true;
        msg!("Base prices locked");
        Ok(())
    }

    // ============ 真实铸造 / 赎回（Token-2022）============

    pub fn mint(ctx: Context<MintAccounts>, usdc_amount: u64) -> Result<()> {
        require!(
            ctx.accounts.reserve.migration_state == MigrationState::Normal,
            PlanetError::MigrationFrozen
        );

        let clock = Clock::get()?;
        risk::consume_risk(&mut ctx.accounts.risk, usdc_amount, clock.unix_timestamp)?;

        let ppi = ctx.accounts.reserve.current_ppi;
        let reserve_bump = ctx.accounts.reserve.bump;
        let minted = mint_burn::mint_amount(usdc_amount, ppi)?;
        let fee = mint_burn::fee_amount(usdc_amount)?;
        let (burn_amt, reserve_amt, staking_amt) = mint_burn::fee_split(fee);

        invoke(
            &spl_transfer_ix(
                &ctx.accounts.usdc_token_program.key(),
                &ctx.accounts.usdc_from.key(),
                &ctx.accounts.usdc_vault.key(),
                &ctx.accounts.user.key(),
                true,
                usdc_amount,
            ),
            &[
                ctx.accounts.usdc_from.to_account_info(),
                ctx.accounts.usdc_vault.to_account_info(),
                ctx.accounts.user.to_account_info(),
            ],
        )?;

        let seeds: &[&[u8]] = &[b"reserve", &[reserve_bump]];
        invoke_signed(
            &spl_mint_to_ix(
                &ctx.accounts.plt_token_program.key(),
                &ctx.accounts.plt_mint.key(),
                &ctx.accounts.plt_to.key(),
                &ctx.accounts.reserve.key(),
                true,
                minted,
            ),
            &[
                ctx.accounts.plt_mint.to_account_info(),
                ctx.accounts.plt_to.to_account_info(),
                ctx.accounts.reserve.to_account_info(),
            ],
            &[seeds],
        )?;

        let reserve = &mut ctx.accounts.reserve;
        reserve.total_reserve = reserve
            .total_reserve
            .checked_add(usdc_amount)
            .ok_or(PlanetError::MathOverflow)?;
        reserve.total_supply = reserve
            .total_supply
            .checked_add(minted)
            .ok_or(PlanetError::MathOverflow)?;

        msg!(
            "Mint: deposit={} PLT={} fee={} (burn={} reserve={} staking={})",
            usdc_amount, minted, fee, burn_amt, reserve_amt, staking_amt
        );
        emit!(MintEvent {
            deposited_usd: usdc_amount,
            minted_plt: minted,
            fee_usd: fee,
            ppi,
        });
        Ok(())
    }

    pub fn burn(ctx: Context<BurnAccounts>, plt_amount: u64) -> Result<()> {
        require!(
            ctx.accounts.reserve.total_supply >= plt_amount,
            PlanetError::MathOverflow
        );

        let ppi = ctx.accounts.reserve.current_ppi;
        let reserve_bump = ctx.accounts.reserve.bump;
        let received = mint_burn::burn_amount(plt_amount, ppi)?;
        let gross = (plt_amount as u128)
            .checked_mul(ppi as u128)
            .ok_or(PlanetError::MathOverflow)?
            .checked_div(PPI_SCALE as u128)
            .ok_or(PlanetError::DivisionByZero)? as u64;
        let fee = mint_burn::fee_amount(gross)?;
        let (burn_amt, reserve_amt, staking_amt) = mint_burn::fee_split(fee);

        let clock = Clock::get()?;
        risk::consume_risk(&mut ctx.accounts.risk, gross, clock.unix_timestamp)?;

        invoke(
            &spl_burn_ix(
                &ctx.accounts.plt_token_program.key(),
                &ctx.accounts.plt_from.key(),
                &ctx.accounts.plt_mint.key(),
                &ctx.accounts.user.key(),
                true,
                plt_amount,
            ),
            &[
                ctx.accounts.plt_from.to_account_info(),
                ctx.accounts.plt_mint.to_account_info(),
                ctx.accounts.user.to_account_info(),
            ],
        )?;

        let seeds: &[&[u8]] = &[b"reserve", &[reserve_bump]];
        invoke_signed(
            &spl_transfer_ix(
                &ctx.accounts.usdc_token_program.key(),
                &ctx.accounts.usdc_vault.key(),
                &ctx.accounts.usdc_to.key(),
                &ctx.accounts.reserve.key(),
                true,
                received,
            ),
            &[
                ctx.accounts.usdc_vault.to_account_info(),
                ctx.accounts.usdc_to.to_account_info(),
                ctx.accounts.reserve.to_account_info(),
            ],
            &[seeds],
        )?;

        let reserve = &mut ctx.accounts.reserve;
        reserve.total_reserve = reserve
            .total_reserve
            .checked_sub(received)
            .ok_or(PlanetError::InsufficientReserve)?;
        reserve.total_supply = reserve
            .total_supply
            .checked_sub(plt_amount)
            .ok_or(PlanetError::MathOverflow)?;

        msg!(
            "Burn: PLT={} received={} fee={} (burn={} reserve={} staking={})",
            plt_amount, received, fee, burn_amt, reserve_amt, staking_amt
        );
        emit!(BurnEvent {
            burned_plt: plt_amount,
            received_usd: received,
            fee_usd: fee,
            ppi,
        });
        Ok(())
    }

    // ============ mock（算法模拟，保留用于无 SPL 环境的算法测试）============

    pub fn mock_mint(ctx: Context<ComputePpi>, usdc_amount: u64) -> Result<()> {
        let state = &mut ctx.accounts.reserve;
        let ppi = state.current_ppi;

        let minted = mint_burn::mint_amount(usdc_amount, ppi)?;
        let fee = mint_burn::fee_amount(usdc_amount)?;
        let (burn, reserve, staking) = mint_burn::fee_split(fee);

        state.total_reserve = state
            .total_reserve
            .checked_add(usdc_amount)
            .ok_or(PlanetError::MathOverflow)?;
        state.total_supply = state
            .total_supply
            .checked_add(minted)
            .ok_or(PlanetError::MathOverflow)?;

        msg!(
            "Mock mint: deposit={} PLT={} fee={} (burn={} reserve={} staking={})",
            usdc_amount, minted, fee, burn, reserve, staking
        );
        emit!(MintEvent {
            deposited_usd: usdc_amount,
            minted_plt: minted,
            fee_usd: fee,
            ppi,
        });
        Ok(())
    }

    pub fn mock_burn(ctx: Context<ComputePpi>, plt_amount: u64) -> Result<()> {
        let state = &mut ctx.accounts.reserve;
        require!(state.total_supply >= plt_amount, PlanetError::MathOverflow);

        let ppi = state.current_ppi;
        let received = mint_burn::burn_amount(plt_amount, ppi)?;
        let gross = (plt_amount as u128)
            .checked_mul(ppi as u128)
            .ok_or(PlanetError::MathOverflow)?
            .checked_div(PPI_SCALE as u128)
            .ok_or(PlanetError::DivisionByZero)? as u64;
        let fee = mint_burn::fee_amount(gross)?;
        let (burn, reserve, staking) = mint_burn::fee_split(fee);

        state.total_reserve = state
            .total_reserve
            .checked_sub(received)
            .ok_or(PlanetError::MathOverflow)?;
        state.total_supply = state
            .total_supply
            .checked_sub(plt_amount)
            .ok_or(PlanetError::MathOverflow)?;

        msg!(
            "Mock burn: PLT={} received={} fee={} (burn={} reserve={} staking={})",
            plt_amount, received, fee, burn, reserve, staking
        );
        emit!(BurnEvent {
            burned_plt: plt_amount,
            received_usd: received,
            fee_usd: fee,
            ppi,
        });
        Ok(())
    }
}

// ============ 账户结构 ============

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = authority,
        space = ReserveState::LEN,
        seeds = [b"reserve"],
        bump
    )]
    pub reserve: Account<'info, ReserveState>,
    #[account(mut)]
    pub authority: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Admin<'info> {
    #[account(mut, has_one = authority, seeds = [b"reserve"], bump = reserve.bump)]
    pub reserve: Account<'info, ReserveState>,
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct ComputePpi<'info> {
    #[account(mut, seeds = [b"reserve"], bump = reserve.bump)]
    pub reserve: Account<'info, ReserveState>,
}

#[derive(Accounts)]
pub struct InitRisk<'info> {
    #[account(init, payer = authority, space = RiskState::LEN, seeds = [b"risk"], bump)]
    pub risk: Account<'info, RiskState>,
    #[account(mut)]
    pub authority: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct RiskAdmin<'info> {
    #[account(mut, has_one = authority, seeds = [b"risk"], bump = risk.bump)]
    pub risk: Account<'info, RiskState>,
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct InitAttestation<'info> {
    #[account(
        init,
        payer = authority,
        space = ReserveAttestation::LEN,
        seeds = [b"attestation"],
        bump
    )]
    pub attestation: Account<'info, ReserveAttestation>,
    #[account(mut)]
    pub authority: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SubmitAttestation<'info> {
    #[account(mut, has_one = custodian, seeds = [b"attestation"], bump = attestation.bump)]
    pub attestation: Account<'info, ReserveAttestation>,
    pub custodian: Signer<'info>,
}

#[derive(Accounts)]
pub struct VerifyReserve<'info> {
    #[account(seeds = [b"reserve"], bump = reserve.bump)]
    pub reserve: Account<'info, ReserveState>,
    #[account(seeds = [b"attestation"], bump = attestation.bump)]
    pub attestation: Account<'info, ReserveAttestation>,
}

#[derive(Accounts)]
pub struct MintAccounts<'info> {
    #[account(mut, seeds = [b"reserve"], bump = reserve.bump)]
    pub reserve: Account<'info, ReserveState>,
    #[account(mut, seeds = [b"risk"], bump = risk.bump)]
    pub risk: Account<'info, RiskState>,
    /// CHECK: 用户 USDC 账户
    #[account(mut)]
    pub usdc_from: AccountInfo<'info>,
    /// CHECK: 协议 USDC 金库（owner = reserve PDA）
    #[account(mut)]
    pub usdc_vault: AccountInfo<'info>,
    /// CHECK: PLT mint（authority = reserve PDA，铸/烧需可写）
    #[account(mut)]
    pub plt_mint: AccountInfo<'info>,
    /// CHECK: 用户 PLT 账户
    #[account(mut)]
    pub plt_to: AccountInfo<'info>,
    pub user: Signer<'info>,
    /// CHECK: USDC 的 token 程序（Token 或 Token-2022）
    pub usdc_token_program: AccountInfo<'info>,
    /// CHECK: PLT 的 token 程序（Token-2022）
    pub plt_token_program: AccountInfo<'info>,
}

#[derive(Accounts)]
pub struct BurnAccounts<'info> {
    #[account(mut, seeds = [b"reserve"], bump = reserve.bump)]
    pub reserve: Account<'info, ReserveState>,
    #[account(mut, seeds = [b"risk"], bump = risk.bump)]
    pub risk: Account<'info, RiskState>,
    /// CHECK: 协议 USDC 金库（owner = reserve PDA）
    #[account(mut)]
    pub usdc_vault: AccountInfo<'info>,
    /// CHECK: 用户 USDC 收款账户
    #[account(mut)]
    pub usdc_to: AccountInfo<'info>,
    /// CHECK: PLT mint（铸/烧需可写）
    #[account(mut)]
    pub plt_mint: AccountInfo<'info>,
    /// CHECK: 用户 PLT 账户
    #[account(mut)]
    pub plt_from: AccountInfo<'info>,
    pub user: Signer<'info>,
    /// CHECK: USDC 的 token 程序（Token 或 Token-2022）
    pub usdc_token_program: AccountInfo<'info>,
    /// CHECK: PLT 的 token 程序（Token-2022）
    pub plt_token_program: AccountInfo<'info>,
}

/// 指令入参：单商品初始化配置（`set_assets` 使用）。
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct AssetInit {
    pub name: String,
    pub weight: u64,
    pub base_price: u64,
    pub position_value: u64,
}

fn name_to_bytes(name: &str) -> [u8; MAX_NAME_LEN] {
    let mut buf = [0u8; MAX_NAME_LEN];
    let bytes = name.as_bytes();
    let len = bytes.len().min(MAX_NAME_LEN);
    buf[..len].copy_from_slice(&bytes[..len]);
    buf
}

fn bytes_to_name(name: &[u8; MAX_NAME_LEN]) -> String {
    let end = name.iter().position(|&b| b == 0).unwrap_or(MAX_NAME_LEN);
    String::from_utf8_lossy(&name[..end]).into_owned()
}

// ============ SPL Token 指令手工编码 ============
//
// 不引入 spl-token-2022 依赖（其自带 #[global_allocator] 与 borsh 版本会与程序冲突），
// 改为手工构造 SPL Token 核心指令。指令数据格式：1 字节判别码 + 8 字节 little-endian amount。
// 判别码与账户顺序是 SPL Token 协议的硬约定，必须逐字节精确：
//   Transfer = 3, 账户 [source, destination, authority]
//   MintTo   = 7, 账户 [mint, to, authority]
//   Burn     = 8, 账户 [account, mint, authority]

fn spl_transfer_ix(
    program: &Pubkey,
    source: &Pubkey,
    dest: &Pubkey,
    authority: &Pubkey,
    authority_is_signer: bool,
    amount: u64,
) -> Instruction {
    let mut data = vec![3u8];
    data.extend_from_slice(&amount.to_le_bytes());
    Instruction {
        program_id: *program,
        accounts: vec![
            AccountMeta::new(*source, false),
            AccountMeta::new(*dest, false),
            AccountMeta::new_readonly(*authority, authority_is_signer),
        ],
        data,
    }
}

fn spl_mint_to_ix(
    program: &Pubkey,
    mint: &Pubkey,
    to: &Pubkey,
    authority: &Pubkey,
    authority_is_signer: bool,
    amount: u64,
) -> Instruction {
    let mut data = vec![7u8];
    data.extend_from_slice(&amount.to_le_bytes());
    Instruction {
        program_id: *program,
        accounts: vec![
            AccountMeta::new(*mint, false),
            AccountMeta::new(*to, false),
            AccountMeta::new_readonly(*authority, authority_is_signer),
        ],
        data,
    }
}

fn spl_burn_ix(
    program: &Pubkey,
    account: &Pubkey,
    mint: &Pubkey,
    authority: &Pubkey,
    authority_is_signer: bool,
    amount: u64,
) -> Instruction {
    let mut data = vec![8u8];
    data.extend_from_slice(&amount.to_le_bytes());
    Instruction {
        program_id: *program,
        accounts: vec![
            AccountMeta::new(*account, false),
            AccountMeta::new(*mint, false),
            AccountMeta::new_readonly(*authority, authority_is_signer),
        ],
        data,
    }
}
