# Planet 赎回（burn）链路打通 —— 设计方案（待批复实施）

> 状态：**设计稿**。架构改动，实施前请确认方向。相关代码：
> `ton/contracts/planet_core.tolk`、`ton/contracts/jetton/JettonWallet.tolk`、`ton/contracts/jetton/JettonMinter.tolk`。

## 1. 问题：现在有两条互不相通的"赎回"

| 路径 | 触发 | 实际效果 | 缺陷 |
|---|---|---|---|
| `PlanetCore.Burn`（`0x10000002`） | 用户给 **Core** 发 `Burn` | 只改 core 的 `totalSupply` / `totalReserve`（`planet_core.tolk:204`） | **不烧任何 Jetton** → minter 供应不变 |
| 钱包 `AskToBurn`（`0x595f07bc`） | 用户给自己的 **JettonWallet** 发 | 钱包扣余额 → minter `BurnNotificationForMinter` 减供应（`JettonMinter.tolk:24`） | **Core 完全不知情** → core 的 `totalSupply`/`totalReserve` 不减 |

**后果**：
- 与 HANDOFF §1 决策 5「PLT 供应量以 JettonMinter 为唯一真相源」**矛盾**——core 自维护的 `totalSupply` 会和 minter 分叉。
- 走 `AskToBurn` 赎回后，core 的 `totalReserve` 不减，**授权放款的兑付量算不对**。

## 2. 关键约束（决定方案可行性）

- 钱包只接受 **owner 自己**发来的 `AskToBurn`（`JettonWallet.tolk` 断言 `sender == owner`）。→ **Core 无法代替用户触发钱包 burn**，所以"让 core.Burn 去烧币"这条路走不通（除非改钱包 owner 模型，代价大）。
- **minter 的 admin 就是 PlanetCore**（部署时 `adminAddress = core.address`）。→ minter 已经知道 core 地址，**通知 core 不需要新增存储字段**。

## 3. 方案对比

| 方案 | 做法 | 信任/复杂度 | 结论 |
|---|---|---|---|
| **A（推荐）** | 钱包 `AskToBurn` → minter 减供应后，**minter 额外给 `adminAddress`(=Core) 发 `BurnMirror`** → core 同步减 `totalSupply`/`totalReserve` | 全链上、无需新增 keeper、无需改 minter 存储 | ✅ |
| B | 让 `Core.Burn` 去烧币 | 钱包拒绝非 owner | ❌ 不可行 |
| C | 用户先 `AskToBurn`，再由 owner/keeper 调 `Core.SyncBurn` | 需要额外可信消息 + 重放保护 | 备选（不想动 vendored minter 时） |

## 4. 方案 A 设计（推荐）

```
用户 ──AskToBurn──► 自己的 JettonWallet
                       │  扣余额；发 BurnNotificationForMinter(bounce=true)
                       ▼
                    JettonMinter
                       │  校验 sender == 该 owner 的钱包；totalSupply -= amt
                       │  （新增）发 BurnMirror{jettonAmount, initiator} ──► PlanetCore(=adminAddress)
                       ▼
                    PlanetCore
                       校验 sender == jettonMinter
                       totalSupply  -= jettonAmount
                       totalReserve -= burnAmount(jettonAmount, currentPpi)   // 应付出的 USD
                       记录事件
```

**Core 新增**（`planet_core.tolk`）：
```tolk
struct (0x10000008) BurnMirror {
    queryId: int64
    jettonAmount: int64   // 已从 minter 供应中扣除的 PLT
}

// AllowedMessage 联合加入 BurnMirror
fun handleBurnMirror(sender: address, msg: BurnMirror) {
    var storage = lazy Storage.load();
    assert (sender == storage.jettonMinter) throw ERR_NOT_MINTER;   // 新增 105
    assert (storage.totalSupply >= msg.jettonAmount) throw ERR_SUPPLY;
    val received = burnAmount(msg.jettonAmount, storage.currentPpi);
    storage.totalSupply -= msg.jettonAmount;
    storage.totalReserve -= received;
    storage.save();
}
```

**Minter 改动**（vendored 文件 `JettonMinter.tolk:24-44`，`BurnNotificationForMinter` 分支内、减完供应后加一段）：
```tolk
// 通知 PlanetCore 镜像这次销毁（admin 即 Core）
val mirrorMsg = createMessage({
    bounce: BounceMode.NoBounce,
    dest: storage.adminAddress,
    value: 0,
    body: BurnMirror { queryId: msg.queryId, jettonAmount: msg.jettonAmount },
});
mirrorMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
```
> 注意：`BurnMirror` 类型需在 minter 与 core 共享（放 `oracle_state.tolk` 那样的独立模块，或 minter 侧用裸 cell）。**多合约顶层类型同名会冲突**（见 HANDOFF §7）。

**Core 旧 `Burn` 怎么办**：删除，或降级为 owner-only 的管理性调整（避免与镜像双算）。Phase 1 建议**直接删除** `Burn` 消息，赎回统一走钱包 `AskToBurn`。

## 5. 需要拍板的细节

1. **`totalReserve` 扣多少**：`burnAmount` 用 `gross*(1-f)`（含 0.5% 费，`planet_core.tolk:117`）。提案：core 按 **净额**扣（与放款额一致）。
2. **`BurnNotificationForMinter` 已带 `sendExcessesTo`**：镜像消息是"额外一条出账"，费用从钱包剩余 TON 出；需保证钱包有足够 TON（测试里给足）。
3. **失败语义**：镜像消息用 `IGNORE_ERRORS`，即"若 core 拒绝，不影响销毁本身"。→ 会短暂出现 minter 已减、core 未减。可选：改用 `BOUNCE_ON_ACTION_FAIL` 让整条链回滚（更严格，但需 core 侧永不失败）。

## 6. 测试计划（实施时一并加）

在 `ton/contracts/tests/jetton_mint.test.tolk` 扩展（已有 mint→钱包→burn 全链路用例）：
- mint 100 万 → alice `AskToBurn` 10 万 → 断言 **minter.totalSupply == 90 万** 且 **core.supply() == 90 万** 且 **core.reserve() 按净额减少**。
- 非 minter 发 `BurnMirror` → 拒绝（105）。
- core 供应不足时 `BurnMirror` → 拒绝（102）。

## 7. 影响面

- `planet_core.tolk`：+1 消息、+1 处理器、+1 错误码；删 `Burn`。
- `jetton/JettonMinter.tolk`：`BurnNotificationForMinter` 分支 +1 出账（vendored 文件，需记录改动以便上游合并）。
- 测试：`jetton_mint.test.tolk` 增断言；覆盖率预计仍 ≥89%。
- 无链上迁移问题（尚未部署）。

---

**待你确认**：① 是否采用方案 A；② `totalReserve` 扣净额还是毛额；③ 镜像消息失败时是否需要 `BOUNCE_ON_ACTION_FAIL` 严格回滚。确认后我按此实施并保持 CI 绿。
