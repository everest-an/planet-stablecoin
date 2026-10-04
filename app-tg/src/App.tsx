import { useEffect, useState } from "react";
import { TonConnectButton, useTonAddress, useTonConnectUI } from "@tonconnect/ui-react";
import { Address, Cell, beginCell, toNano } from "@ton/core";
import { TonClient } from "@ton/ton";

const ENDPOINT =
  import.meta.env.VITE_TON_ENDPOINT ?? "https://testnet.toncenter.com/api/v2/jsonRPC";
const PLANET_ADDRESS = import.meta.env.VITE_PLANET_ADDRESS ?? "";
const PLT_MINTER_ADDRESS = import.meta.env.VITE_PLT_MINTER_ADDRESS ?? "";
// Since A2, PlanetCore owns the commodity basket; the app reads assets from it directly.

const OP_MINT = 0x10000001; // PlanetCore Mint message opcode
const OP_ASK_TO_BURN = 0x595f07bc; // TEP-74 AskToBurn (sent to the user's jetton wallet)
const USD_DECIMALS = 6;

const client = new TonClient({ endpoint: ENDPOINT });

// The public testnet RPC is rate-limited (HTTP 429); retry with backoff so the UI
// still loads its state instead of erroring out.
async function runMethodRetry(addr: Address, method: string, args?: any[], tries = 6) {
  for (let i = 0; i < tries; i++) {
    try {
      return await client.runMethod(addr, method, args);
    } catch (e) {
      const m = String((e as Error)?.message ?? e);
      if (!/429|Too Many|rate/i.test(m)) throw e;
      await new Promise((r) => setTimeout(r, 1500 * (i + 1)));
    }
  }
  throw new Error("RPC throttled: " + method);
}

function fmtFixed(raw: bigint, decimals = 6): string {
  return (Number(raw) / 10 ** decimals).toLocaleString(undefined, {
    maximumFractionDigits: 6,
  });
}

function mintBody(usdcAmount: bigint): Cell {
  return beginCell()
    .storeUint(OP_MINT, 32)
    .storeInt(BigInt(Date.now()), 64) // queryId
    .storeInt(usdcAmount, 64) // amount (USDC, 6 decimals)
    .endCell();
}

const EXPLORER = "https://testnet.tonviewer.com";

// Turn a TON Connect / RPC error into a human-readable message.
function classifyTxError(e: unknown): string {
  const m = String((e as Error)?.message ?? e);
  if (/reject|denied|cancel|abort|user/i.test(m)) return "已取消：你在钱包里拒绝了交易";
  if (/insufficient|not enough|balance/i.test(m)) return "余额不足（测试网 TON / USDC）";
  return m;
}

export default function App() {
  const userAddress = useTonAddress();
  const [tonConnectUI] = useTonConnectUI();
  const [ppi, setPpi] = useState("—");
  const [reserve, setReserve] = useState("—");
  const [supply, setSupply] = useState("—");
  const [ppiRaw, setPpiRaw] = useState<number | null>(null);
  const [implied, setImplied] = useState<number | null>(null);
  const [assets, setAssets] = useState<
    {
      i: number;
      weight: string;
      weightPct: number;
      base: string;
      cur: string;
      drift: number;
      risk: number;
      vol: number;
      liq: number;
    }[]
  >([]);
  const [amount, setAmount] = useState("");
  const [burnAmount, setBurnAmount] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState("");
  const [error, setError] = useState("");
  const [txUrl, setTxUrl] = useState("");
  const [pltBalance, setPltBalance] = useState("—");
  const [tonBalance, setTonBalance] = useState("—");
  const [updatedAt, setUpdatedAt] = useState("");
  const [maxMint, setMaxMint] = useState(0);
  const [pltRaw, setPltRaw] = useState<bigint | null>(null);

  async function refresh() {
    if (!PLANET_ADDRESS) {
      setError("VITE_PLANET_ADDRESS not set");
      return;
    }
    try {
      const addr = Address.parse(PLANET_ADDRESS);
      const [p, r, s, mx] = await Promise.all([
        runMethodRetry(addr, "ppi"),
        runMethodRetry(addr, "reserve"),
        runMethodRetry(addr, "supply"),
        runMethodRetry(addr, "maxPerTx"),
      ]);
      const ppiBig = p.stack.readBigNumber();
      setPpi(fmtFixed(ppiBig, 6));
      setPpiRaw(Number(ppiBig) / 10 ** USD_DECIMALS);
      setReserve(fmtFixed(r.stack.readBigNumber(), 6));
      setSupply(fmtFixed(s.stack.readBigNumber(), 6));
      setMaxMint(Number(mx.stack.readBigNumber()));

      // User balances: PLT via the jetton wallet, TON via the node.
      if (userAddress) {
        const user = Address.parse(userAddress);
        try {
          const bal = await client.getBalance(user);
          setTonBalance((Number(bal) / 1e9).toFixed(3));
        } catch {
          /* ignore */
        }
        if (PLT_MINTER_ADDRESS) {
          try {
            const minter = Address.parse(PLT_MINTER_ADDRESS);
            const wr = await runMethodRetry(minter, "get_wallet_address", [
              { type: "slice", cell: beginCell().storeAddress(user).endCell() },
            ]);
            const walletAddr = wr.stack.readAddress();
            const wd = await runMethodRetry(walletAddr, "get_wallet_data");
            const pl = wd.stack.readBigNumber();
            setPltBalance(fmtFixed(pl, USD_DECIMALS));
            setPltRaw(pl);
          } catch {
            /* jetton wallet not deployed yet */
          }
        }
      }
      setUpdatedAt(new Date().toLocaleTimeString());

      // On-chain basket composition (owned by PlanetCore since A2)
      {
        const basket = addr;
        const cnt = await runMethodRetry(basket, "assetCount");
        const n = Number(cnt.stack.readBigNumber());
        const rows: {
          i: number;
          weight: string;
          weightPct: number;
          base: string;
          cur: string;
          drift: number;
          risk: number;
          vol: number;
          liq: number;
        }[] = [];
        let impliedSum = 0;
        let hasAsset = false;
        for (let i = 0; i < n; i++) {
          try {
            const a = await runMethodRetry(basket, "assetAt", [
              { type: "int", value: BigInt(i) },
            ]);
            const weight = a.stack.readBigNumber();
            const base = a.stack.readBigNumber();
            const cur = a.stack.readBigNumber();
            const volatility = a.stack.readBigNumber();
            const liquidity = a.stack.readBigNumber();
            const riskState = a.stack.readBigNumber();
            const w = Number(weight) / 1e6;
            const b = Number(base) / 1e6;
            const c = Number(cur) / 1e6;
            const drift = b > 0 ? (c / b - 1) * 100 : 0;
            if (b > 0) {
              impliedSum += w * (c / b);
              hasAsset = true;
            }
            rows.push({
              i,
              weight: (w * 100).toFixed(1) + "%",
              weightPct: Math.min(100, Math.max(0, w * 100)),
              base: "$" + b.toFixed(2),
              cur: "$" + c.toFixed(2),
              drift,
              risk: Number(riskState),
              vol: Number(volatility) / 1e6,
              liq: Number(liquidity) / 1e6,
            });
          } catch {
            // asset index not set
          }
        }
        setAssets(rows);
        setImplied(hasAsset ? impliedSum : null);
      }
      setError("");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  useEffect(() => {
    refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userAddress]);

  // auto-refresh periodically (the index moves as the relayer pushes prices)
  useEffect(() => {
    const id = setInterval(() => {
      void refresh();
    }, 60000);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userAddress]);

  async function onMint() {
    if (!PLANET_ADDRESS) return;
    const units = BigInt(Math.floor(Number(amount) * 10 ** USD_DECIMALS));
    if (units <= 0n) {
      setError("Enter an amount");
      return;
    }
    if (maxMint > 0 && Number(units) > maxMint) {
      setError(`超过单笔限额（${maxMint / 10 ** USD_DECIMALS} USDC）`);
      return;
    }
    setBusy(true);
    setError("");
    setMsg("");
    setTxUrl("");
    try {
      const boc = mintBody(units).toBoc().toString("base64");
      await tonConnectUI.sendTransaction({
        validUntil: Math.floor(Date.now() / 1000) + 300,
        messages: [
          {
            address: PLANET_ADDRESS,
            amount: toNano("0.05").toString(),
            payload: boc,
          },
        ],
      });
      setMsg(`已提交：mint ${amount} USDC（等待链上确认…）`);
      setAmount("");
      if (userAddress) setTxUrl(`${EXPLORER}/${userAddress}`);
      setTimeout(() => { void refresh(); }, 5000);
    } catch (e) {
      setError(classifyTxError(e));
    } finally {
      setBusy(false);
    }
  }

  async function onBurn() {
    if (!PLT_MINTER_ADDRESS || !userAddress) return;
    const units = BigInt(Math.floor(Number(burnAmount) * 10 ** USD_DECIMALS));
    if (units <= 0n) {
      setError("Enter an amount");
      return;
    }
    if (pltRaw !== null && units > pltRaw) {
      setError("超过你的 PLT 余额");
      return;
    }
    setBusy(true);
    setError("");
    setMsg("");
    setTxUrl("");
    try {
      const minter = Address.parse(PLT_MINTER_ADDRESS);
      const res = await runMethodRetry(minter, "get_wallet_address", [
        { type: "slice", cell: beginCell().storeAddress(Address.parse(userAddress)).endCell() },
      ]);
      const walletAddr = res.stack.readAddress();
      const body = beginCell()
        .storeUint(OP_ASK_TO_BURN, 32)
        .storeUint(BigInt(Date.now()), 64) // queryId (uint64)
        .storeCoins(units) // jettonAmount
        .storeAddress(null) // sendExcessesTo: address? = null
        .storeMaybeRef(null) // customPayload: cell? = null
        .endCell();
      await tonConnectUI.sendTransaction({
        validUntil: Math.floor(Date.now() / 1000) + 300,
        messages: [
          {
            address: walletAddr.toString(),
            amount: toNano("0.05").toString(),
            payload: body.toBoc().toString("base64"),
          },
        ],
      });
      setMsg(`已提交：burn ${burnAmount} PLT（等待链上确认…）`);
      setBurnAmount("");
      if (userAddress) setTxUrl(`${EXPLORER}/${userAddress}`);
      setTimeout(() => { void refresh(); }, 5000);
    } catch (e) {
      setError(classifyTxError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="wrap">
      <header className="head">
        <h1>Planet</h1>
        <TonConnectButton />
      </header>

      <p className="tag">Commodity purchasing-power index · TON · TON Connect</p>

      <section className="grid">
        <div className="card">
          <span className="k">PPI</span>
          <span className="v">{ppi}</span>
        </div>
        <div className="card">
          <span className="k">Reserve</span>
          <span className="v">{reserve}</span>
        </div>
        <div className="card">
          <span className="k">PLT Supply</span>
          <span className="v">{supply}</span>
        </div>
        {userAddress && (
          <div className="card">
            <span className="k">Your PLT</span>
            <span className="v">{pltBalance}</span>
          </div>
        )}
        {userAddress && (
          <div className="card">
            <span className="k">Your TON</span>
            <span className="v">{tonBalance}</span>
          </div>
        )}
      </section>

      {updatedAt && <p className="muted">Last updated: {updatedAt}</p>}

      {assets.length > 0 && (
        <section className="basket">
          <label className="k">Index composition (on-chain basket)</label>
          {implied !== null && (
            <p className="implied">
              basket-implied PPI <b>{implied.toFixed(4)}</b>
              {ppiRaw !== null && ppiRaw > 0 && (
                <>
                  {" "}· on-chain <b>{ppi}</b> · Δ{" "}
                  <b>{(((implied - ppiRaw) / ppiRaw) * 100).toFixed(2)}%</b>
                </>
              )}
            </p>
          )}
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>Weight</th>
                <th>Base</th>
                <th>Now</th>
                <th>vs base</th>
                <th>Risk</th>
              </tr>
            </thead>
            <tbody>
              {assets.map((a) => (
                <tr key={a.i}>
                  <td>{a.i}</td>
                  <td className="wcell">
                    <span className="wbar">
                      <span className="wfill" style={{ width: `${a.weightPct}%` }} />
                    </span>
                    {a.weight}
                  </td>
                  <td>{a.base}</td>
                  <td>{a.cur}</td>
                  <td className={a.drift >= 0 ? "drift up" : "drift down"}>
                    {a.drift >= 0 ? "+" : ""}
                    {a.drift.toFixed(1)}%
                  </td>
                  <td>
                    {a.risk !== 0 ? (
                      <span className="drift down" title={`riskState=${a.risk}`}>
                        frozen
                      </span>
                    ) : (
                      "ok"
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}

      <section className="mint">
        <label className="k" htmlFor="amt">
          Mint PLT (deposit USDC)
        </label>
        <div className="row">
          <input
            id="amt"
            inputMode="decimal"
            placeholder="0.00"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            disabled={busy || !userAddress}
          />
          <button onClick={onMint} disabled={busy || !userAddress || !amount}>
            {busy ? "…" : "Mint"}
          </button>
        </div>
        {!userAddress && <p className="muted">Connect a wallet to mint.</p>}
      </section>

      <section className="mint">
        <label className="k" htmlFor="burn">
          Burn PLT (TEP-74 burn via your jetton wallet)
        </label>
        <div className="row">
          <input
            id="burn"
            inputMode="decimal"
            placeholder="0.00"
            value={burnAmount}
            onChange={(e) => setBurnAmount(e.target.value)}
            disabled={busy || !userAddress}
          />
          <button onClick={onBurn} disabled={busy || !userAddress || !burnAmount}>
            {busy ? "…" : "Burn"}
          </button>
        </div>
        {!PLT_MINTER_ADDRESS && (
          <p className="muted">Set VITE_PLT_MINTER_ADDRESS to enable burn.</p>
        )}
        {msg && <p className="ok">{msg}</p>}
        {txUrl && (
          <p className="muted">
            <a href={txUrl} target="_blank" rel="noreferrer">
              在区块浏览器查看该钱包 ↗
            </a>
          </p>
        )}
      </section>

      <p className="muted">
        Phase 1 MVP — mint sends PlanetCore&apos;s <code>Mint</code> op (0x10000001);
        burn uses TEP-74 <code>AskToBurn</code> (0x595f07bc) and the minter mirrors it
        back to PlanetCore. PPI is read from PlanetCore; the basket-implied value is
        computed from the on-chain basket for comparison.
      </p>

      {error && <p className="err">{error}</p>}

      <footer className="foot">
        <a href="https://github.com/everest-an/planet-stablecoin" target="_blank" rel="noreferrer">
          github.com/everest-an/planet-stablecoin
        </a>
      </footer>
    </main>
  );
}
