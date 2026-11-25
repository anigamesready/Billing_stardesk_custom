import test from "node:test";
import assert from "node:assert/strict";
import gateway from "../edge/cloudflare/ani-games-db-android-stage-gateway.mjs";
import relay from "../edge/cloudflare/ani-games-db-android-stage-ws-relay.mjs";

const IP = "203.0.113.10";
const ORIGIN = "null";

function request(url, method="GET", body) {
  const headers = {"CF-Connecting-IP": IP, "Origin": ORIGIN};
  if (body !== undefined) headers["content-type"] = "application/json";
  return new Request(url, {method, headers, body: body === undefined ? undefined : JSON.stringify(body)});
}

test("gateway forwards GET /iot/status to the private relay binding", async () => {
  let seen = null;
  const response = await gateway.fetch(request("https://gateway.test/iot/status"), {
    EDGE_PROXY_SECRET: "gateway-test-secret",
    RELAY_SERVICE: {fetch: async forwarded => {
      seen = forwarded;
      return Response.json({ok:true,online:true});
    }}
  });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).online, true);
  assert.equal(new URL(seen.url).pathname, "/iot/status");
  assert.equal(seen.headers.get("x-ani-edge-client-ip"), IP);
});

test("gateway forwards POST /iot/power but rejects all other IoT paths", async () => {
  let calls = 0;
  const env = {
    EDGE_PROXY_SECRET: "gateway-test-secret",
    RELAY_SERVICE: {fetch: async forwarded => {
      calls++;
      assert.equal(new URL(forwarded.url).pathname, "/iot/power");
      assert.equal(forwarded.method, "POST");
      return Response.json({ok:true,pulse_ms:500});
    }}
  };
  const response = await gateway.fetch(request("https://gateway.test/iot/power","POST",{deviceId:"device-test"}),env);
  assert.equal(response.status,200);
  assert.equal((await response.json()).pulse_ms,500);
  const denied = await gateway.fetch(request("https://gateway.test/iot/admin-secret"),env);
  assert.equal(denied.status,404);
  assert.equal(calls,1);
});

test("gateway restricts Blynk method/route combinations", async () => {
  let calls = 0;
  const env = {EDGE_PROXY_SECRET:"x",RELAY_SERVICE:{fetch:async()=>{calls++;return Response.json({ok:true});}}};
  const badStatus = await gateway.fetch(request("https://gateway.test/iot/status","POST",{}),env);
  const badPower = await gateway.fetch(request("https://gateway.test/iot/power","GET"),env);
  assert.equal(badStatus.status,405);
  assert.equal(badPower.status,405);
  assert.equal(calls,0);
});

test("gateway accepts an Origin:null preflight only for the exact Blynk path", async () => {
  const response = await gateway.fetch(request("https://gateway.test/iot/power","OPTIONS"), {
    EDGE_PROXY_SECRET:"x",
    RELAY_SERVICE:{fetch:async()=>{throw new Error("preflight must not call relay");}}
  });
  assert.equal(response.status,204);
  assert.equal(response.headers.get("access-control-allow-origin"),"null");
});

test("relay allowlist forwards GET /iot/status to the WebSocket Agent", async () => {
  let envelope = null;
  const env = {RELAY_HUB:{getByName:name=>{
    assert.equal(name,"redmi-db-android-stage");
    return {fetch:async req=>{
      envelope=await req.json();
      return Response.json({ok:true});
    }};
  }}};
  const response = await relay.fetch(request("https://relay.test/iot/status"),env);
  assert.equal(response.status,200);
  assert.equal(envelope.path,"/iot/status");
  assert.equal(envelope.method,"GET");
  assert.equal(envelope.clientIp,IP);
});

test("relay allowlist forwards POST /iot/power and denies other /iot routes", async () => {
  let envelope = null;
  const env = {RELAY_HUB:{getByName:()=>({fetch:async req=>{
    envelope=await req.json();
    return Response.json({ok:true});
  }})}};
  const response = await relay.fetch(request("https://relay.test/iot/power","POST",{deviceId:"device-test"}),env);
  assert.equal(response.status,200);
  assert.equal(envelope.path,"/iot/power");
  assert.equal(envelope.method,"POST");
  assert.deepEqual(JSON.parse(Buffer.from(envelope.bodyBase64,"base64").toString("utf8")),{deviceId:"device-test"});
  const denied = await relay.fetch(request("https://relay.test/iot/internal"),env);
  assert.equal(denied.status,404);
  assert.equal(envelope.path,"/iot/power");
});

test("relay restricts Blynk method/route combinations and supports preflight", async () => {
  let calls=0;
  const env = {RELAY_HUB:{getByName:()=>({fetch:async()=>{calls++;return Response.json({ok:true});}})}};
  const badStatus=await relay.fetch(request("https://relay.test/iot/status","POST",{}),env);
  const badPower=await relay.fetch(request("https://relay.test/iot/power","GET"),env);
  const preflight=await relay.fetch(request("https://relay.test/iot/power","OPTIONS"),env);
  assert.equal(badStatus.status,405);
  assert.equal(badPower.status,405);
  assert.equal(preflight.status,204);
  assert.equal(calls,0);
});
