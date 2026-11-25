import { createHmac, timingSafeEqual } from "node:crypto";

export const AGENT_PROTOCOL = "ani-db-relay-v1";
export const RELAY_WS_URL = "wss://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev/agent/connect";
export const MAX_REQUEST_BYTES = 2 * 1024 * 1024;
export const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;

const ALLOWED_EXACT = new Set([
  "/health", "/auth/v1/token", "/auth/v1/user", "/auth/v1/logout", "/iot/status", "/iot/power"
]);

export function makeAgentToken(secret, now = Date.now()) {
  if (typeof secret !== "string" || secret.length < 32) throw new Error("RELAY_SHARED_SECRET_MUST_BE_AT_LEAST_32_CHARACTERS");
  const timestamp = Math.trunc(now);
  const signature = createHmac("sha256", secret).update(AGENT_PROTOCOL + ":" + timestamp).digest("hex");
  return String(timestamp) + "." + signature;
}

export function verifyAgentToken(token, secret, now = Date.now()) {
  if (typeof token !== "string" || typeof secret !== "string" || secret.length < 32) return false;
  const parts = token.split(".");
  if (parts.length !== 2) return false;
  const timestamp = Number(parts[0]);
  if (!Number.isSafeInteger(timestamp) || Math.abs(now - timestamp) > 120000 || !/^[0-9a-f]{64}$/i.test(parts[1])) return false;
  const expected = createHmac("sha256", secret).update(AGENT_PROTOCOL + ":" + timestamp).digest();
  const supplied = Buffer.from(parts[1], "hex");
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

export function isAllowedApiPath(pathname, method) {
  if (pathname === "/setup" || pathname.startsWith("/setup/") ||
      pathname === "/api/admin/bootstrap" || pathname.startsWith("/api/admin/bootstrap/")) return false;
  if (ALLOWED_EXACT.has(pathname)) {
    if (pathname === "/iot/status") return method === "GET";
    if (pathname === "/iot/power") return method === "POST";
    return method === "GET" || method === "POST";
  }
  if (method !== "POST") return false;
  return /^\/rest\/v1\/rpc\/[a-z][a-z0-9_]{1,100}$/i.test(pathname) ||
    /^\/device\/[a-z0-9/_-]+$/i.test(pathname) ||
    pathname === "/functions/v1/ani-games-api" ||
    /^\/functions\/v1\/ani-games-api\/[a-z0-9/_-]+$/i.test(pathname);
}

export function validateEnvelope(input) {
  if (!input || typeof input !== "object" || input.type !== "request") return null;
  if (typeof input.id !== "string" || !/^[0-9a-f-]{36}$/i.test(input.id)) return null;
  if (!["GET", "POST"].includes(input.method)) return null;
  if (typeof input.path !== "string" || !input.path.startsWith("/") || input.path.startsWith("//")) return null;
  let url;
  try { url = new URL(input.path, "http://relay.invalid"); } catch { return null; }
  if (url.origin !== "http://relay.invalid" || !isAllowedApiPath(url.pathname, input.method)) return null;

  const encoded = typeof input.bodyBase64 === "string" ? input.bodyBase64 : "";
  if (encoded.length > Math.ceil(MAX_REQUEST_BYTES * 4 / 3) + 8 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) return null;
  const headers = {};
  const sourceHeaders = input.headers && typeof input.headers === "object" ? input.headers : {};
  for (const name of ["authorization", "apikey", "content-type", "x-client-info"]) {
    const value = sourceHeaders[name];
    if (typeof value === "string" && value.length <= 4096) headers[name] = value;
  }
  return { id: input.id, method: input.method, path: url.pathname + url.search, headers, body: Buffer.from(encoded, "base64") };
}
