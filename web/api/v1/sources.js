// GET /api/v1/sources — what the oracle is actually reading right now, channel by channel.
//
// This exists because "we aggregate multiple channels" is a claim until someone can look. Every
// channel that answered is listed with its raw reading, the confirmation count, the worst deviation
// from the primary, and the decision (normal / caution). Rejected channels are named with how far off
// they were, so a reader can see that a disagreement was detected rather than averaged away.
//
// It fetches upstream on each miss, so the edge cache is short. A failure to reach the channels is a
// 503 with the standard envelope — never a 200 with an empty list, which would read as "no problem".

import { ASSETS, TOL, readAsset } from "../_channels.js";
import { CHAIN, CORE, newRequestId, sendJson, sendUpstreamError } from "../_evm.js";

const BUDGET_MS = 12000;

export default async function handler(req, res) {
  const requestId = newRequestId();
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
  res.setHeader("X-Request-Id", requestId);
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.setHeader("Allow", "GET, HEAD, OPTIONS");
    return res.status(405).json({
      error: { code: "method_not_allowed", message: "Only GET/HEAD/OPTIONS are supported.", request_id: requestId },
    });
  }

  let results;
  try {
    results = await Promise.all(
      ASSETS.map(async (a) => {
        const r = await readAsset(a);
        return {
          index: a.i,
          name: a.name,
          symbol: a.sym,
          ok: r.ok,
          price: r.ok ? r.price : null,
          confirmations: r.ok ? r.confirmations : 0,
          channelsAnswered: r.ok ? r.channelsOk : 0,
          riskState: r.ok ? r.riskState : null,
          worstDeviationPct: r.ok ? Number((r.spread * 100).toFixed(4)) : null,
          channels: (r.observations ?? []).map((o) => ({
            channel: o.channel,
            code: o.code,
            price: Number.isFinite(o.price) ? o.price : null,
            error: o.error ?? null,
            verdict: !Number.isFinite(o.price)
              ? "unavailable"
              : o.channel === a.primary
                ? "primary"
                : r.rejected?.some((x) => x.channel === o.channel)
                  ? "rejected"
                  : "confirmed",
          })),
          reason: r.ok ? undefined : r.reason,
        };
      }),
    );
  } catch {
    return sendUpstreamError(res, requestId, "upstream_error", "Could not reach the price channels right now.");
  }

  const answered = results.reduce((n, r) => n + r.channelsAnswered, 0);
  if (answered === 0) {
    return sendUpstreamError(
      res,
      requestId,
      "channels_unavailable",
      "No price channel answered. This is not an empty basket — it is an outage.",
    );
  }

  return sendJson(
    req,
    res,
    requestId,
    {
      rev: "src-1",
      chain: CHAIN,
      core: CORE,
      tolerancePct: TOL * 100,
      rule:
        "The primary channel sets the price; another channel confirms it only if it lands within tolerance. " +
        "A reading with no confirmation is published as caution, never averaged with the dissenter.",
      assets: results,
      summary: {
        assets: results.length,
        withTwoOrMoreChannels: results.filter((r) => r.channelsAnswered >= 2).length,
        confirmed: results.filter((r) => r.confirmations >= 1).length,
        caution: results.filter((r) => r.ok && r.riskState === 1).length,
        channelReads: answered,
      },
    },
    { maxAge: 120, volatile: [] },
  );
}
