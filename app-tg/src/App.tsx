import { useEffect, useState } from "react";
import { TonConnectButton, useTonAddress, useTonConnectUI } from "@tonconnect/ui-react";
import { Address, Cell, beginCell, toNano } from "@ton/core";
import { TonClient } from "@ton/ton";

const ENDPOINT =
  import.meta.env.VITE_TON_ENDPOINT ?? "https://testnet.toncenter.com/api/v2/jsonRPC";
const PLANET_ADDRESS = import.meta.env.VITE_PLANET_ADDRESS ?? "";
const PLT_MINTER_ADDRESS = import.meta.env.VITE_PLT_MINTER_ADDRESS ?? "";
const BASKET_ADDRESS = import.meta.env.VITE_BASKET_ADDRESS ?? "";

const OP_MINT = 0x10000001; // PlanetCore Mint message opcode
const OP_ASK_TO_BURN = 0x595f07bc; // TEP-74 AskToBurn (sent to the user's jetton wallet)
const USD_DECIMALS = 6;

const client = new TonClient({ endpoint: ENDPOINT });

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

export default function App() {
  const userAddress = useTonAddress();
  const [tonConnectUI] = useTonConnectUI();
  const [ppi, setPpi] = useState("—");
  const [reserve, setReserve] = useState("—");
  const [supply, setSupply] = useState("—");
  const [assets, setAssets] = useState<
    { i: number; weight: string; base: string; cur: string; value: string }[]
  >([]);
  const [amount, setAmount] = useState("");
  const [burnAmount, setBurnAmount] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState("");
  const [error, setError] = useState("");

  async function refresh() {
    if (!PLANET_ADDRESS) {
      setError("VITE_PLANET_ADDRESS not set");
      return;
    }
    try {
      const addr = Address.parse(PLANET_ADDRESS);
      const [p, r, s] = await Promise.all([
        client.runMethod(addr, "ppi"),
        client.runMethod(addr, "reserve"),
        client.runMethod(addr, "supply"),
      ]);
      setPpi(fmtFixed(p.stack.readBigNumber(), 6));
      setReserve(fmtFixed(r.stack.readBigNumber(), 6));
      setSupply(fmtFixed(s.stack.readBigNumber(), 6));

      // On-chain basket composition (PlanetBasket registry)
      if (BASKET_ADDRESS) {
        const basket = Address.parse(BASKET_ADDRESS);
        const cnt = await client.runMethod(basket, "assetCount");
        const n = Number(cnt.stack.readBigNumber());
        const rows: { i: number; weight: string; base: string; cur: string; value: string }[] = [];
        for (let i = 0; i < n; i++) {
          try {
            const a = await client.runMethod(basket, "assetAt", [
              { type: "int", value: BigInt(i) },
            ]);
            const weight = a.stack.readBigNumber();
            const base = a.stack.readBigNumber();
            const cur = a.stack.readBigNumber();
            const value = a.stack.readBigNumber();
            rows.push({
              i,
              weight: ((Number(weight) / 1e6) * 100).toFixed(1) + "%",
              base: "$" + (Number(base) / 1e6).toFixed(2),
              cur: "$" + (Number(cur) / 1e6).toFixed(2),
              value: "$" + (Number(value) / 1e6).toLocaleString(),
            });
          } catch {
            // asset index not set
          }
        }
        setAssets(rows);
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

  async function onMint() {
    if (!PLANET_ADDRESS) return;
    const units = BigInt(Math.floor(Number(amount) * 10 ** USD_DECIMALS));
    if (units <= 0n) {
      setError("Enter an amount");
      return;
    }
    setBusy(true);
    setError("");
    setMsg("");
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
      setMsg(`Sent mint of ${amount} USDC`);
      setAmount("");
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
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
    setBusy(true);
    setError("");
    setMsg("");
    try {
      const minter = Address.parse(PLT_MINTER_ADDRESS);
      const res = await client.runMethod(minter, "get_wallet_address", [
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
      setMsg(`Sent burn of ${burnAmount} PLT`);
      setBurnAmount("");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
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
      </section>

      {assets.length > 0 && (
        <section className="basket">
          <label className="k">Underlying basket (on-chain)</label>
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>Weight</th>
                <th>Base</th>
                <th>Now</th>
                <th>Value</th>
              </tr>
            </thead>
            <tbody>
              {assets.map((a) => (
                <tr key={a.i}>
                  <td>{a.i}</td>
                  <td>{a.weight}</td>
                  <td>{a.base}</td>
                  <td>{a.cur}</td>
                  <td>{a.value}</td>
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
      </section>

      <p className="muted">
        Phase 1 MVP — mint sends PlanetCore&apos;s <code>Mint</code> op (0x10000001).
        Burn UI follows once redemption is wired.
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
