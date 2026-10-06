// Oracle monitor — polls the public health endpoint and alerts Telegram when the state CHANGES.
//
// Why a state file: an alert that repeats every run trains people to ignore it. This keeps the
// last observed state in the repo and only messages on a transition (healthy -> degraded and
// back), so one incident produces one alert.
//
// Exit code: 0 when healthy, 1 when degraded — so the workflow run itself is the second signal
// (the badge/notification) even if Telegram is unreachable.
//
// Env: ORACLE_API (default the public endpoint), TG_BOT_TOKEN, TG_ALERT_CHAT_ID (optional).

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const STATE_FILE = join(HERE, "oracle-state.json");

const API = process.env.ORACLE_API || "https://ppppp.space/api/v1/oracle?full=1";
const TOKEN = process.env.TG_BOT_TOKEN || "";
const CHAT = process.env.TG_ALERT_CHAT_ID || "";

function signature(o) {
  return JSON.stringify({
    healthy: o.healthy,
    fresh: o.fresh,
    reasons: (o.reasons || []).slice().sort(),
    warnings: (o.warnings || []).slice().sort(),
  });
}

function humanize(o) {
  const lines = [];
  lines.push(o.healthy && o.fresh ? "Planet oracle: OK" : "Planet oracle: DEGRADED");
  lines.push(`fresh=${o.fresh} age=${o.ageSeconds}s (limit ${o.maxAgeSeconds}s) healthy=${o.healthy}`);
  if (o.reasons?.length) lines.push("reasons: " + o.reasons.join(", "));
  if (o.warnings?.length) lines.push("warnings: " + o.warnings.join(", "));
  if (o.signers) lines.push(`signers: ${o.signers.count} / threshold ${o.signers.threshold}`);
  if (o.basket) {
    lines.push(
      `basket: weights ${o.basket.weightsSum}/${o.basket.expectedSum} valid=${o.basket.weightsValid}` +
        (o.basket.frozen?.length ? ` frozen=[${o.basket.frozen.join(",")}]` : "")
    );
  }
  lines.push(o.core);
  lines.push("https://ppppp.space/dashboard");
  return lines.join("\n");
}

async function alert(text) {
  if (!TOKEN || !CHAT) {
    console.log("(no TG_BOT_TOKEN / TG_ALERT_CHAT_ID set — printing instead)");
    console.log(text);
    return;
  }
  const res = await fetch(`https://api.telegram.org/bot${TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: CHAT, text, disable_web_page_preview: true }),
  });
  const j = await res.json().catch(() => ({}));
  console.log(`telegram sendMessage ok=${j.ok} ${j.description ?? ""}`);
}

async function main() {
  const res = await fetch(API, { headers: { "user-agent": "planet-monitor" } });
  const body = await res.json().catch(() => null);

  if (!res.ok || !body || body.error) {
    // A 503 from the endpoint already means "could not read the chain" — that is itself an alert,
    // but it is transient by design, so we report it as degraded-by-read-failure without spamming.
    const sig = "unreadable:" + (body?.error?.code ?? res.status);
    const prev = existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf8")) : null;
    if (!prev || prev.signature !== sig) {
      await alert(`Planet oracle: could not read the chain (${body?.error?.code ?? "HTTP " + res.status})`);
      writeFileSync(STATE_FILE, JSON.stringify({ signature: sig, at: new Date().toISOString() }, null, 2) + "\n");
    } else {
      console.log("still unreadable; already alerted");
    }
    console.log("monitor: UNREADABLE");
    process.exit(1);
  }

  const sig = signature(body);
  const prev = existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf8")) : null;
  const degraded = !(body.healthy && body.fresh);

  if (!prev) {
    console.log("first run — recording state, not alerting");
    writeFileSync(STATE_FILE, JSON.stringify({ signature: sig, at: new Date().toISOString() }, null, 2) + "\n");
  } else if (prev.signature !== sig) {
    await alert(humanize(body));
    writeFileSync(STATE_FILE, JSON.stringify({ signature: sig, at: new Date().toISOString() }, null, 2) + "\n");
    console.log("state changed — alerted");
  } else {
    console.log("state unchanged — no alert");
  }

  console.log(humanize(body));
  process.exit(degraded ? 1 : 0);
}

main().catch((e) => {
  console.error("monitor failed:", e?.message ?? e);
  process.exit(1);
});
