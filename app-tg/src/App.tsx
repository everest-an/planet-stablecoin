import { useEffect, useState } from "react";
import { useTonAddress, useTonConnectUI } from "@tonconnect/ui-react";
import { Address, Cell, beginCell, toNano } from "@ton/core";
import { TonClient } from "@ton/ton";

const ENDPOINT =
  import.meta.env.VITE_TON_ENDPOINT ?? "https://testnet.toncenter.com/api/v2/jsonRPC";
// Optional toncenter API key (sent as X-API-Key) — raises the public testnet rate limit.
const API_KEY = (import.meta.env.VITE_TONCENTER_API_KEY as string | undefined) || undefined;
const PLANET_ADDRESS = import.meta.env.VITE_PLANET_ADDRESS ?? "";
const PLT_MINTER_ADDRESS = import.meta.env.VITE_PLT_MINTER_ADDRESS ?? "";
const BOND_ADDRESS = import.meta.env.VITE_BOND_ADDRESS ?? "";
const MAX_ORACLE_AGE = 21600; // 6h — matches PlanetCore's mint freshness guard
// Since A2, PlanetCore owns the commodity basket; the app reads assets from it directly.

const OP_MINT = 0x10000001; // PlanetCore Mint message opcode
const OP_ASK_TO_BURN = 0x595f07bc; // TEP-74 AskToBurn (sent to the user's jetton wallet)
const USD_DECIMALS = 6;

const client = new TonClient({ endpoint: ENDPOINT, apiKey: API_KEY });

// The public testnet RPC is rate-limited (HTTP 429); retry with exponential backoff +
// jitter (and transient network errors) so the UI still loads instead of erroring out.
async function runMethodRetry(addr: Address, method: string, args?: any[], tries = 6) {
  for (let i = 0; i < tries; i++) {
    try {
      return await client.runMethod(addr, method, args);
    } catch (e) {
      const m = String((e as Error)?.message ?? e);
      if (!/429|Too Many|rate|timeout|timed out|fetch|network/i.test(m)) throw e;
      const wait = Math.min(8000, 600 * 2 ** i) + Math.random() * 400;
      await new Promise((r) => setTimeout(r, wait));
    }
  }
  throw new Error(
    "RPC throttled: " +
      method +
      (API_KEY ? "" : " — set VITE_TONCENTER_API_KEY or a keyed VITE_TON_ENDPOINT")
  );
}

function fmtFixed(raw: bigint, decimals = 6): string {
  return (Number(raw) / 10 ** decimals).toLocaleString(undefined, {
    maximumFractionDigits: 6,
  });
}

// Compact oracle age: 42s / 12m / 3h 20m / 2d 4h.
function fmtAge(seconds: number | null): string {
  if (seconds === null || !Number.isFinite(seconds) || seconds < 0) return "—";
  const s = Math.floor(seconds);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 48) return m % 60 ? `${h}h ${m % 60}m` : `${h}h`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}

function mintBody(usdcAmount: bigint): Cell {
  return beginCell()
    .storeUint(OP_MINT, 32)
    .storeInt(BigInt(Date.now()), 64) // queryId
    .storeInt(usdcAmount, 64) // amount (USDC, 6 decimals)
    .endCell();
}

const EXPLORER = "https://testnet.tonviewer.com";

type Theme = "light" | "dark";

// Precedence: saved choice → Telegram colorScheme → OS preference.
function preferredTheme(): Theme {
  const saved = localStorage.getItem("planet-theme");
  if (saved === "light" || saved === "dark") return saved;
  const tg = (window as unknown as { Telegram?: { WebApp?: { colorScheme?: string } } }).Telegram
    ?.WebApp;
  if (tg?.colorScheme === "dark") return "dark";
  if (tg?.colorScheme === "light") return "light";
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

// Turn a TON Connect / RPC error into a human-readable message.
function classifyTxError(e: unknown): string {
  const m = String((e as Error)?.message ?? e);
  if (/reject|denied|cancel|abort|user/i.test(m)) return "Cancelled: you rejected the transaction in your wallet";
  if (/insufficient|not enough|balance/i.test(m)) return "Insufficient balance (testnet TON / USDC)";
  return m;
}

export default function App() {
  const userAddress = useTonAddress();
  const [tonConnectUI] = useTonConnectUI();
  const [theme, setTheme] = useState<Theme>(preferredTheme);
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
  const [intentNote, setIntentNote] = useState("");
  const [riskFund, setRiskFund] = useState("—");
  const [oracleAge, setOracleAge] = useState<number | null>(null);
  const [bond, setBond] = useState<{
    open: boolean;
    premiumBps: number;
    totalIssued: string;
  } | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem("planet-theme", theme);
  }, [theme]);

  async function refresh(manual = false) {
    if (manual) setRefreshing(true);
    try {
      if (!PLANET_ADDRESS) {
        setError("VITE_PLANET_ADDRESS not set");
        return;
      }
      const addr = Address.parse(PLANET_ADDRESS);
      const [p, r, s, mx, lu, rf] = await Promise.all([
        runMethodRetry(addr, "ppi"),
        runMethodRetry(addr, "reserve"),
        runMethodRetry(addr, "supply"),
        runMethodRetry(addr, "maxPerTx"),
        runMethodRetry(addr, "lastOracleUpdate"),
        runMethodRetry(addr, "riskFund"),
      ]);
      const ppiBig = p.stack.readBigNumber();
      setPpi(fmtFixed(ppiBig, 6));
      setPpiRaw(Number(ppiBig) / 10 ** USD_DECIMALS);
      setReserve(fmtFixed(r.stack.readBigNumber(), 6));
      setSupply(fmtFixed(s.stack.readBigNumber(), 6));
      setMaxMint(Number(mx.stack.readBigNumber()));
      setRiskFund(fmtFixed(rf.stack.readBigNumber(), 6));
      const lastPush = Number(lu.stack.readBigNumber());
      setOracleAge(
        lastPush > 0 ? Math.max(0, Math.floor(Date.now() / 1000) - lastPush) : null
      );

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

      // Bond state is read from the bond contract itself: these getters already exist on
      // the deployed bond, while the newer Core bond getters may not be deployed yet.
      if (BOND_ADDRESS) {
        try {
          const b = Address.parse(BOND_ADDRESS);
          const [bo, bp, ti] = await Promise.all([
            runMethodRetry(b, "isOpen"),
            runMethodRetry(b, "premiumBps"),
            runMethodRetry(b, "totalIssued"),
          ]);
          setBond({
            open: bo.stack.readBoolean(),
            premiumBps: Number(bp.stack.readBigNumber()),
            totalIssued: fmtFixed(ti.stack.readBigNumber(), 6),
          });
        } catch {
          setBond(null);
        }
      } else {
        setBond(null);
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
    } finally {
      if (manual) setRefreshing(false);
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

  // Conversational entry ("talk to the bot, then trade"): the bot opens the app with an
  // intent, e.g. https://app.ppppp.space/?intent=mint_100 — or the Mini App start_param
  // (t.me/<bot>?startapp=mint_100). We only PRE-FILL the form: the user still signs the
  // transaction in their own wallet. The bot never holds keys and never signs for you.
  useEffect(() => {
    const tg = (
      window as unknown as { Telegram?: { WebApp?: { initDataUnsafe?: { start_param?: string } } } }
    ).Telegram?.WebApp;
    const raw = (
      new URLSearchParams(window.location.search).get("intent") ||
      tg?.initDataUnsafe?.start_param ||
      ""
    ).trim();
    const m = /^(mint|burn)[_-]?([0-9]*\.?[0-9]+)?$/i.exec(raw);
    if (!m) return;
    const kind = m[1].toLowerCase();
    const val = m[2] || "";
    if (kind === "mint") {
      if (val) setAmount(val);
      setIntentNote(
        `From Telegram: mint${val ? " " + val : ""} — connect a wallet and sign to confirm.`
      );
      document.getElementById("mint")?.scrollIntoView({ behavior: "smooth", block: "start" });
    } else {
      if (val) setBurnAmount(val);
      setIntentNote(
        `From Telegram: burn${val ? " " + val + " PLT" : ""} — connect a wallet and sign to confirm.`
      );
      document.getElementById("burn")?.scrollIntoView({ behavior: "smooth", block: "start" });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function onMint() {
    if (!PLANET_ADDRESS) return;
    const units = BigInt(Math.floor(Number(amount) * 10 ** USD_DECIMALS));
    if (units <= 0n) {
      setError("Enter an amount");
      return;
    }
    if (maxMint > 0 && Number(units) > maxMint) {
      setError(`Amount exceeds the per-transaction cap (${maxMint / 10 ** USD_DECIMALS} USDC)`);
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
      setMsg(`Submitted: mint ${amount} USDC (waiting for on-chain confirmation…)`);
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
      setError("Amount exceeds your PLT balance");
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
      setMsg(`Submitted: burn ${burnAmount} PLT (waiting for on-chain confirmation…)`);
      setBurnAmount("");
      if (userAddress) setTxUrl(`${EXPLORER}/${userAddress}`);
      setTimeout(() => { void refresh(); }, 5000);
    } catch (e) {
      setError(classifyTxError(e));
    } finally {
      setBusy(false);
    }
  }

  const loading = !updatedAt && !error;
  const stale = oracleAge !== null && oracleAge > MAX_ORACLE_AGE;
  const ppiDev = ppiRaw !== null && ppiRaw > 0 ? (ppiRaw - 1) * 100 : null;

  return (
    <main className="wrap" aria-busy={loading}>
      <header className="head">
        <h1>Planet</h1>
        <div className="head-right">
          <button
            className="link"
            onClick={() => setTheme(theme === "dark" ? "light" : "dark")}
            title="toggle theme"
            aria-label="Toggle light and dark theme"
          >
            [ {theme} ]
          </button>
          {!userAddress ? (
            <button className="btn" onClick={() => tonConnectUI.openModal()}>
              connect wallet
            </button>
          ) : (
            <div className="wallet">
              <span className="addr" title={userAddress}>
                {userAddress.slice(0, 4)}…{userAddress.slice(-4)}
              </span>
              <button className="link" onClick={() => tonConnectUI.disconnect()}>
                disconnect
              </button>
            </div>
          )}
        </div>
      </header>

      <p className="tag">[ commodity purchasing-power index · TON testnet ]</p>
      {intentNote && <p className="muted">▸ {intentNote}</p>}
      {loading && (
        <p className="muted" role="status">
          reading chain…
        </p>
      )}
      {error && (
        <p className="err banner" role="alert">
          {error}
        </p>
      )}
      {stale && (
        <p className="err banner" role="alert">
          Oracle is stale ({fmtAge(oracleAge)} old) — minting is blocked until the relayer
          pushes a fresh price.
        </p>
      )}

      <div className="sec-head">
        <span className="num">[ 01 ]</span>
        <span className="lbl">ledger</span>
        <span className="end">¬</span>
      </div>
      <section className="grid">
        <div className="card">
          <span className="k">PPI</span>
          <span className="v">{ppi}</span>
          {ppiDev !== null && (
            <span className={`peg${Math.abs(ppiDev) > 5 ? " far" : ""}`}>
              vs 1.000000 {ppiDev >= 0 ? "▲" : "▼"} {ppiDev >= 0 ? "+" : ""}
              {ppiDev.toFixed(2)}%
            </span>
          )}
        </div>
        <div className="card">
          <span className="k">Reserve</span>
          <span className="v">{reserve}</span>
        </div>
        <div className="card">
          <span className="k">PLT Supply</span>
          <span className="v">{supply}</span>
        </div>
        <div className="card">
          <span className="k">Oracle age</span>
          <span className={`v${stale ? " signal" : ""}`}>{fmtAge(oracleAge)}</span>
        </div>
        <div className="card">
          <span className="k">Risk fund</span>
          <span className="v">${riskFund}</span>
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

      <div className="meta">
        <span className="muted">Last updated: {updatedAt || "—"}</span>
        <button className="link" onClick={() => void refresh(true)} disabled={refreshing}>
          [ {refreshing ? "refreshing…" : "refresh"} ]
        </button>
      </div>

      {assets.length > 0 && (
        <section className="basket">
          <div className="sec-head">
            <span className="num">[ 02 ]</span>
            <span className="lbl">index composition</span>
            <span className="end">¬</span>
          </div>
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
                    {a.drift >= 0 ? "▲ " : "▼ "}
                    {a.drift >= 0 ? "+" : ""}
                    {a.drift.toFixed(1)}%
                  </td>
                  <td>
                    {a.risk !== 0 ? (
                      <span className="badge frozen" title={`riskState=${a.risk}`}>
                        frozen
                      </span>
                    ) : (
                      <span className="badge">ok</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}

      <section className="stability">
        <div className="sec-head">
          <span className="num">[ 03 ]</span>
          <span className="lbl">stability</span>
          <span className="end">¬</span>
        </div>
        {BOND_ADDRESS ? (
          bond ? (
            <div className="kv">
              <div>
                <span className="k">Sale</span>
                <span className={`badge${bond.open ? " open" : ""}`}>
                  {bond.open ? "open" : "closed"}
                </span>
              </div>
              <div>
                <span className="k">Premium</span>
                <span className="v-sm">{(bond.premiumBps / 100).toFixed(2)}%</span>
              </div>
              <div>
                <span className="k">Face outstanding</span>
                <span className="v-sm">${bond.totalIssued}</span>
              </div>
            </div>
          ) : (
            <p className="muted">Bond state unavailable.</p>
          )
        ) : (
          <p className="muted">Bond not configured (set VITE_BOND_ADDRESS).</p>
        )}
        <p className="note">
          The sale opens automatically below PPI 0.950000 and closes at 0.970000. Settled
          bonds draw from the risk fund.
        </p>
      </section>

      <section className="mint" id="mint">
        <div className="sec-head">
          <span className="num">[ 04 ]</span>
          <span className="lbl">mint</span>
          <span className="end">¬</span>
        </div>
        <label className="k" htmlFor="amt">
          testnet demo mint (no real deposit)
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

      <section className="mint" id="burn">
        <div className="sec-head">
          <span className="num">[ 05 ]</span>
          <span className="lbl">burn</span>
          <span className="end">¬</span>
        </div>
        <label className="k" htmlFor="burn">
          TEP-74 burn via your jetton wallet
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
        {msg && (
          <p className="ok" role="status" aria-live="polite">
            {msg}
          </p>
        )}
        {txUrl && (
          <p className="muted">
            <a href={txUrl} target="_blank" rel="noreferrer">
              View this wallet in the explorer ↗
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

      <footer className="foot">
        <a href="https://ppppp.space" target="_blank" rel="noreferrer">
          ppppp.space
        </a>
      </footer>
    </main>
  );
}
