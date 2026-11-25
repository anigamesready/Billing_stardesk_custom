import test from "node:test";
import assert from "node:assert/strict";
import { AGENT_PROTOCOL, makeAgentToken, verifyAgentToken, isAllowedApiPath, validateEnvelope } from "./protocol.mjs";

test("HMAC token matches the relay Worker protocol and expires", () => {
  const secret = "a".repeat(64);
  const now = 1795615200000;
  const token = makeAgentToken(secret, now);
  assert.equal(token.startsWith(String(now) + "."), true);
  assert.equal(verifyAgentToken(token, secret, now), true);
  assert.equal(verifyAgentToken(token, "b".repeat(64), now), false);
  assert.equal(verifyAgentToken(token, secret, now + 120001), false);
  assert.equal(AGENT_PROTOCOL, "ani-db-relay-v1");
});

test("only API routes allowed by Cloudflare Relay are forwarded", () => {
  assert.equal(isAllowedApiPath("/health", "GET"), true);
  assert.equal(isAllowedApiPath("/rest/v1/rpc/androiddb_v0_remote_login", "POST"), true);
  assert.equal(isAllowedApiPath("/device/heartbeat", "POST"), true);
  assert.equal(isAllowedApiPath("/setup", "GET"), false);
  assert.equal(isAllowedApiPath("/api/admin/bootstrap", "POST"), false);
  assert.equal(isAllowedApiPath("/iot/power", "GET"), false);
  assert.equal(isAllowedApiPath("/iot/status", "POST"), false);
  assert.equal(isAllowedApiPath("/unknown", "GET"), false);
});

test("relay envelope is normalized without accepting absolute or network paths", () => {
  const request = validateEnvelope({
    type: "request",
    id: "0e07a2e1-299b-4f8a-9d7a-95b4a41ec772",
    method: "POST",
    path: "/rest/v1/rpc/androiddb_v0_remote_login",
    headers: { "content-type": "application/json", authorization: "Bearer example", "x-ignore": "ignored" },
    bodyBase64: Buffer.from("{}").toString("base64")
  });
  assert.ok(request);
  assert.equal(request.path, "/rest/v1/rpc/androiddb_v0_remote_login");
  assert.equal(request.headers["x-ignore"], undefined);
  assert.equal(request.body.toString("utf8"), "{}");
  assert.equal(validateEnvelope({
    type: "request", id: "0e07a2e1-299b-4f8a-9d7a-95b4a41ec772", method: "GET", path: "/health", bodyBase64: Buffer.from("x").toString("base64")
  }), null);
  assert.equal(validateEnvelope({
    type: "request", id: "0e07a2e1-299b-4f8a-9d7a-95b4a41ec772", method: "GET", path: "//evil.example/health"
  }), null);
  assert.equal(validateEnvelope({
    type: "request", id: "0e07a2e1-299b-4f8a-9d7a-95b4a41ec772", method: "GET", path: "/setup"
  }), null);
});

test("Relay Agent pins only the approved relay hostname to verified Cloudflare IPv4 edges", () => {
  const host = new URL(RELAY_WS_URL).hostname;
  let allResult;
  relayLookup(host, { all: true }, (error, addresses) => {
    assert.equal(error, null);
    allResult = addresses;
  });
  assert.deepEqual(allResult, [
    { address: "104.18.13.15", family: 4 },
    { address: "104.18.12.15", family: 4 }
  ]);

  let singleResult;
  relayLookup(host, {}, (error, address, family) => {
    assert.equal(error, null);
    singleResult = { address, family };
  });
  assert.deepEqual(singleResult, { address: "104.18.13.15", family: 4 });

  let rejected;
  relayLookup("untrusted.example", {}, error => { rejected = error; });
  assert.equal(rejected?.code, "ENOTFOUND");
  assert.equal(rejected?.message, "RELAY_HOSTNAME_NOT_ALLOWED");
});
