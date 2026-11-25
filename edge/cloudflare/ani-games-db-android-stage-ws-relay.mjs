const AGENT_PROTOCOL = "ani-db-relay-v1";
const AGENT_TOKEN_PREFIX = "ani-token-";
const HUB_NAME = "redmi-db-android-stage";
const MAX_BODY_BYTES = 2 * 1024 * 1024;
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
const MAX_IN_FLIGHT = 64;
const REQUEST_TIMEOUT_MS = 30000;
const HEALTH_TIMEOUT_MS = 8000;
// Temporary transition window: accept v1.0 static tokens until the Redmi agent is updated.
// Disable legacy auth after the new agent reports a successful HMAC-authenticated connection.
const ALLOW_LEGACY_AGENT_TOKEN = true;
const ALLOWED_HEADERS = ["authorization", "apikey", "content-type", "x-client-info"];
const ALLOWED_EXACT_PATHS = new Set(["/health", "/auth/v1/token", "/auth/v1/user", "/auth/v1/logout", "/iot/status", "/iot/power"]);

function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), { status, headers: {
    "content-type": "application/json; charset=utf-8", "cache-control": "no-store",
    "x-content-type-options": "nosniff", "referrer-policy": "no-referrer", ...headers
  }});
}
function corsHeaders(request) {
  if (request.headers.get("Origin") !== "null") return {};
  return {
    "access-control-allow-origin": "null",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "authorization,apikey,content-type,x-client-info",
    "access-control-max-age": "600", "vary": "Origin"
  };
}
function isBootstrapRoute(path) {
  return path === "/setup" || path.startsWith("/setup/") ||
    path === "/api/admin/bootstrap" || path.startsWith("/api/admin/bootstrap/");
}
function isAllowedApiRoute(path) {
  if (isBootstrapRoute(path)) return false;
  if (ALLOWED_EXACT_PATHS.has(path)) return true;
  if (/^\/rest\/v1\/rpc\/[a-z][a-z0-9_]{1,100}$/i.test(path)) return true;
  if (/^\/device\/[a-z0-9/_-]+$/i.test(path)) return true;
  return path === "/functions/v1/ani-games-api" ||
    /^\/functions\/v1\/ani-games-api\/[a-z0-9/_-]+$/i.test(path);
}
function equalSecret(candidate, expected) {
  if (typeof candidate !== "string" || typeof expected !== "string" || !expected || candidate.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= candidate.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}
function clientAddress(request, env) {
  const validIp = value => typeof value === "string" && value.length <= 64 && /^[0-9a-fA-F:.]+$/.test(value);
  const directIp = String(request.headers.get("CF-Connecting-IP") || "");
  if (validIp(directIp)) return directIp;
  const forwardedIp = String(request.headers.get("x-ani-edge-client-ip") || "");
  const gatewayAuth = String(request.headers.get("x-ani-gateway-auth") || "");
  if (validIp(forwardedIp) && equalSecret(gatewayAuth, env.RELAY_SHARED_SECRET)) return forwardedIp;
  return "";
}
function bytesToBase64(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  return btoa(binary);
}
function base64ToBytes(value) {
  if (typeof value !== "string" || value.length > Math.ceil(MAX_RESPONSE_BYTES * 4 / 3) + 8) throw new Error("INVALID_RESPONSE_BODY");
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  if (bytes.length > MAX_RESPONSE_BYTES) throw new Error("RESPONSE_TOO_LARGE");
  return bytes;
}
function parseAgentProtocols(request) {
  const entries = String(request.headers.get("Sec-WebSocket-Protocol") || "").split(",").map(x => x.trim()).filter(Boolean);
  const tokens = entries.filter(x => x.startsWith(AGENT_TOKEN_PREFIX));
  return { base: entries.includes(AGENT_PROTOCOL), token: tokens.length === 1 ? tokens[0].slice(AGENT_TOKEN_PREFIX.length) : "" };
}
function hexToBytes(hex) {
  if (typeof hex !== "string" || !/^[0-9a-f]{64}$/i.test(hex)) return null;
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++) out[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}
export async function verifyAgentToken(token, secret, now = Date.now()) {
  if (typeof token !== "string" || typeof secret !== "string" || !secret) return false;
  const parts = token.split(".");
  if (parts.length === 2) {
    const timestamp = Number(parts[0]);
    const signature = hexToBytes(parts[1]);
    if (!Number.isSafeInteger(timestamp) || !signature || Math.abs(now - timestamp) > 120000) return false;
    try {
      const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
        { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
      return await crypto.subtle.verify("HMAC", key, signature,
        new TextEncoder().encode(`${AGENT_PROTOCOL}:${timestamp}`));
    } catch { return false; }
  }
  return ALLOW_LEGACY_AGENT_TOKEN && equalSecret(token, secret);
}
function filteredRequestHeaders(request) {
  const out = {};
  for (const name of ALLOWED_HEADERS) {
    const value = request.headers.get(name);
    if (value !== null) out[name] = value;
  }
  return out;
}
async function proxyApiRequest(request, env, url) {
  const origin = request.headers.get("Origin");
  if (origin && origin !== "null") return json({ error: "ORIGIN_NOT_ALLOWED" }, 403);
  if (!isAllowedApiRoute(url.pathname)) {
    return json({ error: isBootstrapRoute(url.pathname) ? "LOCAL_ONLY_ROUTE" : "ROUTE_NOT_ALLOWED" },
      isBootstrapRoute(url.pathname) ? 403 : 404, corsHeaders(request));
  }
  if (url.pathname === "/iot/status" && !["GET", "OPTIONS"].includes(request.method)) return json({ error: "METHOD_NOT_ALLOWED" }, 405, corsHeaders(request));
  if (url.pathname === "/iot/power" && !["POST", "OPTIONS"].includes(request.method)) return json({ error: "METHOD_NOT_ALLOWED" }, 405, corsHeaders(request));
  if (!["GET", "POST", "OPTIONS"].includes(request.method)) return json({ error: "METHOD_NOT_ALLOWED" }, 405, corsHeaders(request));
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(request) });
  const ip = clientAddress(request, env);
  if (!ip) return json({ error: "CLIENT_IP_UNAVAILABLE" }, 400, corsHeaders(request));
  let bodyBytes = new Uint8Array();
  if (request.method !== "GET") {
    bodyBytes = new Uint8Array(await request.arrayBuffer());
    if (bodyBytes.byteLength > MAX_BODY_BYTES) return json({ error: "REQUEST_TOO_LARGE" }, 413, corsHeaders(request));
  }
  const envelope = { id: crypto.randomUUID(), method: request.method, path: url.pathname + url.search,
    clientIp: ip, headers: filteredRequestHeaders(request), bodyBase64: bytesToBase64(bodyBytes) };
  let upstream;
  try {
    const hub = env.RELAY_HUB.getByName(HUB_NAME);
    upstream = await hub.fetch(new Request("https://relay.internal/proxy", {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(envelope)
    }));
  } catch { return json({ error: "RELAY_UNAVAILABLE" }, 503, corsHeaders(request)); }
  const headers = new Headers(upstream.headers);
  headers.set("cache-control", "no-store");
  headers.set("x-content-type-options", "nosniff");
  headers.set("referrer-policy", "no-referrer");
  for (const [name, value] of Object.entries(corsHeaders(request))) headers.set(name, value);
  return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers });
}
async function relayHealth(env) {
  const hub = env.RELAY_HUB.getByName(HUB_NAME);
  let status;
  try { status = await (await hub.fetch("https://relay.internal/status")).json(); }
  catch { return json({ relay: "offline", agent_connected: false, api: "unknown", database: "unknown", reason: "DURABLE_OBJECT_STATUS_UNREACHABLE" }, 503); }
  if (!status.connected) return json({ relay: "online", agent_connected: false, api: "unknown", database: "unknown", reason: "AGENT_SOCKET_ABSENT" }, 503);

  const envelope = { id: crypto.randomUUID(), method: "GET", path: "/health", clientIp: "127.0.0.1", headers: {}, bodyBase64: "" };
  let response;
  try {
    response = await hub.fetch(new Request("https://relay.internal/proxy", {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(envelope)
    }));
  } catch {
    return json({ relay: "online", agent_connected: false, api: "unreachable", database: "unknown", reason: "AGENT_PROBE_TRANSPORT_FAILED" }, 503);
  }
  let data = null;
  try { data = await response.json(); } catch {}
  if (!response.ok) {
    const reason = typeof data?.error === "string" ? data.error : `AGENT_PROBE_HTTP_${response.status}`;
    const disconnected = ["AGENT_OFFLINE", "AGENT_TIMEOUT", "AGENT_UNAVAILABLE"].includes(reason);
    return json({ relay: "online", agent_connected: !disconnected, api: "unreachable", database: "unknown", reason }, 503);
  }
  const api = data?.api === "online" ? "online" : (typeof data?.api === "string" ? data.api : "unknown");
  const database = data?.database === "online" ? "online" : (typeof data?.database === "string" ? data.database : "unknown");
  const healthy = api === "online" && database === "online";
  return json({ relay: "online", agent_connected: true, api, database,
    agent_connected_since: status.connected_since || null,
    reason: healthy ? null : (data ? "LOCAL_API_HEALTH_NOT_READY" : "LOCAL_API_HEALTH_INVALID_RESPONSE") }, healthy ? 200 : 503);
}

export class RelayHub {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.pending = new Map();
    if (typeof WebSocketRequestResponsePair === "function") {
      this.ctx.setWebSocketAutoResponse?.(new WebSocketRequestResponsePair("AGENT_PING", "AGENT_PONG"));
    }
  }
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/agent/connect") {
      if (request.method !== "GET" || request.headers.get("Upgrade") !== "websocket") return new Response("WebSocket upgrade required", { status: 426 });
      for (const socket of this.ctx.getWebSockets("agent")) {
        try { socket.close(1012, "Agent replaced by newer connection"); } catch {}
      }
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      server.serializeAttachment({ role: "agent", connectedAt: new Date().toISOString() });
      this.ctx.acceptWebSocket(server, ["agent"]);
      return new Response(null, { status: 101, webSocket: client, headers: { "Sec-WebSocket-Protocol": AGENT_PROTOCOL } });
    }
    if (url.pathname === "/status") {
      const sockets = this.ctx.getWebSockets("agent");
      const attachment = sockets[0]?.deserializeAttachment?.() || null;
      return json({ connected: sockets.some(s => s.readyState === 1), socket_count: sockets.length,
        connected_since: attachment?.connectedAt || null, pending_requests: this.pending.size });
    }
    if (url.pathname === "/proxy" && request.method === "POST") return this.proxyRequest(request);
    return json({ error: "NOT_FOUND" }, 404);
  }
  async proxyRequest(request) {
    let envelope;
    try { envelope = await request.json(); } catch { return json({ error: "INVALID_RELAY_ENVELOPE" }, 400); }
    if (!envelope || typeof envelope !== "object" ||
      !/^[0-9a-f-]{36}$/i.test(String(envelope.id || "")) ||
      !["GET", "POST"].includes(envelope.method) || typeof envelope.path !== "string" ||
      !envelope.path.startsWith("/") || !isAllowedApiRoute(new URL(envelope.path, "https://local.invalid").pathname)) {
      return json({ error: "INVALID_RELAY_ENVELOPE" }, 400);
    }
    if (this.pending.size >= MAX_IN_FLIGHT) return json({ error: "RELAY_BUSY" }, 503);
    const socket = this.ctx.getWebSockets("agent").find(s => s.readyState === 1);
    if (!socket) return json({ error: "AGENT_OFFLINE" }, 503);
    const id = envelope.id;
    const timeoutMs = envelope.path.split("?", 1)[0] === "/health" ? HEALTH_TIMEOUT_MS : REQUEST_TIMEOUT_MS;
    let timer;
    const reply = new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error("AGENT_RESPONSE_TIMEOUT")), timeoutMs);
      this.pending.set(id, { resolve, reject, socket, timer });
    });
    try {
      socket.send(JSON.stringify({ type: "request", ...envelope }));
      const result = await reply;
      const body = base64ToBytes(result.bodyBase64 || "");
      const headers = new Headers({ "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" });
      for (const name of ["content-type", "retry-after"]) {
        const value = result.headers?.[name];
        if (typeof value === "string" && value.length <= 256) headers.set(name, value);
      }
      return new Response([204, 205, 304].includes(result.status) ? null : body, { status: result.status, headers });
    } catch (error) {
      return json({ error: error?.message === "AGENT_RESPONSE_TIMEOUT" ? "AGENT_TIMEOUT" : "AGENT_UNAVAILABLE" }, 503);
    } finally {
      const pending = this.pending.get(id);
      if (pending) clearTimeout(pending.timer);
      this.pending.delete(id);
    }
  }
  async webSocketMessage(socket, message) {
    if (typeof message !== "string" || message.length > 8 * 1024 * 1024) return;
    let data;
    try { data = JSON.parse(message); } catch { return; }
    if (data?.type !== "response" || typeof data.id !== "string") return;
    const pending = this.pending.get(data.id);
    if (!pending || pending.socket !== socket) return;
    const status = Number(data.status);
    if (!Number.isInteger(status) || status < 200 || status > 599 || typeof data.bodyBase64 !== "string") {
      pending.reject(new Error("INVALID_AGENT_RESPONSE")); return;
    }
    pending.resolve({ status, headers: data.headers && typeof data.headers === "object" ? data.headers : {}, bodyBase64: data.bodyBase64 });
  }
  async webSocketClose(socket, code, reason) {
    for (const [id, pending] of this.pending.entries()) {
      if (pending.socket === socket) {
        clearTimeout(pending.timer); pending.reject(new Error("AGENT_DISCONNECTED")); this.pending.delete(id);
      }
    }
    try { socket.close(code, reason); } catch {}
  }
  async webSocketError(socket) { await this.webSocketClose(socket, 1011, "Agent socket error"); }
}

export async function handleRequest(request, env) {
  const url = new URL(request.url);
  const origin = request.headers.get("Origin");
  if (url.pathname === "/agent/connect") {
    if (request.method !== "GET" || request.headers.get("Upgrade") !== "websocket") return json({ error: "WEBSOCKET_UPGRADE_REQUIRED" }, 426);
    const auth = parseAgentProtocols(request);
    if (!auth.base || !(await verifyAgentToken(auth.token, env.RELAY_SHARED_SECRET))) return json({ error: "AGENT_UNAUTHORIZED" }, 401);
    return env.RELAY_HUB.getByName(HUB_NAME).fetch(request);
  }
  if (url.pathname === "/_relay/health" && request.method === "GET") return relayHealth(env);
  if (origin && origin !== "null") return json({ error: "ORIGIN_NOT_ALLOWED" }, 403);
  return proxyApiRequest(request, env, url);
}
export default { async fetch(request, env) { return handleRequest(request, env); } };
