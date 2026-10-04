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

### S1 ✅ 预言机**双签**（2-of-2，本轮已实现）
`OracleState.signerKey2`：若配置了第二签名公钥，`SignedPriceUpdate` 必须携带**两个**有效签名
（`sigR/sigS` + `sig2R/sig2S`），任一无效即拒（`ERR_BAD_SIG`/`ERR_BAD_SIG2`）。
→ 单把签名钥被窃**不足以**篡改价格。**计划**：扩展为 **M-of-N**（阈值签名集）。

### S2 ⬜ owner 多签 + 时间锁（**最高优先级**）
- **推荐做法**：把 `owner` 设为一个 **TON 多签钱包地址**（v4 多签/标准 multisig）——**不改合约**，
  所有 owner 动作经 M-of-N 多签。
- 关键动作（`SetJettonMinter`/`SetOracle`/`SetSigner`/`SetLimits`/篮子）**两步 + 时间锁**：
  `Propose → (延迟 T) → Execute`，给社区退出/反应窗口。
- **计划**：实现 `Propose/Execute` 两阶段（或直接用外部 timelock 钱包作 owner）。

### S3 ⬜ 多源 oracle 交叉验证
- 现有两条路：**注册式 CAM** + **签名式**。**计划**：要求 **≥2 个独立源**对同一资产一致（或取中位），
  单源异常自动 `frozen`。RedStone+DIA 双源即此意（见 `oracle-ton.md`）。

### S4 ⬜ 审计与形式化
- 第三方审计（Halborn 类）+ 形式化（Certora/SMT）覆盖 PPI 数学、铸赎、镜像、护栏；
- 漏洞赏金；**未过审不上主网**。

### S5 ⬜ 运营安全
- RPC 换带 key 或自建（公共 toncenter 限流）；
- 部署 key/relayer key 分离（现为同一钱包）；
- relayer 钱包限额、监控与告警（gas/异常推价）。

## 4. 关键结论

- **最脆弱的是 owner 单钥**（能改 minter/oracle/篮子）→ **务必用多签钱包做 owner + 时间锁**（S2）。
- **预言机篡改**已由「时间戳单调 + 50% 跳变护栏 + 双签 + frozen 熔断」多重缓解；下一步 M-of-N 与多源（S1/S3）。
- **合约未审计**是上与不上主网的分界线（S4）。
- 这些**不替代** 1:1 所需的**真实托管 + 储备证明 + KYC**（见 `real-asset-1to1.md`）。

## 5. 待你决定
1. 是否把 owner 改为**多签钱包**（M/N 取值、签名人）？
2. 是否要**链上 Propose/Execute 时间锁**（还是用外部 timelock 钱包）？
3. 预言机阈值签名要 **2-of-2** 还是 **M-of-N**（N 多大）？
