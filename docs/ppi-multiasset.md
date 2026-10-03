# Planet 多资产 PPI —— 链上计算设计方案（待批复实施）

> 状态：**设计稿**。架构改动，实施前请确认。相关：`docs/TON-MAPPING.md`（`calculatePpi` 标为 TODO）、
> `ton/contracts/planet_core.tolk`、`ton/contracts/planet_basket.tolk`。

## 1. 现状

- `PlanetCore.currentPpi` 是一个**单值**：由 owner 的 `UpdatePrice` 或 oracle 的 `OracleUpdatePrice`
  **直接赋值**（`planet_core.tolk`）——即"别人告诉我 PPI 是多少"，**没有链上计算**。
- `PlanetBasket` 另存每个资产的 `weight/basePrice/currentPrice/positionValue`，但**只读展示**，
  与 Core 的 PPI **没有任何计算关系**（两处数据会分叉）。
- 白皮书定义：`PPI_t = Σ w_i · (P_i,t / P_i,base)`（加权价格指数，`PricePLT = PPI · USD_base`，`USD_base=1`）。
- `TON-MAPPING.md` 已规划：`calculatePpi`（TODO）+ `map<int, Asset>（商品索引 -> 权重/基准价/现价）` 放 Core。

## 2. 目标

Core **自己存篮子并在链上计算 PPI**；预言机改为推**单资产价格**，而不是最终 PPI 数字。

## 3. 关键约束

1. **TON 合约间不能同步读对方存储**（异步消息）。→ 篮子/价格必须与 PPI 计算**同处 Core**
   （正是 `TON-MAPPING` 的 `map<int, Asset>` 放 Core 方案），不能"从 PlanetBasket 读"。
2. **定点**：全 1e6；中间量用 257-bit `int` 防溢出（本仓已有踩坑，见 HANDOFF §7）。
3. **权重和 == `WEIGHT_SCALE`(1e6)**；基准价可锁定（不可变）。
4. **存储 ≤1023 bits**：现 `Storage` 约 919 bits + `oracleState` 1 ref。加 `assetCount:int64`(+64 → 983 ✓)
   与 `assets: map`（ref，不占 data bits → 2 refs ≤4 ✓）**可容纳**。需编译验证。

## 4. 数据结构（Core）

```tolk
struct Asset {
    weight: int64       // ppm, 1e6 = 100%
    basePrice: int64    // 1e6，锁定后不可变
    currentPrice: int64 // 1e6
}

struct Storage {
    // ...现有字段...
    assets: map<int64, Asset>   // 索引 -> 资产
    assetCount: int64
    baseLocked: bool
}
```

## 5. 消息

| 消息 | opcode | 权限 | 作用 |
|---|---|---|---|
| `SetBasketAsset { queryId, index, weight, basePrice }` | `0x10000009` | owner | 设/改某资产；锁价后禁改 `basePrice` |
| `OracleUpdateAssetPrice { queryId, index, price, timestamp }` | `0x1000000A` | 仅 oracle | 推单资产现价；时间戳单调（防重放）|
| `LockBasePrices { queryId }` | `0x1000000B` | owner | 锁定基准价 |

设置资产 / 推价后**自动重算** `currentPpi`（无需单独 `ComputePpi` 消息）。
现有 `UpdatePrice`(`0x10000003`) 与 `OracleUpdatePrice`(`0x10000007`)：建议**保留 `UpdatePrice` 作为 owner 应急覆盖**，
删除/停用 `OracleUpdatePrice`（oracle 改推资产价）——见 §9 决策。

## 6. 计算

```
PPI = Σ_{i=0}^{assetCount-1}  w_i · cur_i / base_i        // 全 1e6 定点
```

Tolk 纯函数（可单测）：
```tolk
fun assetTerm(weight: int64, currentPrice: int64, basePrice: int64): int64 {
    assert (basePrice > 0) throw ERR_BAD_BASE;              // 新增 106
    return ((weight as int) * (currentPrice as int) / (basePrice as int)) as int64;
}

// 遍历 map：用 0..assetCount-1 的索引循环（比 map 迭代更稳）
fun computePpi(assets: map<int64, Asset>, assetCount: int64): int64 {
    var sum: int = 0;
    var i: int = 0;
    while (i < assetCount as int) {
        val a = assets.mustGet(i as int64);
        sum += (a.weight as int) * (a.currentPrice as int) / (a.basePrice as int);
        i += 1;
    }
    return sum as int64;
}
```
> 缺价处理见 §9 决策（建议：缺价/零基准 → 拒绝，要求篮子配置完整后再启用）。

## 7. 与 PlanetBasket 的关系（二选一）

- **(i) 推荐**：Core 成为**篮子唯一真相源**；`SetBasketAsset` 后 Core **镜像**到 `PlanetBasket`
  （复用 `burn_mirror` 的镜像模式），App 继续读 Basket 的 getters；PlanetBasket 不再独立写。
- (ii) 双写：owner 同时给 Core 和 Basket 发消息（易分叉，不推荐）。
- (iii) 退役 PlanetBasket：App 直接读 Core getters（改动前端）。

## 8. 计算/存储示例

3 资产，权重 40%/35%/25%（和 =1e6），基准价 1.0/1.0/1.0，现价 1.10/0.95/1.02：
```
PPI = 0.40·1.10 + 0.35·0.95 + 0.25·1.02 = 0.440 + 0.3325 + 0.255 = 1.0275  → 1027500
```

## 9. 待你拍板

1. **是否采用方案 (i)**（Core 真相源 + 镜像 Basket）？
2. **缺价/权重和不为 100%** 的处理：拒绝原子操作（推荐）还是允许部分计算？
3. 是否**删除 `OracleUpdatePrice`**（单值推 PPI），统一改推资产价？还是保留作应急？
4. 是否保留 owner 的 `UpdatePrice` 作为**应急覆盖**（会与链上计算并存，需在文档明确语义）？

## 10. 测试计划（实施时）

- 单元 `calculatePpi/computePpi`：单资产、多资产、权重和=1e6、基准价变化、大额（int 防溢出）。
- 集成：`SetBasketAsset`×N → `OracleUpdateAssetPrice`×N → `ppi()` 等于预期；权重和≠1e6 拒绝；
  非 oracle 拒绝(103)、重放拒绝(104)、锁价后改 base 拒绝、缺基准价拒绝(106)。
- 覆盖率维持 ≥89%（门禁）。

## 11. 影响面

- Core：+3 消息、+存储段、+`computePpi`；`Storage` 需过 1023-bit 编译校验。
- 预言机侧：`docs/oracle-ton.md` 的适配器需按**资产 feed_id** 推价（而非推 PPI）。
- `PlanetBasket`：若采纳 (i) 则改为被 Core 镜像驱动；否则不变。
- 前端：可选展示每资产权重/现价/贡献。
- 无链上迁移问题（尚未部署）。
