// Deprecated alias for /api/v1/status. Kept so existing clients keep working; it redirects
// (HTTP 308, method-preserving) and advertises the sunset via standard headers:
//
//   Deprecation: true            (draft-ietf-httpapi-deprecation-header)
//   Sunset: <date>               (RFC 8594)
//   Link: <.../v1/status>; rel="successor-version"

export default function handler(_req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Deprecation", "true");
  res.setHeader("Sunset", "Wed, 31 Dec 2026 23:59:59 GMT");
  res.setHeader("Link", '</api/v1/status>; rel="successor-version"');
  res.setHeader("Location", "/api/v1/status");
  return res.status(308).end();
}
