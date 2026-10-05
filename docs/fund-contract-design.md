# Fund 合约设计（代币化 ETF 基金）

> 目标：把 PLANET 从"合成指数 PoC"改造成**代币化 ETF 基金**：客户买 PLT → 运营方**真实买入 ETF** →
> 托管 → PLT = **基金份额（按 NAV 定价）**→ 收**管理费 + 申赎价差** → 篮子涨，客户真赚。
> **本文件是设计稿（接口/状态/流程/安全），不含最终代码。** 关联：`tokenized-etf-fund.md`、`audit-report.md`。

---

## 0. 关键原则

1. **绝不凭空铸币（修 EC1）**：铸造**只能**在「用户入金 **且** 托管方确认已买入 ETF」之后发生。
2. **份额价值 = NAV**（不是商品 PPI）。NAV 由**托管方签名 attest**（复用现有 **签名 + M-of-N + 时间戳单调**）。
3. **两阶段**（申购/赎回都先挂单、后确认），**可超时退款**——不信任单方。
4. **治理**：`owner = 多签 + 时间锁`（复用 `PlanetTimelock`）。
5. **不重造轮子**：复用 PLT TEP-74、预言机签名设施、测试/CI/审计成果。

## 1. 合约形态

**新建 `PlanetFund.tolk`**（干净）、**不改**现有 `PlanetCore`（保留作"指数展示 PoC"）。
PLT（Jetton minter/admin）归 Fund 管理。

```
User ──Subscribe{usd}──► PlanetFund ──(pending)──► 链下: 券商买入 ETF ──► 托管
                              ▲                                              │
                              └──── ConfirmMint{naV} (托管 M-of-N 签名) ◄────┘
                              └────► mint PLT @ NAV − 申购费
User ──RequestRedeem{shares}─► PlanetFund ──(待办)──► 链下: 卖出 ETF ──► ConfirmRedeem{nav} ──► 付款 + 烧份额
```

## 2. 状态（Storage）

```tolk
struct Order {
    user: address
    amount: int64     // 申购: USDC(6d)；赎回: 份额
    navAtRequest: int64
    ts: int64
    done: bool
}

struct FundStorage {
    owner: address
    jettonMinter: address          // PLT minter
    custodian: address             // 托管/券商签名者（或多签集合，见 §5）
    navPerShare: int64             // 1e9（每份净值），托管 attest
    lastNavUpdate: int64           // 单调时间戳（防重放）
    mgmtFeeBps: int64              // 年管理费（在 NAV 内计提）
    mintFeeBps: int64              // 申购价差
    redeemFeeBps: int64            // 赎回价差
    paused: bool
    kycRequired: bool
    allowed: map<address, bool>    // KYC 白名单（可选）
    minNav: int64                  // 0.01 之类，防恶意低 NAV
    navJumpBps: int64              // 单次 NAV 跳变上限（如 2000=20%）
    orders: map<int64, Order>      // queryId -> 订单（申购/赎回共用，op 区分）
    orderCount: int64
}
```

## 3. 消息（ops）

| op | 名字 | 谁发 | 作用 |
|---|---|---|---|
| `0x30000001` | `Subscribe { queryId, usd }` | 用户 | 登记申购；随附付款（TON/USDC）→ 生成 pending 订单 |
| `0x30000002` | `ConfirmMint { queryId, navPerShare, timestamp }` | **托管(M-of-N)** | 确认 ETF 已买入 → 按 NAV−申购费 **铸 PLT** 给用户 |
| `0x30000003` | `RequestRedeem { queryId, shares }` | 用户 | 锁定/标记份额赎回 → pending |
| `0x30000004` | `ConfirmRedeem { queryId, navPerShare, timestamp }` | **托管(M-of-N)** | 确认 ETF 已卖出 → **烧份额 + 付款**给用户 |
| `0x30000005` | `AttestNav { queryId, navPerShare, timestamp }` | **托管(M-of-N)** | 更新 `navPerShare`（带跳变护栏 + 单调时间戳） |
| `0x30000006` | `CancelOrder { queryId }` | 用户/owner | 超时/取消 → 退款（未确认时） |
| `0x30000007` | `SetFees { mgmtBps, mintBps, redeemBps }` | owner | 费率 |
| `0x30000008` | `SetCustodian { custodian }` | owner | 换托管 |
| `0x30000009` | `SetKyc { required }` / `Allow { addr, ok }` | owner | KYC 策略 |
| `0x3000000A` | `SetPaused { paused }` | owner | 熔断 |
| `0x10000014` | `SetOwner` | owner | 迁移到多签（复用） |

## 4. 关键流程

### 4.1 申购（两阶段，防凭空铸）
1. 用户发 `Subscribe{queryId, usd}` + 付款（USDC jetton 或 TON）。
2. Fund 记 `orders[queryId] = Order{user, amount: usd, navAtRequest: navPerShare, ts, done:false}`。
   （**不铸币**。）
3. **链下**：运营方用这笔钱在券商**买入**目标权重 ETF，进托管账户。
4. 托管方发 `ConfirmMint{queryId, navPerShare, ts}`（**M-of-N 签名**）：
   - 校验：`order` 存在且未完成；`ts > lastNavUpdate`；`navPerShare` 合法（≥minNav、跳变≤navJumpBps）；
   - `shares = usd × 1e6 / navPerShare ×(1 − mintFeeBps/1e4)`；
   - 通过 minter **铸 PLT** 给 `order.user`；`done=true`；更新 `navPerShare`。
5. 超时未确认 → 用户 `CancelOrder` 退款。

### 4.2 赎回（两阶段）
1. 用户 `RequestRedeem{queryId, shares}`（份额由 Fund 托管/锁定，或先烧后确认）。
2. 链下卖出对应 ETF。
3. 托管 `ConfirmRedeem{queryId, navPerShare, ts}` → `payout = shares × navPerShare / 1e6 × (1 − redeemFeeBps/1e4)` → 烧份额 + 付款。
4. 超时 → 取消、退回份额。

### 4.3 NAV + 管理费
- `navPerShare` 由托管**定期 attest**；fund 只在链上存最新值。
- **管理费在 NAV 内计提**（托管计算 NAV 时扣除）——即 attest 的 NAV 是**净费后**；链上另在申赎时收**价差费**。
- 护栏：`navPerShare ≥ minNav`、`|Δnav| ≤ navJumpBps`、`ts` 单调。

## 5. 托管签名 = M-of-N（复用现有设施）

- 直接复用 `signed_price` / `priceHash` 模式：对 `(域标 + 本合约地址 + payload)` 签名，**域分隔**防跨部署重放。
- 托管密钥为 **M-of-N**（如 2-of-3：托管 + 运营 + 第三方审计方）——**单把钥被窃无法伪造 NAV/确认**。
- `SetCustodian` 可轮换；轮换走 owner（多签+时间锁）。

## 6. 安全设计（直接映射审计教训）

| 风险 | 对策 |
|---|---|
| **凭空铸币（EC1）** | 铸币**只**发生在 `ConfirmMint`（托管 M-of-N），不在 `Subscribe` |
| **NAV 篡改** | M-of-N 签名 + 跳变护栏 + 单调时间戳 + minNav |
| **重放 / 跨部署重放** | queryId 幂等 + **域分隔**签名 |
| **整数/负值** | 所有金额 `> 0`；赎回付款做 reserve 下溢断言（见 `audit-report` AR2/AR3/NEW-3） |
| **bounce** | 实现 `onBouncedMessage`（忽略，参 `NEW-1`） |
| **owner 单点** | `SetOwner`→多签 + `PlanetTimelock` |
| **铸币后 minter 失败（SC1）** | 两阶段：**确认后**才铸；minter 失败则订单不完成 |
| **用户被夹/超时** | 订单可取消 + 超时退款；不锁定用户资金 |

## 7. 从现状迁移（复用 / 改造）

| 复用 ✅ | 改造 🔧 | 弃 ❌ |
|---|---|---|
| PLT TEP-74（minter+wallet） | `Mint`→**入金+托管确认**驱动 | 商品 PPI 作为**计价**（可留作展示） |
| 签名/M-of-N/域分隔/时间戳设施 | 费率语义→管理费+价差 | 商品稳定性机制（分档费/债券/风险基金）**作为锚定手段** |
| `owner+SetOwner+PlanetTimelock` | 增加 `PlanetFund` 合约 | "稳定币/1:1 商品储备"叙事 |
| 测试/CI/覆盖率/审计成果 | 前端→申购/赎回/NAV/持仓展示 | — |

## 8. 链下与合规（非代码，但决定成败）

- **券商 + 托管账户**：真正买卖 ETF、并按目标权重再平衡。
- **储备证明**：定期 attest（最好第三方）+ 链上可验。
- **KYC/AML + 法币出入金**。
- **牌照/募集说明书**：PLT 即"基金份额/证券"，**这是"能不能做"的门槛**。

---

## 9. 交付顺序建议
1. 本设计评审 → 2. `PlanetFund.tolk` 骨架（状态/消息/权限）+ 单元测试（**先做两阶段申购 + NAV 护栏**）→
3. 接 minter 的**确认后铸币**（端到端）→ 4. 赎回 → 5. 费率/NAV 计提 → 6. 审计。

> **红线**：合规落地前，只能作为 PoC/演示；**不得对外募资/发行**。
