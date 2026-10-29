// DRAGON NET mirror: the ranked server (Server/ranked) through Cloudflare.
//
// Some players' antivirus web protection, router security or ISP filters block the server's own
// address (a free-hosting domain). Cloudflare addresses are almost never blocked, so the
// launcher falls back to this mirror ([ranked] mirror) when it can't reach the server.
//
// Every request to  https://<worker>/sparking/...  is passed on to  ORIGIN/sparking/...  and the
// answer comes back unchanged (links to the origin in pages and redirects point here instead).
//
// Settings (Cloudflare dashboard > Workers & Pages > this worker > Settings > Variables):
//   ORIGIN     https://tecshideout.ct.ws         (plain variable, no trailing slash)
//   PROXY_KEY  a long random password           (Secret; the same as 'proxy_key' in config.php)
// With PROXY_KEY the server sees each player's own address (login limits are per address);
// without it, every mirror player shares Cloudflare's few addresses.

export default {
  async fetch(request, env) {
    const origin = (env.ORIGIN || "").replace(/\/+$/, "");
    if (!origin)
      return new Response("ORIGIN isn't set", { status: 500 });
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/sparking/") && url.pathname !== "/sparking")
      return Response.redirect(url.origin + "/sparking/", 302);

    const target = origin + url.pathname + url.search;
    const headers = new Headers(request.headers);
    for (const h of [...headers.keys()]) {
      if (h.startsWith("cf-") || h === "host" || h === "x-forwarded-for" || h === "x-real-ip"
          || h.startsWith("x-sparking-client") || h === "x-sparking-proxy-key"
          || h === "x-sparking-host")
        headers.delete(h);
    }
    if (env.PROXY_KEY) {
      headers.set("X-Sparking-Proxy-Key", env.PROXY_KEY);
      headers.set("X-Sparking-Client-IP", request.headers.get("CF-Connecting-IP") || "");
      headers.set("X-Sparking-Host", url.host);   // links / pictures the server hands out
    }
    headers.set("X-Forwarded-Proto", "https");

    const init = { method: request.method, headers, redirect: "manual" };
    if (request.method !== "GET" && request.method !== "HEAD")
      init.body = await request.arrayBuffer();
    let res;
    try {
      res = await fetch(target, init);
    } catch (e) {
      return new Response(JSON.stringify({ ok: false, error: "mirror_unreachable" }),
                          { status: 502, headers: { "Content-Type": "application/json" } });
    }

    const out = new Headers(res.headers);
    const loc = out.get("Location");
    if (loc && loc.startsWith(origin))
      out.set("Location", url.origin + loc.substring(origin.length));
    const type = out.get("Content-Type") || "";
    if (type.includes("text/html")) {
      // Pages: links to the origin point at the mirror.
      const text = (await res.text()).split(origin + "/sparking").join(url.origin + "/sparking");
      out.delete("Content-Length");
      return new Response(text, { status: res.status, headers: out });
    }
    return new Response(res.body, { status: res.status, headers: out });
  },
};
