// Gas runway alert: the deployer pays for timelock rounds and the index refresh. If it runs dry, the
// market freezes silently (no consumer) and the queue stalls. Alert before that happens.
import { createPublicClient, http, formatEther } from "viem";
import { arbitrum } from "viem/chains";

const ADDR = process.env.ADDR || "0xBf0D7119F553eB5f85C9806f0849f9c86a9B768C";
const MIN_ETH = Number(process.env.MIN_ETH || "0.002");
const RPC = process.env.RPC || "https://arb1.arbitrum.io/rpc";

const pub = createPublicClient({ chain: arbitrum, transport: http(RPC) });
const bal = await pub.getBalance({ address: ADDR });
const eth = Number(formatEther(bal));
console.log(`deployer ${ADDR}: ${eth.toFixed(6)} ETH (threshold ${MIN_ETH})`);

if (eth < MIN_ETH) {
  const token = process.env.TG_BOT_TOKEN;
  const chat = process.env.TG_ALERT_CHAT_ID;
  if (token && chat) {
    try {
      await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          chat_id: chat,
          text: `Planet: deployer gas is low — ${eth.toFixed(5)} ETH (< ${MIN_ETH}). Top up ${ADDR} on Arbitrum One or the timelock queue and index refresh will stall.`,
        }),
      });
      console.log("telegram alert sent");
    } catch (e) {
      console.error("alert failed:", e.message);
    }
  } else {
    console.error("TG secrets missing - cannot alert");
  }
  process.exit(1);
}
