import { useEffect, useState } from "react";
import { TonConnectButton, useTonAddress } from "@tonconnect/ui-react";
import { TonClient, Address } from "@ton/ton";

const ENDPOINT =
  import.meta.env.VITE_TON_ENDPOINT ?? "https://testnet.toncenter.com/api/v2/jsonRPC";
const PLANET_ADDRESS = import.meta.env.VITE_PLANET_ADDRESS ?? "";

const client = new TonClient({ endpoint: ENDPOINT });

function fmtFixed(raw: bigint, decimals = 6): string {
  return (Number(raw) / 10 ** decimals).toLocaleString(undefined, {
    maximumFractionDigits: 6,
  });
}

export default function App() {
  const userAddress = useTonAddress();
  const [ppi, setPpi] = useState("—");
  const [reserve, setReserve] = useState("—");
  const [supply, setSupply] = useState("—");
  const [error, setError] = useState("");

  useEffect(() => {
    if (!PLANET_ADDRESS) {
      setError("VITE_PLANET_ADDRESS not set");
      return;
    }
    let alive = true;
    (async () => {
      try {
        const addr = Address.parse(PLANET_ADDRESS);
        const [p, r, s] = await Promise.all([
          client.runMethod(addr, "ppi"),
          client.runMethod(addr, "reserve"),
          client.runMethod(addr, "supply"),
        ]);
        if (!alive) return;
        setPpi(fmtFixed(p.stack.readBigNumber(), 6));
        setReserve(fmtFixed(r.stack.readBigNumber(), 6));
        setSupply(fmtFixed(s.stack.readBigNumber(), 6));
        setError("");
      } catch (e) {
        if (alive) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      alive = false;
    };
  }, [userAddress]);

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

      <section className="actions">
        <p>Wallet: {userAddress ? `${userAddress.slice(0, 8)}…` : "not connected"}</p>
        <p className="muted">
          Phase 0 MVP — reads PlanetCore getters on-chain. Mint/burn wired after the
          PLT Jetton ships.
        </p>
      </section>

      {error && <p className="err">{error}</p>}

      <footer className="foot">
        <a
          href="https://github.com/everest-an/planet-stablecoin"
          target="_blank"
          rel="noreferrer"
        >
          github.com/everest-an/planet-stablecoin
        </a>
      </footer>
    </main>
  );
}
