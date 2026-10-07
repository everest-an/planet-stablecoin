> # ⚠️ 更正声明（必读）
>
> **本文是 v1.0 早期白皮书（Solana 时代）的原文抽取，其中两处说法与事实不符，且已作废：**
>
> 1. 文末技术附录写有「**此方案已通过形式化验证工具 Certora 证明算法收敛性**」—— **从未进行任何形式化验证** ✗。
> 2. 同处写有「**审计报告见 `Planet_Audit_Report_v1.0.pdf`**」「聘请 **Halborn** 进行渗透测试」—— **从未进行任何第三方审计** ✗。
>
> 此外，文中「1:1 大宗商品储备 / 足额抵押 / 稳定币」等表述**均未实现** ✓：
> 当前线上（TON 测试网）是**无背书合成指数代币**，**不是稳定币**、**无储备**、**未审计**。
>
> **仓库内部请勿再引用上述任何一句** ✗（对客户/审计/监管重复这些说法会构成虚假陈述 ✗）。
> 对外一律以 `docs/WHITEPAPER.md` + 网页白皮书 + `docs/audit-prep.md` 为准 ✓。
>
> **本文件已设 `export-ignore`** ✓ —— **永不进入公开仓** ✓。

---

 	1
Planet 稳定币白皮书
全球大宗商品锚定算法稳定币
版本 	1.0
部署网络：Solana
作者：Everest 	An
1. 	概述
Planet（PLT） 	是一种创新的算法稳定币，将地球的主流真实资产隐射到
区块链当中。通过锚定全球大宗商品购买力实现通用价值弹性算法稳定币。
PLT 	以 	1:1 	比例储备大宗商品期货及 	ETF 	组合，结合动态再平衡机制和弹性供
应算法，确保其价值与全球实物资产购买力同步波动。所有操作在 	Solana 	链上
执行，实现低手续费、高吞吐量交易。
2. 	核心机制
2.1 	价值锚定
• 	基础资产池：覆盖能源（原油、天然气）、金属（金、银、铜）、农产
品（小麦、玉米）等 	20+ 	种大宗商品。
1. 	全球代表性：覆盖能源、金属、农产品、工业原料四大类
2. 	高流动性：选择日均交易量 	> 	$5 	亿 	的期货/ETF
3. 	价格透明性：依赖 	CME、LME、ICE 	等主流交易所实时数据
4. 	分散风险：单品类权重 	≤ 	15%，地域分布覆盖五大洲

-- 1 of 18 --

2
2.2 	初始资产组合
类别 	具体商品 	期货代码 	ETF 	代码 	权重 	价格来源
能源 西德克萨斯原油
（WTI）
CL
(NYMEX) USO 	12% 	CME 	Group
布伦特原油 	BZ 	(ICE) 	BNO 	10% 	ICE
天然气 NG
(NYMEX) UNG 	8% 	CME 	Group
金属 	黄金 GC
(COMEX) GLD 	10% 	LBMA
白银 	SI 	(COMEX) 	SLV 	7% 	LBMA
铜 HG
(COMEX) CPER 	6% 	LME
农产品 	小麦 	ZW 	(CBOT) 	WEAT 	9% 	CBOT
玉米 	ZC 	(CBOT) 	CORN 	7% 	CBOT
大豆 	ZS 	(CBOT) 	SOYB 	6% 	CBOT
咖啡 	KC 	(ICE) 	JO 	4% 	ICE
工业原料 	橡胶 TSR20
(SGX) - 	5% 	SGX
木材 	LBS 	(CME) 	WOOD 	4% 	CME 	Group
锂 	LITH 	(LME) 	LIT 	3% 	LME
其他 	水权* NQH2O
(CME) PHO 	5% 	Nasdaq
碳信用 	GEO 	(CME) 	KRBN 	4% 	CME 	Group
*注：水权为新兴大宗商品，反映可持续资源价值
总权重：∑=100%，每季度由 	DAO 	投票调整

-- 2 of 18 --

3
2.3 	储备管理机制
• 	RTRA 	实时再平衡算法 	Real-time 	rebalancing 	algorithm：
\Delta 	A_i 	= 	\left( 	w_i 	- 	\frac{V_i}{\sum 	V} 	\right) 	\times 	T 	\quad 	\text{其
中:}
– 	𝐀𝐀𝐀：资产 	i 	的调整量（美元）
– 	𝐀𝐀：目标权重
– 	𝐀𝐀：当前持仓价值
– 	𝐀：总储备金规模
• 	操作流程：
1. 	预言机每 	5 	分钟更新价格（Pyth 	Network）
2. 	智能合约计算偏离度：𝐀 	= 	𝐀𝐀 	− 	𝐀𝐀/𝐀
3. 	当 	𝐀 	> 	0.5% 	时自动触发再平衡
4. 	通过 	Solana 	DEX 	聚合器（Jupiter）执行交易
• 	购买力指数（PPI）：

-- 3 of 18 --

4
PPI𝐀 	=
𝐀=1
𝐀
𝐀𝐀 	⋅ 𝐀𝐀,𝐀
𝐀𝐀,base

– 	𝐀𝐀：商品 	𝐀 	的权重（按全球贸易量分配，∑𝐀𝐀 	= 	1）
– 	𝐀𝐀,𝐀：商品 	𝐀 	在时间 	𝐀 	的实时价格
– 	𝐀𝐀,base：商品 	𝐀 	在基准日（发行日）的价格
• 	PLT 	目标价格：
PricePLT 	= 	PPI𝐀 	× 	USDbase
（USDbase 	= 	1，初始锚定 	1 	USD）
2.2 	储备管理
• 	1:1 	资产储备：
每枚 	PLT 	由等值的大宗商品期货/ETF 	支持，资产组合按 	PPI 	权重分配。
• 	多重托管：
– 	70% 	资产 	→ 	受监管经纪商（Interactive 	Brokers 	等）
– 	30% 	资产 	→ 	去中心化保险协议（Nexus 	Mutual）
• 	实时再平衡：
预言机每 	10 	分钟更新价格，触发再平衡：
𝐀𝐀𝐀 	= 	𝐀𝐀 	− Value 	𝐀𝐀
Total 	Reserve 	Value × 	Reserve
– 	𝐀𝐀𝐀：商品 	𝐀 	的仓位调整量
– 	再平衡通过 	Solana 	链上智能合约自动执行交易（如买入原油期货、
卖出黄金 	ETF）。

-- 4 of 18 --

5
2.3 	交易手续费
• 	0.5% 	全局手续费：
应用于铸造、赎回、转账。
• 	手续费分配：
– 	70% 	→ 	用于回购并销毁 	PLT（通缩压力）
– 	30% 	→ 	注入储备池（增强抵押率）
3. 	代币供应算法
3.1 	铸造（增发）
当 	PPI𝐀 	> 	1.03（需求旺盛）：
1. 	用户存入 	USD/USDC 	换取 	PLT。
2. 	合约自动用资金买入大宗商品期货/ETF。
3. 	新 	PLT 	数量：
Minted 	PLT= Deposited 	USD
PricePLT
3.2 	赎回（收缩）
当 	PPI𝐀 	< 	0.97（需求不足）：
1. 	用户销毁 	PLT 	换取 	USD/USDC。
2. 	合约卖出对应比例的期货/ETF。
3. 	用户所得：
Received 	USD=Burned 	PLT×PricePLT 	× 	1 	− 	0.005

-- 5 of 18 --

6
3.3 	稳定性调节
• 	目标区间：PPI 	在 	0.97–1.03 	时，系统维持现状。
• 	极端波动应对：
– 	若 	PPI 	> 	1.05：提高铸造手续费至 	1%（抑制过热）
– 	若 	PPI 	< 	0.95：开启「稳定债券」机制（用户可折价买入 	PLT，未
来赎回获利）
4. 	系统架构（Solana 	实现）
4.1 	智能合约模块
graph 	LR
A[用户] 	-->|请求| 	B(PLT 	Core 	Contract)
B 	--> 	C[Price 	Oracle]
C 	-->|PPI 	数据| 	D[Pyth 	Network]
D 	-->|实时价格| 	B
B 	-->|再平衡指令| 	E[DeFi 	协议]
E 	-->|交易| 	F[商品期货/ETF]
F 	-->|储备证明| 	B
4.2 	关键组件
• 	预言机：集成 	Pyth 	Network（Solana 	原生，支持 	100+ 	大宗商品实时数
据）。
• 	DeFi 	接口：连接 	Raydium（DEX）与 	Synthetix（合成资产），执行期货
/ETF 	交易。

-- 6 of 18 --

7
• 	储备审计：链上实时公示储备地址，第三方可验证 	1:1 	抵押。
5. 	治理与经济模型
• 	治理代币：PLT-G（持有者投票调整参数）。
• 	可调参数：
– 	商品权重 	𝐀𝐀（年更新）
– 	手续费率（0.3%~0.8% 	浮动）
– 	PPI 	阈值区间
• 	抗风险设计：
– 	储备资产分散在 	10+ 	交易所（避免流动性危机）
– 	最低抵押率 	105%（超额缓冲）
• 	透明审计：
– 	链上储备证明（SPL 	代币账户公开可查）
– 	每日发布 	Merkle 	树储备报告
–
6. 	优势与创新
• 	全球适用性：PPI 	覆盖多品类商品，规避单一经济体通胀风险。
• 	良性波动：PLT 	价值随实物资产上涨而增值，非机械锚定法币。
• 	Solana 	优势：

-- 7 of 18 --

8
– 	交易确认 	<0.5 	秒，手续费 	≈$0.00025
– 	支持高频再平衡和复杂算法。
7. 	路线图
阶段 	目标
Q3 	2025 	测试网上线（PPI 	算法验证）
Q4 	2025 	Solana 	主网部署，初始商品池：10 	种
Q1 	2026 	支持法币出入金通道（USD/EUR/JPY）
Q2 	2026 	DAO 	治理启动，去中心化参数控制
8. 	代币经济学
8.1 	代币体系
代币类型 	符号 	功能 	供应机制
稳定币 	PLT 	支付/储值/交易媒介 	算法弹性供应
治理代币 	PLTG 	系统参数投票/收益分配 	固定 	10 	亿枚
8.2 	PLT 	稳定币发行机制
• 	铸造方程：
M_{new} 	= 	\frac{D 	\times 	(1 	- 	f)}{\text{PPI}_t} 	\quad 	\text{其中:}
– 	𝐀𝐀𦰀𝐀：新铸造 	PLT 	数量
– 	𝐀：用户存入的 	USDC 	数量
– 	𝐀：0.5%手续费

-- 8 of 18 --

9
– 	PPI𝐀：实时购买力指数
• 	销毁方程：
R 	= 	B 	\times 	\text{PPI}_t 	\times 	(1 	- 	f)
– 	𝐀：用户赎回的 	USDC 	数量
– 	𝐀：销毁的 	PLT 	数量
8.3 	PLTG 	治理代币分配
用途 	比例 	解锁规则
社区激励 	40% 	5 	年线性释放（流动性挖矿）
协议金库 	25% 	DAO 	控制（生态建设）
核心团队 	15% 	2 	年锁定期+3 	年线性释放
投资者 	12% 	1 	年锁定期+2 	年线性释放
公开销售 	8% 	TGE 	完全释放
8.4 	价值捕获模型
• 	手续费流向（0.5%全局费率）：
pie
title 	手续费分配
“PLT 	回购销毁” 	： 	45%
“储备金增强” 	： 	30%
“PLTG 	质押奖励” 	： 	25%
• 	PLTG 	赋能机制：
– 	质押分红：分享 	25%的手续费收益（按周发放 	USDC）
– 	治理权力：

-- 9 of 18 --

10
• 	投票调整商品权重 	𝐀𝐀
• 	决定储备金托管方变更
• 	修改 	PPI 	波动阈值（±3%默认值）
– 	流动性激励：
PLT/USDC 	LP 	提供者可获 	PLTG 	奖励（APR 	15-25%）
8.5 	稳定性保障机制
• 	双轨价格锚定：
| 	场景 	| 	市场价 	< 	PPI_t 	| 	市场价 	> 	PPI_t 	|
|———————|—————-|—————-|
| 	系统响应 	| 	开启折扣铸造 	| 	开启溢价赎回 	|
| 	用户激励 	| 	1 	PLT 	= 	0.98 	PPI 	| 	1 	PLT 	= 	1.02 	PPI 	|
• 	极端波动应对基金：
– 	储备金的 	1%作为风险缓冲
– 	当 	PPI 	单日波动 	>7%时启用
– 	通过期权对冲（Hedera 	链上衍生品）
9. 	经济模型模拟
假设场景：原油价格单日上涨 	10%
1. 	PPI 	上升 	→ 	PLT 	目标价从$1.00 	升至$1.03
2. 	套利者涌入铸造：
- 	存入 	100 	万 	USDC 	→ 	获得 	970,873 	PLT（扣除手续费）
3. 	系统自动买入$994,500 	原油 	ETF

-- 10 of 18 --

11
4. 	结果：
- 	储备金增加$994,500
- 	PLT 	供应量扩大 	0.97%
- 	价格回归 	PPI 	锚定区间
结论
Planet（PLT）通过算法连接实体经济与区块链，提供抗通胀、全球通用的稳定
价值载体。其动态再平衡和弹性供应机制，为加密货币市场注入真实商品购买
力支撑。PLT 	通过严格的资产配置和代币经济设计，实现三重稳定性：
1. 	价值支撑：20+大宗商品 	1:1 	储备
2. 	算法调节：动态供应响应 	PPI 	波动
3. 	经济激励：PLTG 	治理代币引导生态正循环
> 	“这不是另一个算法稳定币实验——而是将全球真实经济价值锚定在区块链上
的革命性尝试。”
附录
- 	初始商品权重表
- 	智能合约审计报告（待发布）
- 	储备资产白名单（CME 	期货、iShares 	ETF 	等）
- 	大宗商品期货/ETF 	流动性评分表
-
附录：技术方案

-- 11 of 18 --

12
以下是 	Planet 	稳定币在 	Solana 	上的技术实现方案，包含核心算法、预言机
集成、API 	设计及安全审计规范。本方案基于 	Solana 	的链上程序（On-chain
Program）架构，采用 	Rust 	语言开发，结合 	Pyth 	预言机实现大宗商品价格实时
锚定。
一、系统架构
graph 	TD
A[用户] 	-->|请求| 	B(Planet 	核心程序)
B 	--> 	C[Pyth 	预言机]
C 	-->|大宗商品价格| 	D[Pythnet]
D 	-->|Wormhole 	VAA| 	E[Solana 	主网]
B 	-->|再平衡指令| 	F[Raydium 	DEX]
F 	-->|交易| 	G[商品 	ETF/期货]
B 	-->|审计接口| 	H[第三方审计合约]
二、核心模块实现
1. 	价格预言机集成（Pyth 	Network）
• 	数据源配置
通过 	Pyth 	的 	Solana 	Price 	Feed 	账户获取 	20+大宗商品实时价格，每
400ms 	更新一次：
use 	pyth_sdk_solana::load_price_feed_from_account;
fn 	get_commodity_price(price_account: 	&AccountInfo) 	-> 	Res
ult<f64, 	ProgramError> 	{
let 	price_feed 	= 	load_price_feed_from_account(price_ac
count)?;

-- 12 of 18 --

13
let 	current_price 	= 	price_feed.get_current_price().ok_
or(ProgramError::InvalidAccountData)?;
Ok(current_price.price 	as 	f64)
}
• 	PPI 	计算
基于白皮书公式实现购买力指数：
fn 	calculate_ppi(weights: 	&[f64], 	prices: 	&[f64], 	base_pri
ces: 	&[f64]) 	-> 	f64 	{
weights.iter()
.zip(prices.iter().zip(base_prices.iter()))
.map(|(w, 	(p, 	base))| 	w 	* 	(p 	/ 	base))
.sum()
}
 	PLTG 	释放智能合约代码片段
// 	Solana
智能合约（部分）
impl 	PlanetGov 	{
fn 	distribute_rewards(&mut 	self) 	{
let 	fees 	= 	self.treasury.get_fees();
let 	burn_amount 	= 	fees 	* 	0.45; 	// 	45%
回购销毁
let 	reserve_boost 	= 	fees 	* 	0.30; 	// 	30%
储备增强
let 	staking_rewards 	= 	fees 	* 	0.25; 	// 	25%
质押奖励
self.burn_plt(burn_amount);
self.boost_reserves(reserve_boost);
self.distribute_to_stakers(staking_rewards);
}
}

-- 13 of 18 --

14
2. 	动态再平衡算法
• 	仓位调整逻辑
每 	10 	分钟触发一次再平衡（通过 	Solana 	Clockwork 	定时任务）：
fn 	rebalance_reserves(
current_weights: 	&[f64],
current_values: 	&[f64],
total_reserve: 	f64
) 	-> 	Vec<f64> 	{
current_weights.iter()
.zip(current_values.iter())
.map(|(w, 	v)| 	(w 	- 	(v 	/ 	total_reserve)) 	* 	total_re
serve)
.collect()
}
• 	DEX 	交易执行
通过 	Raydium 	聚合器自动交易 	ETF：
fn 	execute_trade(
asset_id: 	Pubkey,
amount: 	f64,
is_buy: 	bool
) 	-> 	Result<(), 	ProgramError> 	{
let 	raydium_ix 	= 	raydium::swap_instruction(
asset_id,
amount,
is_buy,
)?;
invoke(&raydium_ix, 	&accounts)?;
Ok(())
}

-- 14 of 18 --

15
3. 	代币供应弹性算法
• 	铸造/销毁逻辑
当 	PPI 	偏离阈值时调节供应量：
// 	PPI 	> 	1.03
时增发
fn 	mint_plt(usdc_deposited: 	f64, 	current_ppi: 	f64) 	-> 	u64
{
let 	fee 	= 	usdc_deposited 	* 	0.005;
let 	net_usdc 	= 	usdc_deposited 	- 	fee;
(net_usdc 	/ 	current_ppi) 	as 	u64 	//
返回新铸造 	PLT
数量
}
// 	PPI 	< 	0.97
时销毁
fn 	burn_plt(plt_burned: 	u64, 	current_ppi: 	f64) 	-> 	f64 	{
plt_burned 	as 	f64 	* 	current_ppi 	* 	0.995 	//
返回应支付 	U
SDC
}
三、API 	接口设计
端点 	方法 	参数 	功能
/mint 	POST 	usdc_amount: 	u64 	存入 	USDC 	铸造 	PLT
/burn 	POST 	plt_amount: 	u64 	销毁 	PLT 	赎回 	USDC
/get_ppi 	GET 	- 	返回当前 	PPI 	值
/reserves 	GET 	- 	返回储备资产分布
示例调用：

-- 15 of 18 --

16
curl 	-X 	POST 	https://api.planet.finance/mint 	\
-H 	"Content-Type: 	application/json" 	\
-d 	'{"usdc_amount": 	1000}'
四、安全审计规范
1. 	智能合约审计重点
• 	防溢出攻击：所有数学运算使用 	checked_add/sub/mul/div
let 	new_supply 	= 	total_supply.checked_add(minted_amount).o
k_or(OverflowError)?;
• 	预言机数据验证：检查 	Pyth 	置信区间（防止异常价格）
if 	price_feed.confidence_interval 	> 	(price 	* 	0.05) 	{
return 	Err(OracleError::HighVariance);
}
• 	重入攻击防护：所有外部调用使用 	Solana 	的 	CPI 	限制（Cross-Program
Invocation）
2. 	第三方审计流程
5. 	静态分析：
使用 	cargo-audit 	扫描依赖漏洞，Mythril 	检测逻辑缺陷。
6. 	动态测试：
模拟极端市场场景（如大宗商品价格单日±20%波动）。
7. 	审计机构：
聘请 	Halborn 	进行渗透测试，重点检查：
– 	储备金操作权限隔离
– 	预言机更新延迟攻击
– 	治理代币投票劫持

-- 16 of 18 --

17
五、链下服务设计
1. 	储备证明系统
• 	每日 	Merkle 	树发布
在 	Arweave 	存储储备金快照，结构如下：
{
"total_reserve": 	"1.2e9", 	// 	1.2 	亿美元
"assets": 	[
{"symbol": 	"WTI", 	"value": 	"3.6e8", 	"proof": 	"0x892a...
"},
{"symbol": 	"GOLD", 	"value": 	"2.8e8", 	"proof": 	"0x4fb
1..."}
],
"auditor_signature": 	"Solana.Validators.7xQhp..."
}
2. 	跨链兼容层
通过 	Wormhole 	实现多链 	PLT 	流通：
sequenceDiagram
Ethereum->>Wormhole: 	锁定 	PLT
Wormhole->>Solana: 	生成 	vPLT（跨链 	PLT）
Solana->>Pythnet: 	请求价格证明
Pythnet-->>Solana: 	返回 	VAA(价格+置信区间)
六、部署与监控
组件 	工具 	监控指标
链上程序 	Solana 	CLI 	交易失败率、Gas 	消耗峰值
预言机 	Pyth 	Hermes 	API 	价格更新延迟、置信区间偏离

-- 17 of 18 --

18
组件 	工具 	监控指标
前端 	Grafana+Prometheus 	用户铸造/赎回频率、PPI 	波动率
关键安全原则：所有核心操作需通过多签钱包（如 	Squads 	Protocol）执
行，私钥分片存储于 	HSM 	设备。
此方案已通过形式化验证工具 	Certora 	证明算法收敛性，审计报告见
Planet_Audit_Report_v1.0.pdf。实际部署需在 	Solana 	测试网完成 	500 	万次压力测
试（模拟 	10 	万 	TPS 	大宗商品波动场景）。
免责声明：本白皮书为技术提案，不构成投资建议。大宗商品价格波动
可能导致 	PLT 	短期偏离锚定。

-- 18 of 18 --

