// Smoke test: spawn the MCP server, run initialize -> tools/list -> tools/call over stdio.
import { spawn } from "node:child_process";

const child = spawn(process.execPath, ["index.mjs"], { stdio: ["pipe", "pipe", "inherit"] });
let buf = "";
const pending = new Map();
let id = 0;

child.stdout.on("data", (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg.id != null && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  }
});

function rpc(method, params, isNotification = false) {
  const payload = { jsonrpc: "2.0", method, params };
  if (!isNotification) payload.id = ++id;
  child.stdin.write(JSON.stringify(payload) + "\n");
  if (isNotification) return Promise.resolve(null);
  return new Promise((res, rej) => {
    pending.set(payload.id, res);
    setTimeout(() => rej(new Error("timeout on " + method)), 20000);
  });
}

const init = await rpc("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "smoke", version: "1.0" } });
console.log("initialize:", init.result?.serverInfo?.name, init.result?.protocolVersion);
await rpc("notifications/initialized", {}, true);

const list = await rpc("tools/list", {});
console.log("tools:", list.result?.tools?.map((t) => t.name).join(", "));

for (const name of ["get_risk_level", "get_index", "get_perp_market"]) {
  const r = await rpc("tools/call", { name, arguments: {} });
  const text = r.result?.content?.[0]?.text ?? JSON.stringify(r.error);
  console.log(`\n--- ${name} ---\n` + text.slice(0, 600));
}
child.kill();
console.log("\nSMOKE OK");
process.exit(0);
