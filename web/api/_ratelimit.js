// In-memory token bucket for the public API (audit N1).
// Vercel serverless resets state on cold start, so this is a best-effort limiter - it stops a single
// hammerer from burning invocations and upstream price quotas. It is not a hard guarantee; the
// durable version would need Redis, which this deployment does not have.
const buckets = new Map();
const MAX_ENTRIES = 5000;

export function rateLimit(req, res, { limit = 30, windowMs = 60_000, name = "api" } = {}) {
  const fwd = req.headers["x-forwarded-for"];
  const ip = (Array.isArray(fwd) ? fwd[0] : String(fwd || "")).split(",")[0].trim() || req.socket?.remoteAddress || "unknown";
  const key = name + ":" + ip;
  const now = Date.now();

  let b = buckets.get(key);
  if (!b || now - b.start >= windowMs) { b = { start: now, count: 0 }; buckets.set(key, b); }
  b.count++;

  if (buckets.size > MAX_ENTRIES) {
    for (const k of buckets.keys()) { buckets.delete(k); if (buckets.size <= MAX_ENTRIES / 2) break; }
  }

  res.setHeader("X-RateLimit-Limit", String(limit));
  res.setHeader("X-RateLimit-Remaining", String(Math.max(0, limit - b.count)));
  if (b.count > limit) {
    res.setHeader("Retry-After", String(Math.ceil((b.start + windowMs - now) / 1000)));
    res.status(429).json({ error: { code: "rate_limited", message: "too many requests; retry shortly" } });
    return false;
  }
  return true;
}
