// GET /api/health — one line for uptime monitors and probes. Deliberately no external calls: this
// answers "is the deployment up", not "is every dependency healthy" (that is /api/v1/oracle).
export default function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Cache-Control", "no-store");
  return res.status(200).json({
    ok: true,
    service: "planet",
    rev: "health-1",
    time: new Date().toISOString(),
  });
}
