import WebSocket from "ws";
import { AGENT_PROTOCOL, RELAY_WS_URL, MAX_RESPONSE_BYTES, makeAgentToken, validateEnvelope } from "./protocol.mjs";

const SECRET = process.env.RELAY_SHARED_SECRET || "";
const API_BASE = new URL(process.env.ANI_LOCAL_API_URL || "http://127.0.0.1:8788");
const WS_URL = new URL(process.env.RELAY_WS_URL || RELAY_WS_URL);
const MAX_IN_FLIGHT = 64;

if (SECRET.length < 32) throw new Error("RELAY_SHARED_SECRET_REQUIRED");
if (API_BASE.protocol !== "http:" || !["127.0.0.1", "::1", "localhost"].includes(API_BASE.hostname) ||
    API_BASE.username || API_BASE.password || API_BASE.search || API_BASE.hash || !["", "/"].includes(API_BASE.pathname)) {
  throw new Error("ANI_LOCAL_API_URL_MUST_BE_LOOPBACK_HTTP_WITHOUT_PATH");
}
if (WS_URL.protocol !== "wss:" || WS_URL.hostname !== "ani-games-db-android-stage-ws-relay.anigamesready.workers.dev" ||
    WS_URL.pathname !== "/agent/connect" || WS_URL.search || WS_URL.hash) {
  throw new Error("RELAY_WS_URL_NOT_ALLOWED");
}

let stopping = false;
let activeSocket = null;
let reconnectTimer = null;
let reconnectDelay = 2000;
let inFlight = 0;

function log(event, fields = {}) {
  process.stdout.write(JSON.stringify({ at: new Date().toISOString(), service: "ani-games-relay-agent", event, ...fields }) + "\n");
}
function sendResponse(socket, payload) {
  if (socket.readyState !== WebSocket.OPEN) return;
  try { socket.send(JSON.stringify(payload)); } catch {}
}
function responsePayload(id, status, body, headers = {}) {
  return { type: "response", id, status, headers, bodyBase64: Buffer.from(body).toString("base64") };
}

async function forwardRequest(socket, raw) {
  let message;
  try { message = JSON.parse(raw.toString("utf8")); } catch { return; }
  if (message?.type !== "request" || typeof message.id !== "string") return;
  const request = validateEnvelope(message);
  if (!request) {
    sendResponse(socket, responsePayload(message.id, 400, JSON.stringify({ error: "INVALID_RELAY_REQUEST" }), {
      "content-type": "application/json; charset=utf-8"
    }));
    return;
  }
  if (inFlight >= MAX_IN_FLIGHT) {
    sendResponse(socket, responsePayload(request.id, 503, JSON.stringify({ error: "RELAY_AGENT_BUSY" }), {
      "content-type": "application/json; charset=utf-8", "retry-after": "2"
    }));
    return;
  }

  inFlight += 1;
  try {
    const target = new URL(request.path, API_BASE);
    if (target.origin !== API_BASE.origin) throw new Error("LOCAL_TARGET_REJECTED");
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), target.pathname === "/health" ? 7000 : 27000);
    let localResponse;
    try {
      const init = { method: request.method, headers: request.headers, signal: controller.signal, redirect: "manual" };
      if (request.method === "POST") init.body = request.body;
      localResponse = await fetch(target, init);
    } finally {
      clearTimeout(timeout);
    }

    const body = Buffer.from(await localResponse.arrayBuffer());
    if (body.length > MAX_RESPONSE_BYTES) {
      sendResponse(socket, responsePayload(request.id, 502, JSON.stringify({ error: "LOCAL_RESPONSE_TOO_LARGE" }), {
        "content-type": "application/json; charset=utf-8"
      }));
      return;
    }
    const headers = {};
    for (const name of ["content-type", "retry-after"]) {
      const value = localResponse.headers.get(name);
      if (value) headers[name] = value.slice(0, 256);
    }
    sendResponse(socket, responsePayload(request.id, localResponse.status, body, headers));
  } catch (error) {
    const timedOut = error?.name === "AbortError";
    sendResponse(socket, responsePayload(request.id, timedOut ? 504 : 502,
      JSON.stringify({ error: timedOut ? "LOCAL_API_TIMEOUT" : "LOCAL_API_UNREACHABLE" }),
      { "content-type": "application/json; charset=utf-8" }));
    log("local_request_failed", { code: timedOut ? "TIMEOUT" : "UNREACHABLE" });
  } finally {
    inFlight = Math.max(0, inFlight - 1);
  }
}

function scheduleReconnect() {
  if (stopping || reconnectTimer) return;
  const delay = Math.min(reconnectDelay, 30000);
  reconnectDelay = Math.min(reconnectDelay * 2, 30000);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay + Math.floor(Math.random() * 1000));
  reconnectTimer.unref?.();
}

function connect() {
  if (stopping) return;
  const token = makeAgentToken(SECRET);
  const socket = new WebSocket(WS_URL, [AGENT_PROTOCOL, "ani-token-" + token], {
    handshakeTimeout: 15000, maxPayload: 10 * 1024 * 1024, perMessageDeflate: false
  });
  activeSocket = socket;
  let heartbeat = null;
  let lastPong = Date.now();

  socket.on("open", () => {
    reconnectDelay = 2000;
    lastPong = Date.now();
    log("connected");
    heartbeat = setInterval(() => {
      if (socket.readyState !== WebSocket.OPEN) return;
      if (Date.now() - lastPong > 60000) {
        log("heartbeat_timeout");
        socket.terminate();
        return;
      }
      socket.send("AGENT_PING");
    }, 20000);
  });
  socket.on("message", data => {
    const raw = data.toString("utf8");
    if (raw === "AGENT_PONG") { lastPong = Date.now(); return; }
    void forwardRequest(socket, data);
  });
  socket.on("unexpected-response", (_request, response) => {
    log("handshake_rejected", { status: response.statusCode || 0 });
  });
  socket.on("error", error => log("socket_error", { code: error?.code || "UNKNOWN" }));
  socket.on("close", code => {
    if (heartbeat) clearInterval(heartbeat);
    if (activeSocket === socket) activeSocket = null;
    log("disconnected", { code });
    scheduleReconnect();
  });
}

function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  if (reconnectTimer) clearTimeout(reconnectTimer);
  log("stopping", { signal });
  try { activeSocket?.close(1000, "Agent stopping"); } catch {}
  setTimeout(() => process.exit(0), 1000).unref?.();
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
log("starting", { localApi: API_BASE.origin, endpoint: WS_URL.origin });
connect();
