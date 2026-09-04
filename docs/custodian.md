# 托管方对接规格(储备证明 / 预言机映射审计)

> 本文档定义 Planet 链上合约与链下托管方(券商)的对接接口。
> 目标:让「链上 PLT 供应 ≤ 链下真实 ETF 市值」可被任何人审计,实现"资产可信任"。

---

## 1. 架构总览(两条腿)

```
┌──────────── 链上(Solana Anchor) ────────────┐
│  ReserveState   total_supply(PLT 供应)      │
│  ReserveAttestation                        │
│    ├ custodian(托管方公钥)                 │
│    ├ total_value(已验证 ETF 总市值)        │
│    ├ holdings_hash(明细哈希,交叉核验)      │
│    └ attested_at(证明时间戳)               │
│  指令: init_attestation / submit_attestation│
│        / verify_reserve(任何人可调用)      │
└──────────────────▲─────────────────────────┘
                   │ 托管方签名交易提交
┌──────────── 链下(托管方/券商) ──────────────┐
│  Interactive Brokers 等持有一篮子 ETF        │
│  1. 每日生成持仓明细 holdings.json           │
│  2. 计算 total_value = Σ(份额 × 预言机价)   │
│  3. 明细存 Arweave(永久公开)                │
│  4. 计算 holdings_hash = SHA256(明细)       │
│  5. 用托管方私钥签名 submit_attestation 交易 │
└─────────────────────────────────────────────┘
```

**信任闭环**:用户不信协议口头承诺,而是信「链上 `total_value` ≥ `total_supply`」+「`holdings_hash` 能对上 Arweave 明细」+「预言机价格可复算」。

---

## 2. 储备明细数据格式(holdings.json)

托管方每日(或每次重大变动后)生成如下 JSON,存 Arweave:

```json
{
  "version": "1",
  "timestamp": 1750000000,
  "custodian": "<托管方 Solana 公钥 base58>",
  "broker": "Interactive Brokers",
  "account_id": "U1234567",
  "holdings": [
    {
      "symbol": "WTI",
      "etf": "USO",
      "isin": "US91267V1098",
      "shares": 10000,
      "price_usd": 78.50,
      "value_usd": 785000.00
    },
    {
      "symbol": "XAU",
      "etf": "GLD",
      "isin": "US78463V1070",
      "shares": 5000,
      "price_usd": 2400.00,
      "value_usd": 12000000.00
    }
  ],
  "total_value_usd": 12785000.00
}
```

**字段约定**:
- `shares`:ETF 份额(整数)。
- `price_usd`:该 ETF 的预言机价格(美元,可含小数,取 Pyth/Chainlink 实时价)。
- `value_usd` = `shares × price_usd`。
- `total_value_usd` = `Σ value_usd`。

---

## 3. 哈希与定点数换算

### 3.1 holdings_hash(链上 `[u8; 32]`)

对 holdings.json 做**规范化序列化**后取 SHA-256:

```
holdings_hash = SHA256(canonical_json)
```

canonical_json 要求(避免哈希不一致):
- 键按字母序排列;
- 数字统一为固定格式(如 `78.50` 而非 `78.5`);
- 无多余空白;
- 不含 `total_value_usd` 之外的派生字段重复计算(具体:hash 只覆盖 `holdings` 数组 + `timestamp` + `custodian`,不含 `total_value_usd`,因为总价值可被独立复算)。

> 推荐:托管方发布一个开源的小工具 `holdings2hash.py`,任何人可把 Arweave 明细重算成 holdings_hash 核对。

### 3.2 total_value(链上 `u64`,6 位小数)

```
total_value = round(total_value_usd × 10^6)
```

即 USD 金额按 6 位小数定点表示(与合约 `USD_SCALE = 1_000_000` 一致)。

---

## 4. 签名方案(Ed25519)

当前实现:**交易签名即证明**。托管方用其私钥签署 `submit_attestation` 交易,
合约用 `has_one = custodian` 约束校验「签名者 == attestation.custodian」。

```
submit_attestation(total_value: u64, holdings_hash: [u8; 32])
  accounts: attestation(has_one = custodian), custodian(signer)
```

**托管方私钥管理要求**:
- 私钥存 HSM / 多签钱包(Squads Protocol),绝不存服务器明文;
- 托管方公钥在 `init_attestation(custodian)` 时一次性写入链上,之后不可改(如需更换托管方,走治理迁移流程)。

> 升级路线:若需要「链下签名 + 链上验签」的更强方案(证明不依赖某笔交易),可在后续版本加
> `verify_attestation_signature` 指令,用 `solana_program::ed25519_program` 校验
> Ed25519 签名 `sign(custodian_sk, total_value ‖ holdings_hash ‖ timestamp)`。

---

## 5. 链上校验流程(verify_reserve)

任何人(审计方、用户、第三方)可随时调用 `verify_reserve`:

```
verify_reserve()
  accounts: reserve(只读), attestation(只读)
  逻辑:
    ratio = total_value / total_supply(抵押率,ppm)
    若 total_supply > total_value → 报 ReserveUndercollateralized(欠抵押)
    否则 emit ReserveVerifiedEvent(supply, value, ratio)
```

审计步骤(链下配合):
1. 读链上 `total_supply` 与 `attestation.total_value`;
2. 读 Arweave 明细,复算 `total_value`;
3. 核对 `holdings_hash`;
4. 用 Pyth 价格复算每只 ETF 的 `value_usd`;
5. 确认 `total_supply ≤ total_value`(即 100% 抵押)。

---

## 6. 批量再平衡流程(链下)

真实 ETF 的购买/卖出是 **T+1/T+2 交收**,不做逐笔链上触发,而是**批量再平衡**:

```
每日(或净铸造/赎回累计超过阈值时):
  1. 汇总净铸造量 ΔMint = Σ mint - Σ burn
  2. 若 ΔMint > 0:券商用新增 USDC 买入对应权重的 ETF
  3. 若 ΔMint < 0:券商卖出对应权重的 ETF,换回 USDC 供赎回
  4. 更新 holdings.json + 重新 submit_attestation
```

对应链上:合约里的 `simulate_rebalance` 给出理论调仓量 ΔA_i(供券商参考),
实际下单由券商在链下执行,完成后用新的 `total_value` 重新 submit_attestation。

---

## 7. 安全与信任模型

| 风险 | 控制 |
|---|---|
| 托管方虚报 total_value | `holdings_hash` + Arweave 明细 + 预言机价格复算,任何人不一致即可识破 |
| 无抵押增发 | `verify_reserve` 强制 `total_supply ≤ total_value`;铸币前还受 RiskManager 限额约束 |
| 托管方私钥被盗 | HSM / 多签;换托管方走治理迁移 |
| 预言机价格异常 | 价格由 Pyth 提供,置信区间过大可拒绝(见 docs/pyth-feeds.md) |
| 券商流动性危机 | 储备分散 10+ 交易所;迁移状态机可 FreezeMint 冻结新铸造 |

---

## 8. 托管方对接清单

1. [ ] 在 Solana 生成托管方密钥对,公钥提供给协议方做 `init_attestation`。
2. [ ] 实现 holdings.json 生成 + Arweave 上链。
3. [ ] 实现 holdings_hash 计算(开源工具)。
4. [ ] 实现每日 `submit_attestation` 交易签名提交。
5. [ ] 实现批量再平衡(买卖 ETF)。
6. [ ] 接入第三方审计(如 Halborn / ChainSecurity)定期核验持仓。
7. [ ] 建立告警:欠抵押、大额净铸造/赎回、持仓偏离权重。
