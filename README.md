# Planet — 全球大宗商品购买力指数协议

> ⚠️ **版本声明（必读）**：当前仓库是**阶段一概念验证（PoC）**，实现的是「跟踪 PPI 购买力指数的**合成指数代币**」的**算法原型**，**不含真实链下大宗商品储备，不是足额抵押稳定币**。白皮书完整版「1:1 大宗商品储备算法稳定币」需对接 RWA 托管方 + 合规背书后方可实现。详见 [`docs/PRD.md`](docs/PRD.md) 与 [`docs/PLAN.md`](docs/PLAN.md)。

Planet（PLT）将一篮子全球大宗商品（能源/金属/农产品/工业原料）的真实价格聚合为链上**购买力指数 PPI**，用 Solana 链上程序实现。

## 架构

```
前端(React) ──► Planet Core Program (Anchor/Rust)
                   ├─ PPI 计算模块（定点整数，禁止 f64）
                   ├─ 储备状态 ReserveState
                   ├─ 再平衡模拟（仅日志，不执行 DEX 交易）
                   └─ mock 铸造/赎回（0.5% 手续费）
```

- **公链**：Solana（devnet 起步）
- **框架**：Anchor（Rust）
- **预言机**：Pyth Network（阶段一先用手动喂价 Static，Pyth 集成见 `docs/pyth-feeds.md`）
- **代币标准**：Token-2022（`TransferFee` 扩展，0.5% 转账费，阶段二启用）
- **定时任务**：off-chain keeper（Clockwork 已停运，不再使用）

## 关键设计

链上程序（BPF）**不支持浮点数**，白皮书里的 `f64` 公式全部改为**定点整数**（1e6 缩放）：

- `PPI_t = Σ w_i · (P_i,t / P_i,base)` → `ppi::calculate_ppi`
- `ΔA_i = (w_i − V_i/ΣV) × T` → `ppi::compute_rebalance_deltas`
- `Minted = Deposited × (1−f) / PPI` → `mint_burn::mint_amount`

## 指令一览

| 指令 | 说明 | 权限 |
|------|------|------|
| `initialize` | 创建储备状态 PDA | 授权方（payer） |
| `set_assets` | 设置商品篮子（权重/基准价/初始持仓） | authority |
| `update_price` | 更新单商品价格（Static 喂价） | authority |
| `compute_ppi` | 重算并存储 PPI | 无权限 |
| `simulate_rebalance` | 计算调仓量 ΔA_i + 触发判定，仅日志 | 无权限 |
| `mock_mint` | 存入 USDC → 铸造 PLT（计算 + 记账） | 无权限 |
| `mock_burn` | 销毁 PLT → 赎回 USDC（计算 + 记账） | 无权限 |
| `lock_base_prices` | 锁定基准价 | authority |

## 环境搭建（WSL2 推荐）

Solana/Anchor 在 Windows 原生环境脆弱，推荐 WSL2（Ubuntu）：

```bash
# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Solana CLI
sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"

# Anchor (AVM)
cargo install --git https://github.com/coral-xyz/anchor avm --locked --force
avm install latest && avm use latest

# Node 依赖
npm install   # 或 yarn install

# 验证
solana --version && anchor --version
```

## 构建与测试

```bash
# 首次：生成 program keypair 并同步 program id
anchor build
anchor keys sync

# 运行测试（本地 localnet）
anchor test
```

> 注：`declare_id!` 与 `Anchor.toml [programs.localnet]` 当前为占位 program id，首次 `anchor build` 后需 `anchor keys sync` 同步。

### 关于 IDL 生成（已跑通）

`anchor build` 现在能完整产出 `target/deploy/planet.so` + `target/idl/planet.json`。但需如下非默认环境（详见本仓库钉住的历史原因）：

1. **用 platform-tools 的 nightly Rust 1.75 跑构建**（本机 Rust 1.98 移除了 `proc_macro::SourceFile` std API，anchor-syn 0.30.1 依赖它）：
   ```bash
   rustup toolchain link pt ~/.cache/solana/v1.41/platform-tools/rust
   export RUSTUP_TOOLCHAIN=pt
   ```
2. **Cargo.toml 已钉**：`proc-macro2 = "=1.0.79"`（anchor-syn 需要旧 `source_file()` API）、`borsh = "=1.3.1"` + `borsh-derive = "=1.3.1"`（避免 borsh-derive 1.5.x 依赖新版 syn 的 PreciseCapture）。
3. **本地 registry 里 patch wasm-bindgen 家族的 rust-version**（1.77 → 1.75，它们是 wasm32 专属依赖，host 端 proc-macro 支持库实际不用 1.77 特性）：
   ```bash
   sed -i 's/^rust-version = "1.77"$/rust-version = "1.75"/' \
     ~/.cargo/registry/src/index.crates.io-*/wasm-bindgen*-0.2.127/Cargo.toml \
     ~/.cargo/registry/src/index.crates.io-*/js-sys-0.3.104/Cargo.toml \
     ~/.cargo/registry/src/index.crates.io-*/web-sys-0.3.104/Cargo.toml
   ```
4. `Cargo.lock` 已把 `rayon`/`rayon-core` 钉到 1.10.0/1.12.1（rust 1.75 兼容）。

> 长期正解仍是升级 `anchor-lang` 到 0.31+（其 anchor-syn 已适配新版 proc-macro2），可去掉上面 1–3 的 workaround。

## 目录结构

```
programs/planet/src/    # Anchor 合约
  lib.rs                # 指令入口
  constants.rs          # 定点缩放/手续费参数
  errors.rs             # 错误码
  state.rs              # ReserveState + Asset + 事件
  ppi.rs                # PPI 计算 + 再平衡算法
  mint_burn.rs          # 铸造/赎回算法
tests/planet.ts         # TS 集成测试
scripts/keeper.ts       # off-chain keeper（定时触发再平衡）
docs/                   # PRD / PLAN / Pyth 盘点
```

## 免责声明

本协议为技术提案，不构成投资建议。大宗商品价格波动可能导致 PLT 短期偏离锚定。早期 PLT-index 无底层实物兜底，市场价可能大幅偏离理论 PPI。
