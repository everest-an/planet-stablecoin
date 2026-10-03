# Planet — TON 迁移实施计划（PLAN-TON v0.1）

> **决策**：TG 做第一入口 → 协议架到 TON（见 `GTM.md` §2 方案 A）
> **依据**：`whitepaper-extracted.md`（白皮书 v1.0）+ `PRD.md` + `PLAN.md` + `GTM.md`
> **更新**：2026-10-04

---

## 0. 变更摘要

| 项 | 白皮书 v1.0 | 现在 |
|---|---|---|
| 部署网络 | **Solana** | **TON**（原因：Telegram Mini App 合规硬约束，见 `GTM.md` §2） |
| 合约语言 | Rust / Anchor | **Tolk**（TON 官方推荐；Tact 已弃用） |
| 预言机 | Pyth（Solana 原生） | TON 上待定（见 §3） |
| DEX | Raydium / Jupiter | TON DEX（STON.fi / DeDust） |
| 定时任务 | Clockwork | 链下 keeper（Clockwork 已停运） |

**保留**：机制设计（商品篮子、PPI、RTRA、铸造/赎回、费率、稳定区间、PLTG 分配）。
**作废**：白皮书的 Solana 技术实现方案（Rust/Anchor/Pyth SDK/Raydium/Clockwork）——按 TON 重写。

---

## 1. 关键设计（沿用白皮书 + 修正）

### 1.1 初始商品篮子（权重合计 100%，每季度 DAO 投票调整）

| 类别 | 商品 | 期货 | ETF | 权重 | 价格源 |
|---|---|---|---|---|---|
| 能源 | WTI 原油 | CL (NYMEX) | USO | 12% | CME Group |
| 能源 | 布伦特原油 | BZ (ICE) | BNO | 10% | ICE |
| 能源 | 天然气 | NG (NYMEX) | UNG | 8% | CME Group |
| 金属 | 黄金 | GC (COMEX) | GLD | 10% | LBMA |
| 金属 | 白银 | SI (COMEX) | SLV | 7% | LBMA |
| 金属 | 铜 | HG (COMEX) | CPER | 6% | LME |
| 农产品 | 小麦 | ZW (CBOT) | WEAT | 9% | CBOT |
| 农产品 | 玉米 | ZC (CBOT) | CORN | 7% | CBOT |
| 农产品 | 大豆 | ZS (CBOT) | SOYB | 6% | CBOT |
| 农产品 | 咖啡 | KC (ICE) | JO | 4% | ICE |
| 工业原料 | 橡胶 TSR20 | — (SGX) | — | 5% | SGX |
| 工业原料 | 木材 | LBS (CME) | WOOD | 4% | CME Group |
| 工业原料 | 锂 | LITH (LME) | LIT | 3% | LME |
| 其他 | 水权 | NQH2O (CME) | PHO | 5% | Nasdaq |
| 其他 | 碳信用 | GEO (CME) | KRBN | 4% | CME Group |

> **修正**：绝大多数品种**无可行链上喂价**（水权/咖啡/木材/橡胶/锂）。阶段一把篮子降级到**预言机真实可覆盖的 N 种**（黄金/白银/部分能源/农产品），其余标「目标覆盖」，绝不伪造价格。

### 1.2 核心公式（链上定点整数，1e6 缩放，**禁止 f64**）

```
PPI_t        = Σ w_i · (P_i,t / P_i,base)        // 购买力指数
Price_PLT    = PPI_t × USD_base  (=1)
Minted       = D × (1 − f) / PPI_t                // f = 0.5%
Received     = B × PPI_t × (1 − f)
ΔA_i         = (w_i − V_i / ΣV) × T               // RTRA 调仓量
触发条件      : |ΔA_i / V_i| > 0.5%  → 再平衡
```

### 1.3 稳定区间 & 双轨锚定

- PPI ∈ [0.97, 1.03]：维持现状
- PPI > 1.05：铸造费升至 1%（抑制过热）
- PPI < 0.95：开启「稳定债券」（折价铸造，未来赎回获利）
- 双轨：市场价 < PPI → 折价铸造（1 PLT = 0.98 PPI）；市场价 > PPI → 溢价赎回（1 PLT = 1.02 PPI）

### 1.4 手续费分配（**修正白皮书自相矛盾**）

> 白皮书 §2.3 写 70% 销毁 / 30% 储备；§8.4 写 45/30/25。**采用 §8.4：**

- **45%** → 回购销毁 PLT
- **30%** → 注入储备池
- **25%** → PLTG 质押分红（按周 USDC）

### 1.5 PLTG 治理代币

固定 **10 亿**：社区激励 40%（5 年线性）/ 协议金库 25%（DAO）/ 核心团队 15%（2 年锁 + 3 年线性）/ 投资者 12%（1 年锁 + 2 年线性）/ 公开销售 8%（TGE 全解锁）。

---

## 2. TON 合约架构

### 2.1 技术栈
- **语言**：**Tolk**（TON 官方推荐语言；**Tact 已被官方弃用**，见编译器警告与 <https://docs.ton.org/tolk/overview>）
- **工具链**：**Acton**（官方新工具链）或 Blueprint（已标记 legacy）
- **代币标准**：Jetton（TEP-74 转账 + TEP-89 discovery）—— PLT + PLTG
- **钱包连接**：TON Connect
- **测试**：`@ton/sandbox` + Jest
- **说明**：`ton/` 下的 Tact 骨架（Phase 0 PoC）已验证工具链可用，但**生产合约改用 Tolk 重写**。

### 2.2 合约清单
| 合约 | 职责 |
|---|---|
| `PlanetCore.tolk` | 储备状态、PPI 计算、铸造/赎回、费率、稳定区间、迁移状态机 |
| `PltJetton.tolk` (+ Wallet) | PLT Jetton，弹性供应由 Core 铸/烧 |
| `PltgJetton.tolk` | PLTG 治理代币（固定 10 亿） |
| `Risk.tolk` | 单笔/窗口限额、全局暂停 |
| `Attestation.tolk` | 储备证明（托管方提交 total_value + holdings_hash） |

### 2.3 Solana → TON 映射
| Solana（现有代码） | TON（新） |
|---|---|
| `programs/planet` (Anchor) | `contracts/PlanetCore.tolk` |
| `ReserveState` 账户 | Tact 合约 state（`Reserve` struct） |
| `ppi.rs` | Tact 纯函数（定点整数） |
| `mint_burn.rs` | Tact 消息处理器 + Jetton mint/burn |
| `risk.rs` | `Risk.tolk` |
| `attestation.rs` | `Attestation.tolk` |
| SPL Token / Token-2022 | Jetton（TEP-74） |
| mint authority PDA | Core 作为 Jetton minter 的 admin |
| `Clock` + keeper | 链下 keeper 触发 rebalance |
| Pyth SDK | TON 预言机（§3 待定） |

### 2.4 铸造消息流
```
用户 ──TON Connect──► PlanetCore.Mint{usdc_amount}
  → 校验（风险限额 / 迁移状态）
  → 读取 PPI（预言机）
  → 计算 minted = D·(1−f)/PPI
  → 向 PLT Jetton Minter 发 Mint 消息
  → 更新储备/供应状态
```

---

## 3. 技术决策（已核 / 待定）

- ✅ **预言机源（已定）**：**Pyth Core 已于 2026-08-26 停止支持 TON**（官方公告）。
  - **RedStone（首选）**：明确支持 TON，Hybrid Push/Pull，300+ Pull feeds，是 BlackRock BUIDL / Securitize 等 RWA 的官方喂价方 → 最契合 RWA 指数叙事。
  - **DIA（备选/定制）**：支持 TON，30,000+ feeds，可定制长尾/RWA 数据 → 适合商品篮子这类非标准 feed。
  - Chainlink：非 EVM 仅 Aptos/Solana，**不支持 TON**。
  - **结论**：主用 **RedStone**，DIA 兜底定制商品 feed。商品覆盖仍是硬约束（多数商品无 feed）。
- [ ] **DEX**：STON.fi / DeDust / TONCO（再平衡执行 + 初始流动性）。
- ✅ **稳定币**：TON 上 USDT 已原生（~$14 亿），USDC 亦有 → 作为铸造抵押物。
- [ ] **Keeper**：链下定时（GitHub Actions / Cloudflare Cron）调用 rebalance。
- [ ] **储备证明存储**：Arweave 或链下，仅哈希上链（成本）。

---

## 4. 白皮书修正清单（TON 版必须修）

1. ❌ Pyth「支持 100+ 大宗商品」——**不实**，多数商品无 feed。
2. ❌ 链上用 `f64`——BPF/EVM 均不支持浮点，改定点整数 1e6。
3. ❌ `load_price_feed_from_account` 旧 API → 新 API（TON 则整体换）。
4. ❌ Clockwork 定时任务——**已停运**，改链下 keeper。
5. ❌ Synthetix 不在 Solana（在 Ethereum/Optimism）。
6. ❌ 手续费分配 70/30 vs 45/30/25 **自相矛盾** → 定 45/30/25。
7. ❌ 路线图日期（Q3/Q4 2025）已过期，重排。
8. ⚠️ 「1:1 储备」+「最低抵押率 105%」表述需统一。
9. ⚠️ 「Hedera 链上衍生品」对冲——来源可疑，删除或替换。

---

## 5. 分阶段里程碑

| 阶段 | 目标 | 交付物 |
|---|---|---|
| **Phase 0（合约）** | Tact 合约跑通 + testnet 部署 | `contracts/*.tolk` + 单测全绿 + testnet 地址 |
| **Phase 1（发射+入口）** | PLT Jetton 发射 + TG Mini App MVP | 公平发射 + 点数/空投 + 小程序上线 |
| **Phase 2（真实运行）** | 预言机 + keeper 再平衡 + LP | 真实 PPI + 再平衡 + Pancake 等价 LP |
| **Phase 3（扩展）** | 多链 hub-spoke | TON 枢纽 + BSC 镜像（见 `GTM.md` §7） |

---

## 6. TG Mini App 规格（MVP）

- **页面**：指数看板 / 商品篮子 / 买入赎回 / 我的持仓 / 点数任务
- **技术**：React + `@tonconnect/ui-react` + TON API
- **多语言**：英 / 中 / 西 / 土耳其 / 印尼 / 越南 / 俄
- **合规**：仅 TON + TON Connect（Telegram 硬性要求）

---

## 7. 开放问题

- [ ] 预言机源最终选型（§3）
- [ ] 阶段一商品篮子最终名单（受喂价覆盖限制）
- [ ] 是否需要 PLTG（无主体早期可暂缓，先只发 PLT）
- [ ] 目标市场优先级（中文圈 / 尼日利亚 / 土耳其 / 印尼 / 越南，先做一个）
