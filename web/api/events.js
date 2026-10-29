// POST /api/events — funnel tracking. Each call becomes one structured line in the function log,
// greppable as '{"ev":'. Accepts {type, detail} only; type is whitelisted to [a-z_], detail is
// truncated. The client sends a hashed address (8 chars), never the address itself.
export default function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "POST") {
    return res.status(405).json({ error: { code: "method_not_allowed", message: "POST only." } });
  }

  let body = {};
  try {
    body = typeof req.body === "string" ? JSON.parse(req.body) : req.body || {};
  } catch {
    body = {};
  }

  const type = typeof body.type === "string" && /^[a-z_]{2,32}$/.test(body.type) ? body.type : "unknown";
  const detail = typeof body.detail === "string" ? body.detail.slice(0, 80) : "";

  console.log(JSON.stringify({ ev: type, d: detail, t: new Date().toISOString() }));
  return res.status(202).json({ ok: true });
}
