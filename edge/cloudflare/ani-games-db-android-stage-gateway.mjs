const UPSTREAM_KEY = "ani_games_ready_stage:upstream";
const UPSTREAM_TTL_SECONDS = 600;
const ALLOWED_EXACT = new Set([
  "/health",
  "/auth/v1/token",
  "/auth/v1/user",
  "/auth/v1/logout",
  "/iot/status",
  "/iot/power"
]);

function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
      ...headers
    }
  });
}

function corsFor(request) {
  const origin = request.headers.get("Origin");
  if (origin === "null") {
    return {
      "access-control-allow-origin": "null",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "authorization,apikey,content-type,x-client-info,x-ani-bootstrap-token",
      "access-control-max-age": "600",
      "vary": "Origin"
    };
  }
  return {};
}

function isLoopbackOnlyRoute(path) {
  return path === "/setup" || path === "/api/admin/bootstrap" ||
    path.startsWith("/setup/") || path.startsWith("/api/admin/bootstrap/");
}

function isApiRoute(path) {
  if (isLoopbackOnlyRoute(path)) return false;
  if (ALLOWED_EXACT.has(path)) return true;
  if (/^\/rest\/v1\/rpc\/[a-z][a-z0-9_]{1,100}$/i.test(path)) return true;
  if (/^\/device\/[a-z0-9/_-]+$/i.test(path)) return true;
  if (/^\/functions\/v1\/ani-games-api(?:\/[a-z0-9/_-]+)?$/i.test(path)) return true;
  return false;
}

function equalSecret(candidate, expected) {
  if (typeof candidate !== "string" || typeof expected !== "string") return false;
  if (!expected || candidate.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= candidate.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

async function controlRequest(request, env, url) {
  if (request.method !== "POST" && !(request.method === "GET" && url.pathname.endsWith("/status"))) {
    return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  }
  const auth = request.headers.get("Authorization") || "";
  const supplied = auth.match(/^Bearer\s+(.+)$/i)?.[1] || "";
  if (!equalSecret(supplied, env.REGISTER_TOKEN)) return json({ error: "UNAUTHORIZED" }, 401);

  if (url.pathname === "/_ani_gateway/status" && request.method === "GET") {
    const value = await env.UPSTREAMS.get(UPSTREAM_KEY, "json");
    return json({ ok: true, active: Boolean(value?.url), updated_at: value?.updated_at || null });
  }
  if (url.pathname === "/_ani_gateway/clear") {
    await env.UPSTREAMS.delete(UPSTREAM_KEY);
    return json({ ok: true, cleared: true });
  }
  if (url.pathname === "/_ani_gateway/register") {
    let body;
    try { body = await request.json(); } catch { return json({ error: "INVALID_JSON" }, 400); }
    let upstream;
    try { upstream = new URL(String(body?.url || "")); } catch { return json({ error: "INVALID_UPSTREAM_URL" }, 400); }
    if (upstream.protocol !== "https:" ||
        !/^[a-z0-9-]{8,63}\.trycloudflare\.com$/i.test(upstream.hostname) ||
        upstream.username || upstream.password || upstream.pathname !== "/" ||
        upstream.search || upstream.hash) {
      return json({ error: "UPSTREAM_NOT_ALLOWED" }, 400);
    }
    await env.UPSTREAMS.put(UPSTREAM_KEY, JSON.stringify({
      url: upstream.origin,
      updated_at: new Date().toISOString()
    }), { expirationTtl: UPSTREAM_TTL_SECONDS });
    return json({ ok: true, registered: true, expires_in: UPSTREAM_TTL_SECONDS });
  }
  return json({ error: "NOT_FOUND" }, 404);
}

export async function handleRequest(request, env) {
  const url = new URL(request.url);
  // Normalize trailing slashes and make the gateway root a safe health-check alias.
  // This avoids clients landing on the Worker root and receiving ROUTE_NOT_ALLOWED.
  const incomingPath = url.pathname.replace(/\/+$/, "") || "/";
  const routePath = incomingPath === "/" ? "/health" : incomingPath;
  const routedUrl = new URL(url);
  routedUrl.pathname = routePath;
  const headers = corsFor(request);
  const projectPrefix = routePath === "/stardesk" || routePath.startsWith("/stardesk/");
  const effectivePath = projectPrefix ? (routePath.slice("/stardesk".length) || "/") : routePath;
  const healthRoute = effectivePath === "/_ani_gateway/health";
  if (healthRoute) {
    try {
      const relayHealth = await env.RELAY_SERVICE.fetch(new Request(
        projectPrefix ? "https://relay.internal/_relay/stardesk/health" : "https://relay.internal/_relay/health", {
        headers: { "cache-control": "no-store" }
      }));
      const detail = await relayHealth.json();
      const healthy = relayHealth.status === 200 &&
        detail?.relay === "online" &&
        detail?.agent_connected === true &&
        detail?.api === "online" &&
        detail?.database === "online";
      return json({
        gateway: "online",
        transport: "websocket-relay",
        upstream_active: healthy,
        relay: detail?.relay || "unknown",
        agent_connected: detail?.agent_connected === true,
        api: detail?.api || "unknown",
        database: detail?.database || "unknown"
      }, healthy ? 200 : 503);
    } catch {
      return json({
        gateway: "online",
        transport: "websocket-relay",
        upstream_active: false,
        relay: "unreachable",
        agent_connected: false,
        api: "unknown",
        database: "unknown"
      }, 503);
    }
  }
  if (routePath.startsWith("/_ani_gateway/")) {
    return controlRequest(request, env, routedUrl);
  }
  if (projectPrefix && effectivePath.startsWith("/_ani_gateway/")) return json({ error: "LOCAL_ONLY_ROUTE" }, 403, headers);

  if (isLoopbackOnlyRoute(effectivePath)) return json({ error: "LOCAL_ONLY_ROUTE" }, 403, headers);
  if (!isApiRoute(effectivePath)) return json({ error: "ROUTE_NOT_ALLOWED" }, 404, headers);
  if (effectivePath === "/iot/status" && !["GET", "OPTIONS"].includes(request.method)) return json({ error: "METHOD_NOT_ALLOWED" }, 405, headers);
  if (effectivePath === "/iot/power" && !["POST", "OPTIONS"].includes(request.method)) return json({ error: "METHOD_NOT_ALLOWED" }, 405, headers);
  if (!["GET", "POST", "OPTIONS"].includes(request.method)) return json({ error: "METHOD_NOT_ALLOWED" }, 405, headers);

  const origin = request.headers.get("Origin");
  if (origin && origin !== "null") return json({ error: "ORIGIN_NOT_ALLOWED" }, 403);
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: {
      ...headers,
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    }});
  }

  const relayUrl = new URL(routePath + url.search, "https://relay.internal");
  const clientIp = String(request.headers.get("CF-Connecting-IP") || "");
  if (!clientIp || clientIp.length > 64 || !/^[0-9a-fA-F:.]+$/.test(clientIp)) {
    return json({ error: "CLIENT_IP_UNAVAILABLE" }, 400, headers);
  }
  const outgoingHeaders = new Headers();
  for (const name of ["authorization", "apikey", "content-type", "x-client-info"]) {
    const value = request.headers.get(name);
    if (value !== null) outgoingHeaders.set(name, value);
  }
  outgoingHeaders.set("x-ani-edge-client-ip", clientIp);
  outgoingHeaders.set("x-ani-gateway-auth", env.EDGE_PROXY_SECRET);
  if (origin === "null") outgoingHeaders.set("origin", "null");

  let upstreamResponse;
  try {
    const init = {
      method: request.method,
      headers: outgoingHeaders,
      redirect: "manual"
    };
    if (request.method !== "GET" && request.method !== "HEAD") {
      init.body = request.body;
      init.duplex = "half";
    }
    upstreamResponse = await env.RELAY_SERVICE.fetch(new Request(relayUrl.toString(), init));
  } catch {
    return json({ error: "WEBSOCKET_RELAY_UNREACHABLE" }, 502, headers);
  }

  const responseHeaders = new Headers(upstreamResponse.headers);
  responseHeaders.set("cache-control", "no-store");
  responseHeaders.set("x-content-type-options", "nosniff");
  responseHeaders.set("referrer-policy", "no-referrer");
  responseHeaders.delete("set-cookie");
  if (origin === "null") {
    for (const [key, value] of Object.entries(headers)) responseHeaders.set(key, value);
  } else {
    responseHeaders.delete("access-control-allow-origin");
    responseHeaders.delete("access-control-allow-credentials");
  }
  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    statusText: upstreamResponse.statusText,
    headers: responseHeaders
  });
}

export default {
  async fetch(request, env) {
    return handleRequest(request, env);
  }
};
