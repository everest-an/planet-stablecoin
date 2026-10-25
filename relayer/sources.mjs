// CLI wrapper around the shared channel logic. The implementation lives in web/api/_channels.js so the
// relayer and the public /api/v1/sources endpoint can never drift apart — two copies of "how we decide
// a price" is how an oracle ends up publishing something its own API disagrees with.
//
// The CLI body is inside main() on purpose: push-evm.mjs imports this module, and a bare top-level
// loop would print the whole matrix again on every push.

import { ASSETS, readAsset, TOL } from "../web/api/_channels.js";

export { ASSETS, TOL, readAsset };

async function main() {
  const rows = await Promise.all(ASSETS.map(async (a) => ({ a, r: await readAsset(a) })));
  console.log(["#", "asset", "price", "confirm", "ok", "risk", "worst", "channels"].join("\t"));

  let totalChannels = 0;
  let multi = 0;
  for (const { a, r } of rows) {
    if (!r.ok) {
      console.log(`${a.i}\t${a.name}\tREAD FAILED: ${r.reason}`);
      continue;
    }
    totalChannels += r.channelsOk;
    if (r.channelsOk >= 2) multi++;
    const detail = r.observations
      .map((o) => `${o.channel}=${Number.isFinite(o.price) ? o.price.toFixed(4) : "ERR"}`)
      .join(" ");
    console.log(
      [
        a.i,
        a.name,
        r.price.toFixed(4),
        r.confirmations,
        r.channelsOk,
        r.riskState === 0 ? "normal" : "CAUTION",
        (r.spread * 100).toFixed(3) + "%",
        detail,
      ].join("\t"),
    );
    for (const x of r.rejected) {
      console.log(`   rejected ${x.channel}: ${x.price.toFixed(4)} (${(x.dev * 100).toFixed(2)}% off primary, tol ${(TOL * 100).toFixed(1)}%)`);
    }
  }

  console.log(`\n${multi}/${rows.length} assets have 2+ channels answering; ${totalChannels} channel reads total`);
}

if ((process.argv[1] ?? "").replace(/\\/g, "/").endsWith("sources.mjs")) await main();
