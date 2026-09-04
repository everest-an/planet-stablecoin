# Planet 协议 — 实施计划（PLAN）

| 字段 | 内容 |
|------|------|
| 文档版本 | v0.1 |
| 状态 | 草稿 · 待评审 |
| 更新日期 | 2026-09-01 |
| 关联 | `PRD.md`、`Planet Stablecoin White Paper.pdf` |

---

## 1. 技术选型（已确认）

| 决策点 | 选择 | 理由 |
|--------|------|------|
| 公链 | **Solana** | Pyth 原生、DEX（Jupiter/Raydium）成熟、手续费极低适合再平衡、RWA 叙事活跃 |
| 合约框架 | **Anchor**（Rust） | Solana 主流框架，开发/测试/部署一体化 |
| 预言机 | **Pyth Network**（`pyth-sdk-solana`） | Solana 原生，实时大宗商品喂价 |
| 代币标准 | **Token-2022**（`TransferFee` 扩展） | 原生 0.5% 转账费，无需自写 fee 逻辑 |
| 定时任务 | **off-chain keeper**（GitHub Actions cron / Cloudflare cron） | Clockwork 已停运（2023-10 下线），不再使用 |
| 前端 | React + `@solana/web3.js` + `@coral-xyz/anchor` | 生态标准 |

### 1.1 关键纠正（相对白皮书）

1. **Clockwork 已死**：白皮书附录写「Clockwork 定时任务」——Clockwork 于 2023-08 宣布停运、2023-10-31 下线。改用 off-chain keeper 调用链上 `rebalance` 指令。
2. **Pyth 喂价覆盖不足**：白皮书称「Pyth 支持 100+ 大宗商品」。实际 Pyth 主要覆盖加密/美股/外汇/贵金属（XAU/XAG）与少数能源。组合中 **水权 NQH2O、咖啡 KC、木材 LBS、橡胶 TSR20、锂 LITH** 等大概率无 Pyth feed。
   → **阶段一第 1 步：盘点 Pyth devnet 实际可用商品 feed，把 PPI 组合降级到「Pyth 真实覆盖的 N 种」，其余品种标「目标覆盖」。**
3. **Pyth SDK API 已更新**：白皮书用的 `load_price_feed_from_account` 是旧名；当前为 `load_price_feed_from_account_info` + `get_price_no_older_than(timestamp, staleness)`。

---

## 2. 系统架构

```
┌──────────────┐   PPI/权重/日志    ┌─────────────────────────────┐
│   前端       │ ◄─────────────────► │  Planet Core Program (Anchor)│
│  (React)     │                    │  ├─ PPI 计算模块             │
└──────┬───────┘                    │  ├─ 储备状态 (ReserveState)  │
       │ RPC                        │  ├─ 再平衡模拟 (rebalance)   │
       ▼                            │  ├─ mock 铸造/赎回           │
┌──────────────┐                    │  └─ 价格源抽象               │
│ Solana devnet│                    │      ├─ PythPriceFeed        │
└──────┬───────┘                    │      └─ StaticPriceFeed(测试)│
       │                            └──────────┬──────────────────┘
       │                                       │
┌──────▼───────┐  价格 VAA       ┌─────────────▼────────────┐
│ Pyth (devnet)│ ───────────────►│ Pythnet 喂价账户           │
└──────────────┘                 └──────────────────────────┘
```

**价格源双轨设计**：程序内抽象 `PriceSource`，支持两种来源——
- `Pyth`：读 Pyth 价格账户（带 staleness + 置信区间校验）。
- `Static`：读本地静态价格账户（单测 / demo 用，不依赖 Pyth）。

---

## 3. 阶段一任务拆解

| 任务 | 内容 | 产出 | 依赖 |
|------|------|------|------|
| T0 | 环境搭建（Rust + Solana CLI + Anchor + AVM） | 可运行 `anchor build` | — |
| T1 | Pyth devnet 商品 feed 盘点 | `docs/pyth-feeds.md`（可用 feed 清单） | T0 |
| T2 | Anchor 项目初始化 | 项目骨架 + 目录结构 | T0 |
| T3 | PPI 计算模块 | `calculate_ppi` 纯函数 + 单测 | T2 |
| T4 | 储备状态 + 初始化指令 | `ReserveState` 账户 + `initialize` | T2 |
| T5 | 再平衡模拟指令 | `simulate_rebalance`（计算 ΔA_i，写日志） | T3,T4 |
| T6 | mock 铸造/赎回指令 | `mock_mint` / `mock_burn`（0.5% 费） | T4 |
| T7 | 价格源抽象 + Pyth 集成 | `PriceSource` + `update_ppi` | T3,T1 |
| T8 | 单元/集成测试 | `anchor test` 全绿 | T3–T7 |
| T9 | 极简前端 | 展示 PPI/权重/日志 | T5–T7 |
| T10 | 开源 + 文档 | GitHub 仓库 + README + 演示视频 | 全部 |

---

## 4. 关键算法与公式

### 4.1 购买力指数 PPI
```
PPI_t = Σ w_i · (P_i,t / P_i,base)
```
- `w_i`：商品 i 权重（按全球贸易量分配，Σw=1）
- `P_i,t`：商品 i 在 t 时刻实时价格
- `P_i,base`：商品 i 基准日（发行日）价格

### 4.2 目标价格
```
Price_PLT = PPI_t × USD_base   （USD_base = 1）
```

### 4.3 再平衡调仓量（RTRA）
```
ΔA_i = ( w_i − V_i / ΣV ) × T
```
- `V_i`：商品 i 当前持仓价值
- `ΣV`：总储备规模
- 触发条件：|ΔA_i / V_i| > 0.5%（阶段一仅计算 + 日志，不执行交易）

### 4.4 铸造 / 赎回（0.5% 手续费）
```
Minted_PLT = Deposited_USDC × (1 − 0.005) / PPI_t
Received_USDC = Burned_PLT × PPI_t × (1 − 0.005)
```

### 4.5 手续费分配
```
45% → 回购销毁 PLT
30% → 协议金库
25% → PLTG 质押分红
```

### 4.6 稳定性区间（白皮书阈值）
- `PPI ∈ [0.97, 1.03]`：维持现状
- `PPI > 1.05`：铸造手续费升至 1%（抑制过热）
- `PPI < 0.95`：开启「稳定债券」折价铸造

---

## 5. 项目目录结构（规划）

```
E:\PLANET\
├── Planet Stablecoin White Paper.pdf
├── docs\
│   ├── PRD.md
│   ├── PLAN.md
│   └── pyth-feeds.md          # Pyth devnet feed 盘点（T1 产出）
├── programs\
│   └── planet\                # Anchor 合约
│       ├── Cargo.toml
│       └── src\
│           ├── lib.rs         # 入口 + 指令
│           ├── state.rs       # ReserveState 等账户
│           ├── ppi.rs         # PPI 计算模块
│           ├── rebalance.rs   # 再平衡模拟
│           ├── mint_burn.rs   # mock 铸造/赎回
│           └── price_source.rs# Pyth/Static 价格源抽象
├── tests\
│   └── planet.ts              # TS 集成测试
├── app\                       # 极简前端（T9）
├── scripts\
│   └── keeper.ts              # off-chain keeper（定时调 rebalance）
├── Anchor.toml
└── README.md
```

---

## 6. 环境搭建（T0）

> 当前本机：Node v24 ✓、git ✓、winget ✓、WSL2(Ubuntu) ✓；**Rust / Solana CLI / Anchor 未装**。

### 6.1 推荐路径：WSL2（Ubuntu）内开发
Solana/Anchor 在 Windows 原生环境脆弱，推荐 WSL2。

```bash
# 1. Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# 2. Solana CLI
sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"

# 3. Anchor (AVM)
cargo install --git https://github.com/coral-xyz/anchor avm --locked --force
avm install latest
avm use latest

# 4. 验证
solana --version && anchor --version
```

### 6.2 替代路径：Windows 原生
```powershell
winget install Rustlang.Rustup          # Rust
# Solana: https://github.com/anza-xyz/agave 下载 Windows 版
# Anchor: cargo install --git https://github.com/coral-xyz/anchor avm --locked --force
```
> Windows 原生 Anchor 已知存在编译问题，优先 WSL2。

---

## 7. 里程碑时间线

| 阶段 | 时间 | 里程碑 |
|------|------|--------|
| 阶段一 | 0–3 月 | 测试网完整 demo、开源、种子社区 |
| 阶段二 | 3–8 月 | 主网 PLT-index、DEX 交易、链上历史数据 |
| 阶段三 | 8 月后 | 对接 RWA 托管方，迭代向完整版 PLT |

---

## 8. 规避清单（红线，踩中直接归零）

1. ❌ 不把 PLT-index 包装成「足额抵押稳定币」——必须公开区分版本。
2. ❌ 不碰期货链下自营（展期/保证金/爆仓风险），优先 ETF。
3. ❌ 不早期冲 CEX——重心全在 Solana DEX。
4. ❌ 不花钱买虚假社群 / 刷虚假交易量——后续对接机构一查就露馅。
5. ❌ 不在没有 Pyth feed 的情况下硬编码伪造价格——宁可缩小商品覆盖范围。

---

## 9. 阶段一验收标准

- [ ] `anchor build` 通过，无编译错误。
- [ ] `anchor test` 全绿（PPI 计算、再平衡模拟、mock 铸造/赎回）。
- [ ] PPI 计算结果可被外部脚本复算验证。
- [ ] 再平衡指令只写日志、不执行交易。
- [ ] 代码开源、注释完整。
- [ ] `docs/pyth-feeds.md` 完成 Pyth devnet 可用商品 feed 盘点。
