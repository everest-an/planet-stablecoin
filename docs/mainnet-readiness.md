# 上线主网检查清单（Mainnet Readiness）

> 状态：**未达主网条件** —— 当前为 TON 测试网 PoC。本清单是**与「上不上主网」直接挂钩**的门槛，
> 区分 **代码/合约（可自控）** 与 **外部依赖（需第三方/RWA/合规）**。
> 关联：`docs/HANDOFF.md`（唯一可信状态）、`docs/security.md`（威胁模型）、`docs/real-asset-1to1.md`、
> `docs/competitive-comparison.md`、`docs/audit-report.md`。

图例：✅ 已就绪 · 🟡 部分/进行中 · ⬜ 未做（阻塞上线）

---

## A. 合约与代码

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| A1 | 测试覆盖 + CI 门禁 | ✅ | **234 测试 / 19 文件**，All files **95.9% 行 / 88.2% 分支 / 94.0% 评分**（门禁 90，棘轮只升不降），CI 全绿 |
| A2 | 链上多资产 PPI + 铸赎 + 赎回镜像 | ✅ | 篮子 **14 商品**、权重各 ≤15% 且和 = 100%（链上强制） |
| A3 | 预言机**多源 + 门限** | ✅ | Yahoo+Sina 双源中位数；M-of-N 签名集（`SetSigner`/`SetThreshold`，含 M>2）；**域分离**防跨部署重放 |
| A4 | 价格篡改防护 | ✅ | 时间戳单调 + 50% 跳变护栏 + 源间 >2% 冻结（frozen 剔除并重归一化） |
| A5 | owner 治理 | ✅ | `SetOwner` + `PlanetTimelock`（Propose→delay→Execute，链上往返验证）；**治理级篮子管理** `GovernanceAddAsset`/`GovernanceSetWeight`（支持 `weight=0` 软下线，basePrice 永不可改） |
| A6 | **铸赎新鲜度护栏** | ✅ | `MAX_ORACLE_AGE = 6h`：预言机停摆时 **拒绝按陈旧价铸币**（此前是静默风险） |
| A7 | 跨合约 bounce 处理 | ✅ | 所有自研合约 `onBouncedMessage` 忽略弹回体（防误解析） |
| A8 | **第三方审计** | ⬜ | **阻塞项**。审计 PPI 数学/铸赎/镜像/护栏/CAM/Fund/Gov + 形式化不变量 |
| A9 | 漏洞赏金 | ⬜ | 建议审计后启动 |
| A10 | 升级/迁移 runbook | ⬜ | 合约不可变；需成文「迁移 = 新合约 + `SetOwner` 切流」（每次都是新地址 + 重配篮子） |

## B. 密钥与运营安全

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| B1 | owner = **多签钱包 + 时间锁** | 🟡 | 合约 + 时间锁已就绪；**工具就绪、待多签地址**：`relayer.mjs settimelockowner` + 工作流 `Timelock owner -> multisig`（新地址是输入参数）。迁完后治理 = **M-of-N + 60s 延时** |
| B2 | 部署 key 与 relayer key **分离** | ✅ | **已完成并链上验证**：relayer 热钱包 `0QC-PU0nx…` 独立，`signerAt(0)` 已轮换为新公钥，**旧 owner 密钥已移出签名集合**；`configure/register`（owner 操作）与 `push`（热密钥）在 CI 里分用不同 secret |
| B3 | RPC | ✅ | `TON_API_KEY` 已接入（Vercel env + GH secret，**仅服务端**）；冷调用 **~20s → 3.5s**；另有 5 分钟焐热任务 |
| B4 | gas 监控告警 | ✅ | `relayer.mjs check`（阈值可配 `MIN_GAS_TON`）+ 每日 `relayer-check.yml` |
| B5 | 推价**生效校验** | ✅ | relayer 读回 `lastOracleUpdate` + 每资产 `currentPrice` 核对，失败即报错 |
| B6 | 监控/告警 | ✅ | **`/api/v1/oracle` 健康端点**（新鲜度/签名阈值/权重和/frozen）+ `oracle-monitor.yml` 每 2 小时巡检，**状态翻转才告警**（TG + 工作流失败双信号） |
| B7 | 应急预案（pause/熔断） | 🟡 | 合约有 `SetPaused`/偏离冻结/新鲜度护栏；需成文 runbook + 值班 |
| B8 | 部署脚本"假成功"防护 | ✅ | `deploy.tolk` / `deploy_gov.tolk` 部署后**读回校验**（gas 不足会响亮失败） |

## C. 预言机与数据

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| C1 | 多源交叉验证 | ✅ | Yahoo+Sina 取**中位数**；源间价差 >2% 自动 frozen |
| C2 | 接 **RedStone/DIA** 生产源 | ⬜ | 需其 endpoint/key + feed 映射（`docs/oracle-ton.md`） |
| C3 | CAM 注册式路径接真实 adapter | 🟡 | 接缝（`SetCam`/`CamUpdate`）已就绪并测试；真实 CAM 数据源待接 |
| C4 | 源可用性 SLA / 降级 | 🟡 | 单源失败时降级为单源（**不会杀进程**，已修 `process.exit` 跳出 try/catch 的 bug） |
| C5 | 推价节流 | ✅ | 偏差门控（默认 0.1%）+ **6h 心跳上限**；推价成本 **~60× 下降** |

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
| E1 | 统一设计系统 | ✅ | `app-tg/DESIGN.md`（单色终端风）+ 自定义钱包按钮 |
| E2 | 主题 + Telegram 接线 | ✅ | 亮/暗切换 + Telegram `colorScheme`；菜单按钮 → Mini App |
| E3 | 自托管 TON Connect manifest | ✅ | `app-tg/public/tonconnect-manifest.json`（自托管） |
| E4 | 托管 / 域名 / 发布 | ✅ | Vercel（`ppppp.space` / `app.ppppp.space`），**push 即发** |
| E5 | 站点与公开资源 | ✅ | `/` `/dashboard` `/reports` `/docs` `/methodology` `/faq` `/whitepaper` `/api/v1/status` `/api/v1/oracle` `/openapi.json` `robots` `sitemap` `/.well-known/security.txt` |
| E6 | 自动化内容与运营 | ✅ | 月度报告（每月 1 号，自动生成+提交+发布+**自动发群**）；推价（每日）；健康监控（每 2h） |
| E7 | 社群入口 | 🟡 | ProtocolBank 群**置顶入口已上线**（6 按钮）+ bot 简介/命令；**Topics / 频道 / bot 改名待办（需真账号）** |

## F. 法律 / 沟通

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| F1 | 白皮书 / 免责声明 / ToS | 🟡 | 白皮书 **v1.6**（含「已实现 vs 设计」对照）+ 全站 PoC 划线；需正式化 + 法务审阅 |
| F2 | 风险披露（非足额抵押、PoC 声明） | ✅ | 站点每个页面、README、白皮书、`/faq`、bot 回复均标注 |
| F3 | 上线预案与对外沟通 | 🟡 | bot（自动问答）+ 群置顶 + 客服渠道已就绪；正式上线公告待定 |

---

## 上线判定（Gate）

**允许主网的必要条件（全部满足）：**
1. **A8 第三方审计通过**且高危项清零（含本仓 `docs/contract-review.md` 的发现）；
2. **B1 多签 + 时间锁**已上线（工具就绪，待地址），**B2 密钥分离 ✅**；
3. **B4/B5/B6** 监控告警 + 推价校验 + 应急 runbook（B7 待成文）；
4. **C2 至少一个生产级预言机源**（RedStone/DIA）或 3 源交叉；
5. **E3/E4** 自托管 manifest + 托管就绪 ✅；
6. **F1/F3** 法务与沟通就绪。

**「1:1 足额抵押稳定币」额外需要：D1–D4**。在此之前，PLT 定位为**合成指数代币（PoC）**，非足额抵押。

> 结论：**代码与运营侧已大幅就绪**（A1–A7、B2–B6、B8、C1/C5、E1–E6 ✅）。
> 剩余主要缺口：**审计（A8）** · **真实预言机源（C2）** · **多签 owner（B1，工具就绪）** · **RWA/合规（D）** · **法务（F1）**。
