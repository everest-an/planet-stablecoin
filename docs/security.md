# Planet 安全设计（威胁模型与加固）

> 状态：活文档。区分**已实现**与**计划**。关联：`docs/AUDIT.md`（信任模型）、`docs/commodity-cam.md`、
> `docs/oracle-ton.md`、`docs/real-asset-1to1.md`。

## 1. 资产与信任边界

| 资产 | 谁能改 | 风险 |
|---|---|---|
| PLT 供应 / 储备记账 | JettonMinter（唯一真相源）+ Core 镜像 | 伪造 mint/burn |
| 篮子 / PPI | owner / oracle / CAM | **价格篡改** → 打偏 PPI |
| 费率/限额/熔断/风险基金 | owner | 单钥滥用 |
| JettonMinter admin | owner（SetJettonMinter） | 换 minter 劫持铸赎 |
| owner 本身 | 单钥 | **单点**（最脆弱） |

## 2. 已实现的防护

| 威胁 | 防护 |
|---|---|
| **预言机重放** | `OracleState.lastOracleUpdate`，推价 `timestamp` 必须**严格递增** |
| **单次价格篡改** | **价格跳变护栏**：单次更新相对现价跳变 >50%（`MAX_PRICE_JUMP_PPM`）即拒绝（`116`） |
| **预言机密钥被窃** | **阈值签名集（2-of-N）**：需 M 个**不同**来源的有效签名（`117`） |
| **单商品坏数据** | CAM `riskState=frozen` → **不进 PPI**（按活跃资产重归一化）+ RTRA 不调仓 |
| **极端偏离** | `|PPI-1|>15%` → **冻结铸币**（`ERR_DEVIATION`） |
| **越权** | 所有 owner 动作 `assert(sender==owner)`；oracle 动作 `assert(sender==oracle/cam)` |
| **重入/伪 opcode** | `AllowedMessage.fromSlice` + `else throw 0xFFFF` |
| **数值溢出** | 定点 1e6、中间量 257-bit `int`、存储字段定宽 |
| **存储膨胀** | 单 cell ≤1023 bits；超限放 ref cell |
| **赎回脱节** | minter `totalSupply` 为真相源，`BurnMirror` 回写 Core |

## 3. 缺口与加固计划（按优先级）

### S0 ✅ 价格跳变护栏（本轮已实现）
单次推价跳变上限 50%，限制"一次篡改把 PPI 打飞"。**注意**：真实重建仓/reset 需 owner 分批推价。

### S1 ✅ 预言机**阈值签名集（M-of-N 多源）**（已实现）
`SetSigner{index,key}` 注册 N 个来源公钥；`SetThreshold{m}` 设阈值。
- **M≤2**：`SignedPriceUpdate{sig1,sig2,payload}`（两个签名槽）。
- **M>2**：`SignedPriceUpdateN{sigs,payload}`——`sigs` = `uint8 count` + `count` 个 ref（每个一个 512-bit 签名），
  链上以 **bitmask** 找出 **M 个互不相同**且各自有效的签名者；不足即拒（`ERR_BAD_SIG`/`ERR_BAD_SIG2`，`ERR_NO_SIGNER`）。
→ **单把钥被窃不足以篡改价格**；同一把钥签多次只算一次。3-of-3（三源）已测试通过。

### S2 ✅ owner 多签 + 时间锁（已实现）
- **`SetOwner`**：owner 可把所有权**迁移到 TON 多签钱包**（M-of-N）。
- **`PlanetTimelock`**（独立合约，**Core 零改动**）：`Propose{dest,body}` → 等 `delay` 秒（`blockchain.now()`）→ `Execute`，
  把 body **原样重放**给目标；owner 可 `Cancel`。把 Core 的 owner 设为 timelock → **所有 owner 动作都需延迟**。
- **组合做法**：把 timelock 的 owner 设为 **TON 多签钱包** → 同时得到 **M-of-N + 时间延迟**。
- 部署：`PlanetCore.SetOwner(<timelock>)`，再 `PlanetTimelock.TlSetOwner(<multisig>)`。

### S3 🟡 多源 oracle 交叉验证
- 现有两条路：**注册式 CAM** + **签名式（M-of-N）**。M-of-N 阈值签名（S1）已要求多个独立来源**对同一 payload 一致**。

### S4 ⬜ 审计与形式化（外部依赖）
**就绪度**（可交付审计方）：合约清单 + ABI（`ton/Acton.toml`、`ton/build/abi`）、**107 个测试 / 90.2% 覆盖率**
（门禁 90）、威胁模型（本文）、状态交接（`HANDOFF.md`）、测试网 live 地址。
**仍需外部**：第三方审计（Halborn/Certora 类）+ 形式化（PPI 数学、铸赎、镜像、护栏）+ 漏洞赏金。**未过审不上主网。**

### S5 ⬜ 运营安全
- RPC 换带 key 或自建（公共 toncenter 限流）；
- 部署 key/relayer key 分离（现为同一钱包）；
- relayer 钱包限额、监控与告警（gas/异常推价）。

## 4. 关键结论

- **owner 单钥**曾是最脆弱点 → 现已由 **`SetOwner` + `PlanetTimelock`（+ 多签 owner）** 缓解（S2）。
- **预言机篡改**由「时间戳单调 + 50% 跳变护栏 + M-of-N 阈值签名 + frozen 熔断」多重缓解（S0/S1）。
- **合约未审计**是上与不上主网的分界线（S4）。
- 这些**不替代** 1:1 所需的**真实托管 + 储备证明 + KYC**（见 `real-asset-1to1.md`）；外部依赖清单见 §6。

## 5. 待你决定
1. owner 多签的 **M/N 取值与签名人**；
2. timelock 的 **delay**（建议 24–72h）、是否给关键动作设更长延迟；
3. 预言机阈值 **M/N**（建议 3-of-5 多源）。

## 6. 上线主网的**外部**依赖（非代码）
| 项 | 内容 | 归属 |
|---|---|---|
| 审计 | 第三方审计 + 形式化 + 赏金 | 外部 |
| 1:1 | 真实大宗商品托管方 + 储备证明（PoR）+ 合规/KYC | 外部（`real-asset-1to1.md`） |
| 运营 | 自建/带 key RPC、部署 key 与 relayer key 分离、gas/异常推价监控告警 | 运营 |
| 钱包 | 部署 TON 多签钱包作为 owner（+ timelock） | 运营 |
