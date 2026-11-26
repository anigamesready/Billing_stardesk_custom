import test from "node:test";
import assert from "node:assert/strict";
import { AGENT_PROTOCOL, RELAY_WS_URL, makeAgentToken, verifyAgentToken, isAllowedApiPath, validateEnvelope, relayLookup } from "./protocol.mjs";

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

import { createReconnectController } from "./reconnect.mjs";

test("Reconnect timer stays referenced and backs off until the link is stable", () => {
  const jobs = new Map();
  const waits = [];
  let nextId = 1;
  let connects = 0;
  let timerWasUnrefed = false;
  const controller = createReconnectController({
    connect: () => { connects += 1; },
    random: () => 0.5,
    scheduleTimer: (callback, delay) => {
      const id = nextId++;
      waits.push(delay);
      jobs.set(id, callback);
      return { id, unref() { timerWasUnrefed = true; } };
    },
    cancelTimer: handle => jobs.delete(handle.id),
  });

  assert.equal(controller.schedule(), 2500);
  assert.equal(controller.pending, true);
  assert.equal(controller.schedule(), null);
  assert.equal(jobs.size, 1);
  assert.equal(timerWasUnrefed, false);

  const first = [...jobs.values()][0];
  jobs.clear();
  first();
  assert.equal(connects, 1);
  assert.equal(controller.schedule(), 4500);

  const second = [...jobs.values()][0];
  jobs.clear();
  second();
  assert.equal(connects, 2);
  assert.equal(controller.schedule(), 8500);

  controller.markStable();
  assert.equal(controller.nextDelayMs, 2000);
  const third = [...jobs.values()][0];
  jobs.clear();
  third();
  assert.equal(connects, 3);
  assert.equal(controller.schedule(), 2500);
  assert.deepEqual(waits, [2500, 4500, 8500, 2500]);
  assert.equal(timerWasUnrefed, false);
  controller.stop();
  assert.equal(controller.pending, false);
  assert.equal(controller.stopped, true);
  assert.equal(controller.schedule(), null);
});

test("Stopping reconnect cancels pending work and prevents reconnect", () => {
  const jobs = new Map();
  let connects = 0;
  const controller = createReconnectController({
    connect: () => { connects += 1; },
    random: () => 0,
    scheduleTimer: callback => { jobs.set(1, callback); return 1; },
    cancelTimer: id => jobs.delete(id),
  });
  controller.schedule();
  controller.stop();
  assert.equal(jobs.size, 0);
  assert.equal(controller.schedule(), null);
  assert.equal(connects, 0);
});
