// GET /api/v1/price-signed — the pull-oracle feed.
//
// Returns the latest signed price payloads (one per asset) plus the signature for each. A consumer
// submits them on-chain in ITS OWN transaction via PlanetCore.updatePriceSigned(payload, sig) and
// pays that gas; the publisher pays nothing. Cache is short because a payload's timestamp must be
// newer than the on-chain lastOracleUpdate to be usable.
const RAW = "https://raw.githubusercontent.com/everest-an/planet-stablecoin/oracle-data/price-signed.json";

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "GET" && req.method !== "HEAD") {
    return res.status(405).json({ error: { code: "method_not_allowed", message: "GET only." } });
  }
  try {
    const r = await fetch(RAW, { headers: { accept: "application/json", "cache-control": "no-cache" } });
    if (!r.ok) throw new Error("upstream " + r.status);
    const body = await r.text();
    res.setHeader("Cache-Control", "public, s-maxage=30, stale-while-revalidate=60");
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    return res.status(200).send(body);
  } catch (e) {
    return res.status(503).json({
      error: { code: "feed_unavailable", message: "signed feed unavailable: " + e.message },
    });
  }
}
