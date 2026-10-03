import React from "react";
import ReactDOM from "react-dom/client";
import { TonConnectUIProvider } from "@tonconnect/ui-react";
import App from "./App";
import "./styles.css";

// TON Connect requires a manifest URL. Replace with your hosted manifest before release.
const MANIFEST_URL =
  import.meta.env.VITE_TONCONNECT_MANIFEST ??
  "https://ton-connect.github.io/demo-dapp-with-react-ui/tonconnect-manifest.json";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <TonConnectUIProvider manifestUrl={MANIFEST_URL}>
      <App />
    </TonConnectUIProvider>
  </React.StrictMode>
);
