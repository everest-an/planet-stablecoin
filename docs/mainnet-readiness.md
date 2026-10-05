# 上线主网检查清单（Mainnet Readiness）

> 状态：**未达主网条件** —— 当前为 TON 测试网 PoC。本清单是**与「上不上主网」直接挂钩**的门槛，
> 区分 **代码/合约（可自控）** 与 **外部依赖（需第三方/RWA/合规）**。
> 关联：`docs/HANDOFF.md`（唯一可信状态）、`docs/security.md`（威胁模型）、`docs/real-asset-1to1.md`。

图例：✅ 已就绪 · 🟡 部分/进行中 · ⬜ 未做（阻塞上线）

---

## A. 合约与代码

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| A1 | 测试覆盖 + CI 门禁 | ✅ | 108 测试 / 90.2%（门禁 90，棘轮只升不降），CI 全绿 |
| A2 | 链上多资产 PPI + 铸赎 + 赎回镜像 | ✅ | 见 `docs/ppi-multiasset.md`、`burn-linkage.md` |
| A3 | 预言机**多源 + 门限** | ✅ | Yahoo+Sina 双源中位数；M-of-N 签名集（`SetSigner`/`SetThreshold`，含 M>2） |
| A4 | 价格篡改防护 | ✅ | 时间戳单调 + 50% 跳变护栏 + frozen 熔断 |
| A5 | owner 治理 | ✅ | `SetOwner` + `PlanetTimelock`（Propose→delay→Execute，SetOwner 往返链上验证） |
| A6 | **第三方审计** | ⬜ | **阻塞项**。审计 PPI 数学/铸赎/镜像/护栏/CAM + 形式化不变量 |
| A7 | 漏洞赏金 | ⬜ | 建议审计后启动 |
| A8 | 升级/迁移方案 | ⬜ | 是否可升级？现为不可变；需明确「迁移=新合约 + `SetOwner` 切流」的 runbook |

## B. 密钥与运营安全

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| B1 | owner = **多签钱包 + 时间锁** | 🟡 | 合约就绪；**需部署 TON 多签钱包**并 `SetOwner`（timelock 的 owner 设为多签） |
| B2 | 部署 key 与 relayer key **分离** | ⬜ | 现为同一钱包；主网必须分离（relayer key 仅能发签名推价） |
| B3 | RPC | 🟡 | 前端支持 `VITE_TONCENTER_API_KEY`；主网需**带 key/自建** RPC + 冗余 |
| B4 | gas 监控告警 | ✅ | `relayer.mjs check` + 每日 `relayer-check.yml`（低于 0.2 TON 报警） |
| B5 | 推价**生效校验** | ✅ | relayer 读回 `lastOracleUpdate` + 每资产 `currentPrice` 核对，失败即报错 |
| B6 | 监控/告警 | ⬜ | 推价异常、PPI 偏离、冻结事件、余额、失败率 → 接入告警 |
| B7 | 应急预案（pause/熔断） | 🟡 | 合约有 `SetPaused`/偏离冻结；需成文 runbook + 值班 |

## C. 预言机与数据

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| C1 | 多源交叉验证 | ✅ | Yahoo+Sina（spread ≤0.1%）；偏离 >2% 自动 frozen |
| C2 | 接 **RedStone/DIA** 生产源 | ⬜ | 需其 endpoint/key + feed 映射（`docs/oracle-ton.md`） |
| C3 | CAM 注册式路径接真实 adapter | 🟡 | 合约接缝（`SetCam`/`CamUpdate`）已就绪并测试；真实 CAM 数据源待接 |
| C4 | 源可用性 SLA / 降级 | ⬜ | 单源失败时的降级与告警策略 |

## D. 1:1 真实资产（RWA）—— 外部，最终形态的前提

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| D1 | 实物/ETF 托管方 + 托管协议 | ⬜ | 见 `docs/real-asset-1to1.md` |
| D2 | 储备证明（PoR）/ 实时 attestation | ⬜ | 链上可核验的储备 |
| D3 | 铸造/赎回与托管的对手方流程 | ⬜ | 法币/实物出入金、结算周期 |
| D4 | 合规 | ⬜ | 证券/商品属性分析、KYC/AML、辖区牌照 |

## E. 前端 / 分发

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| E1 | 统一设计系统 | ✅ | `app-tg/DESIGN.md`（Aptos 风单色终端）+ 自定义钱包按钮 |
| E2 | 主题 + Telegram 接线 | ✅ | 亮/暗切换（记忆）+ 读 Telegram `colorScheme` |
| E3 | 自托管 TON Connect manifest | ⬜ | 现为 demo manifest；**发布前必须自托管** |
| E4 | 托管/域名/发布流程 | ⬜ | 静态托管 + 版本/回滚 |

## F. 法律 / 沟通

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| F1 | 白皮书 / 免责声明 / ToS | 🟡 | 白皮书 v1.5 有；需正式化 + 法务审阅 |
| F2 | 风险披露（非足额抵押、PoC 声明） | ✅ | README / 白皮书已标注 |
| F3 | 上线预案与对外沟通 | ⬜ | 里程碑、公告、支持渠道 |

---

## 上线判定（Gate）

**允许主网的必要条件（全部满足）：**
1. **A6 第三方审计通过**且高危项清零；
2. **B1 多签 + 时间锁**已上线，**B2 密钥分离**；
3. **B4/B5/B6** 监控告警 + 推价校验 + 应急 runbook；
4. **C2 至少一个生产级预言机源**（RedStone/DIA）或 3 源交叉；
5. **E3** 自托管 manifest、E4 托管就绪；
6. **F1/F3** 法务与沟通就绪。

**「1:1 足额抵押稳定币」额外需要：D1–D4**。在此之前，PLT 定位为**合成指数代币（PoC）**，非足额抵押。

> 结论：**代码侧已接近就绪（A/B4/B5/C1 达成）**；**审计（A6）+ 真实预言机源（C2）+ 密钥分离（B2）+ RWA/合规（D）**是当前主要缺口。
