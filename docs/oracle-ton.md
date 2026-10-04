# Planet × RedStone —— TON 预言机接入（调研 + 设计）

> 目的：把 HANDOFF §6 P2「RedStone 接入」从"需外部信息（模糊阻塞）"收敛为
> "接口已就绪，只差一个部署地址 + feed 清单"。

## 1. 结论摘要

- **RedStone 支持 TON**（2024-09 起，首个 TON 预言机），但官方 `@redstone-finance/ton-connector`
  被标注 **⚠️ Legacy — unmaintained**，合约用 **FunC** 写、需要 **TVM Upgrade 2023.07**，
  不再积极维护（见 redstone-oracles-monorepo `packages/ton-connector`）。
- **没有"大宗商品 PPI"这种 feed**：RedStone 提供的是**各资产价格**（如 ETH/BTC/…）。
  Planet 的 PPI 必须**自己用一组资产价格按篮子权重计算**（`planet_core.tolk` 的 PPI 数学 + 权重）。
- 数据模型（Pull）：价格由**终端用户**在调用时携带**签名数据包**上链，链上做**签名校验**；
  Push：由 relayer 定期把价格写入链上 adapter。TON 侧对应 `price_manager` / `price_feed` 合约。
- 外部只需提供两样：**① 已部署的 TON adapter 地址**（`price_manager`/`price_feed`），
  **② 我们要的资产 feed_id 清单**（篮子里的大宗商品符号）。这两样拿到即成"配置"，不再阻塞代码。

## 2. 我们已就绪的部分（本仓库）

`planet_core.tolk` 已实现**价格预言机接缝（oracle seam）**：

| 消息 | opcode | 权限 | 作用 |
|---|---|---|---|
| `SetOracle { queryId, oracle }` | `0x10000006` | owner | 指定预言机地址（= RedStone adapter） |
| `OracleUpdatePrice { queryId, price, timestamp }` | `0x10000007` | 仅 oracle | 只允许注册的预言机推价；**timestamp 必须严格递增**（防重放） |

- 存储新增 `oracle: address`、`lastOracleUpdate: int64`。
- 新增错误码：`ERR_NOT_ORACLE = 103`、`ERR_STALE_PRICE = 104`。
- 保留 owner 的 `UpdatePrice`（`0x10000003`）作为**手动兜底**。
- 测试：`ton/contracts/tests/oracle.test.tolk`（owner 设 oracle / 非 owner 拒绝 / oracle 推价 / 非 oracle 拒绝 / 重放拒绝）。

## 3. 接入路径（拿到外部信息后）

推荐：**Owner 把 `oracle` 设为 RedStone 的 TON adapter 地址**，由 adapter（或一个薄的
Planet 适配器合约）在收到已校验的价格后，向 PlanetCore 发送 `OracleUpdatePrice`：

```
RedStone payload → RedStone TON adapter（签名校验，FunC）→ PlanetCore.OracleUpdatePrice(ppi, ts)
```

若需多资产→PPI 聚合：在 PlanetCore（或独立适配器）里维护各资产最新价，
按篮子权重计算 `ppi`，再写入 `currentPpi`。**留待 feed 清单确定后实现**（需要知道具体 feed_id 与小数位）。

## 4. 仍未解除的外部依赖（给下个会话）

1. RedStone 在 TON（testnet/mainnet）上**已部署的 `price_manager`/`price_feed` 合约地址**。
2. 篮子对应的 **feed_id 清单**（以及各 feed 的小数位），用于计算 PPI。
3. （可选）确认采用 Pull（用户携带 payload）还是 Push（relayer 写入）——影响适配器设计。

> 备用预言机 **DIA** 亦支持 TON；若 RedStone 的 legacy 连接器可用性存疑，可评估 DIA 的 TON 方案再做选择。

## 5. 已实现的两种接入接缝（把外部依赖降到"一个公钥"）

1. **注册式**：owner 用 `SetCam{index, cam}` 登记每个指数的 CAM/adapter 地址；对方发 `CamUpdate{index, price, volatility, liquidity, riskState, timestamp}`。
2. **签名式（无需登记地址）**：owner 用 `SetSigner{key}` 登记一个 **ed25519 公钥**；任何 relayer 发
   `SignedPriceUpdate{sigR, sigS, payload}`，Core 用 `isSignatureValid(payload.hash(), sig, signerKey)` **链上验签**
   （签名 R‖S 拼接；`timestamp` 单调防重放、`weightsSum==1e6` 严格校验）。

→ 因此"接真实数据源"**只差一个公开公钥**（或选择注册式时一个 adapter 地址 + feed_id 清单）；
链上逻辑与测试（`ton/contracts/tests/signed_oracle.test.tolk`、`cam.test.tolk`）均已就绪。
