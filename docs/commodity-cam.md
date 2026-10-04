# Planet × CAM（Commodity Adapter Module）—— 解耦与多维风控设计稿

> 状态：**设计稿**（待批复实施）。把"大宗商品资产逻辑从 PLT 核心解耦"的想法，映射到本仓现有代码
> （`ton/contracts/planet_core.tolk`、`oracle_state.tolk`、`docs/oracle-ton.md`、`docs/ppi-multiasset.md`）。

## 0. 提案要点（来自启发）

1. **解耦核心与商品逻辑**：不要让 PPI 计算 / RTRA 直接对接原始喂价；引入 **CAM 插件层**，每类商品
   （WTI、黄金、橡胶、碳信用…）一个独立 CAM 合约，向核心输出**标准化**的：实时价格 / 波动率 /
   流动性评分 / 风险状态。新增或下线商品**不改核心**；单一商品故障**被隔离**。
2. **多维风控**：CAM 不只给价格，还给风险维度，用于**优化 RTRA 再平衡触发**。

## 1. 现状对照（我们已具备的地基）

| CAM 提案 | 本仓现状 |
|---|---|
| 每个商品独立适配器 | 已有 **oracle seam**（`SetOracle`），但只有**一个** oracle 推**单资产价** |
| 统一接口取标准化数据 | `OracleUpdateAssetPrice{index, price, timestamp}` 已是雏形，但只有 **price** 一维 |
| PPI 只读标准化输出 | ✅ 已实现：`computePpi` 只读 Core 内 `CoreAsset`，**不碰原始喂价** |
| 单商品故障隔离 | ✅ 部分：`handleOracleUpdateAssetPrice` 逐资产、严格校验，坏数据不污染其它资产 |
| 多维风险驱动 RTRA | ❌ 未做：`shouldRebalance` 只看权重漂移，且**无风险输入** |

**结论**：CAM 提案与现有方向一致，是 oracle seam 的**自然推广**——从"单一 oracle 推价格"升级为
"每商品一个 **CAM**，推**标准化多维数据**"。地基已就绪，改动是**增量**的。

## 2. 关键约束（TON 异步）

TON 合约**不能同步读** CAM 的 getter。因此 CAM→Core 必须走 **push**（CAM 主动把标准化数据发给 Core），
这一点同 `BurnMirror` / `OracleUpdateAssetPrice` 模式。Core 按索引存各资产的最新标准化快照。

## 3. 目标架构

```
        ┌────────────┐  standardized update   ┌──────────────┐
WTI ───►│ CAM: WTI   │──── CamUpdate ────────►│              │
金  ───►│ CAM: Gold  │──── CamUpdate ────────►│  PlanetCore  │  store per-asset snapshot
碳  ───►│ CAM: Carbon│──── CamUpdate ────────►│  · PPI       │  computePpi (price only)
        └────────────┘                        │  · RTRA      │  shouldRebalance (risk-aware)
   (每商品一合约，隔离)                        └──────────────┘
```

**CAM 统一输出**（标准化，写在消息里）：
- `price`：1e6 定点
- `volatility`：1e6 定点（年化，或 bps）
- `liquidity`：0..1e6 分
- `riskState`：`0=normal / 1=caution / 2=frozen`

## 4. 接口设计（Core 侧新增）

```tolk
// CAM 推送（仅注册为某 asset index 的 CAM 可发）
struct (0x1000000C) CamUpdate {
    queryId: int64
    index: int64
    price: int64       // 1e6
    volatility: int64  // 1e6
    liquidity: int64   // 0..1e6
    riskState: int64   // 0/1/2
    timestamp: int64   // 单调（防重放，按 index）
}

// owner 为某资产登记其 CAM 合约
struct (0x1000000D) SetCam {
    queryId: int64
    index: int64
    cam: address
}
```

**存储**（均在 ref cell/map 内，不撑爆 1023-bit）：
- 扩展 `CoreAsset { weight, basePrice, currentPrice, volatility, liquidity, riskState }`（map 值，ref 内）。
- 新增 `cams: map<int64, address>`（index → CAM）。
- 每资产独立 `lastUpdate`（可放入 `CoreAsset` 或单独 map）。

**校验**：`sender == cams[index]`；`timestamp` 按 index 单调；`liquidity ∈ [0,1e6]`、`riskState ∈ {0,1,2}`；
`price > 0`。任一不过 → 拒绝（新增错误码）。

## 5. 多维风险驱动的 RTRA（第 2 点）

现有：`shouldRebalance(weight, positionValue, totalReserve)` 仅比较 |drift| 与固定阈值 0.5%。

建议改为**风险自适应阈值**（核心只消费 CAM 标准化风险，不自己算波动率）：

```
effectiveThreshold = REBALANCE_THRESHOLD
    · (1 + volatility_k)          // 高波动 → 提高阈值（更少频繁交易、避免噪声）
    / (liquidity_k)               // 低流动性 → 提高阈值（避免在薄市场冲击成本）
riskState == 2 (frozen)  → 该资产不参与再平衡（并可触发全局暂停/告警）
riskState == 1 (caution) → 阈值再加成 / 只允许减仓
```

**分级裁剪**：先落地"冻结即跳过"+"高波动/低流动性抬阈值"两条最小规则，后续再调参。

## 6. 分期实施（建议）

- **Phase A（纯代码，无外部数据）**：加 `CamUpdate`/`SetCam`；扩展 `CoreAsset`；Core 接受注册 CAM 的更新；
  写一个**MockCam 测试合约**在 emulator 里推数据；risk-aware `shouldReallocate`。→ CI 可全绿验证。
- **Phase B（需外部数据）**：每商品实现真实 CAM（数据源 = RedStone/DIA feed_id 或自有聚合）。**受外部阻塞**。
- **Phase C**：CAM 注册治理（owner→多签/DAO）、隔离性与限额的形式化验证。

## 7. 收益与隔离性论证

- **不改核心上新商品**：`SetBasketAsset` + `SetCam` 即可。
- **故障隔离**：坏 CAM 只能改**自己 index** 的快照；`computePpi` 用 `int` 定点且逐资产，其它资产不受影响；
  范围校验挡住越界值；`riskState=frozen` 可把该资产从再平衡中摘除。
- **信任边界**：CAM 是**按商品**的可信适配器（owner 登记）；比"单一全局 oracle"故障面更小。

## 8. 待你拍板

1. 是否按 **Phase A** 先做（MockCam + risk-aware RTRA，纯代码可验证）？
2. **CAM 粒度**：每商品一个 CAM，还是每"商品类"一个（如所有农产品一个）？
3. `volatility`/`liquidity` 的**单位与算法**归属：CAM 计算（推荐）还是 Core 用价格序列自算？
4. `riskState` 三种状态下 Core 的**动作**：仅影响再平衡？还是也影响 mint/赎回/费率？
5. `volatility_k`/`liquidity_k` 的**权重系数**初值与可调方式（owner 设参 vs 硬编码常量）。

---

> 与现有文档的关系：`docs/oracle-ton.md`（数据源）/ `docs/ppi-multiasset.md`（PPI 计算）/ 本文（适配器 + 风控）。
> Phase A 完成后，`OracleUpdateAssetPrice` 可由 `CamUpdate` 取代（CAM 成为唯一标准化入口）。
