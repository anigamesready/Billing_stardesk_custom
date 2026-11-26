import test from "node:test";
import assert from "node:assert/strict";
import gateway from "../edge/cloudflare/ani-games-db-android-stage-gateway.mjs";
import relay from "../edge/cloudflare/ani-games-db-android-stage-ws-relay.mjs";
const IP="203.0.113.10";
function req(url,method="GET",body){const headers={"CF-Connecting-IP":IP,"Origin":"null"};if(body!==undefined)headers["content-type"]="application/json";return new Request(url,{method,headers,body:body===undefined?undefined:JSON.stringify(body)});}

test("gateway exact GET /iot/status forwards through the private relay binding",async()=>{
 let path="",auth="";
 const env={EDGE_PROXY_SECRET:"edge-test",RELAY_SERVICE:{fetch:async r=>{path=new URL(r.url).pathname;auth=r.headers.get("x-ani-gateway-auth");return Response.json({ok:true,online:true});}}};
 const res=await gateway.fetch(req("https://gateway.test/iot/status"),env);
 assert.equal(res.status,200);assert.equal((await res.json()).online,true);assert.equal(path,"/iot/status");assert.equal(auth,"edge-test");
});
test("gateway exact POST /iot/power forwards, but arbitrary IoT paths remain denied",async()=>{
 let calls=0,path="";
 const env={EDGE_PROXY_SECRET:"edge-test",RELAY_SERVICE:{fetch:async r=>{calls++;path=new URL(r.url).pathname;return Response.json({ok:true,pulse_ms:500});}}};
 const res=await gateway.fetch(req("https://gateway.test/iot/power","POST",{deviceId:"ci-device"}),env);
 assert.equal(res.status,200);assert.equal(path,"/iot/power");assert.equal((await res.json()).pulse_ms,500);
 const denied=await gateway.fetch(req("https://gateway.test/iot/internal"),env);
 assert.equal(denied.status,404);assert.equal(calls,1);
});
test("gateway restricts method/path combinations",async()=>{
 let calls=0;const env={EDGE_PROXY_SECRET:"edge-test",RELAY_SERVICE:{fetch:async()=>{calls++;return Response.json({ok:true});}}};
 assert.equal((await gateway.fetch(req("https://gateway.test/iot/status","POST",{}),env)).status,405);
 assert.equal((await gateway.fetch(req("https://gateway.test/iot/power","GET"),env)).status,405);
 assert.equal(calls,0);
});
test("gateway Origin:null preflight is limited to the approved Blynk route",async()=>{
 const res=await gateway.fetch(req("https://gateway.test/iot/power","OPTIONS"),{EDGE_PROXY_SECRET:"x",RELAY_SERVICE:{fetch:async()=>{throw new Error("preflight must not be proxied");}}});
 assert.equal(res.status,204);assert.equal(res.headers.get("access-control-allow-origin"),"null");
});
test("relay exact GET /iot/status enters the relay proxy envelope",async()=>{
 let envelope=null;
 const env={RELAY_HUB:{getByName:name=>{assert.equal(name,"redmi-db-android-stage");return {fetch:async r=>{envelope=await r.json();return Response.json({ok:true});}};}}};
 const res=await relay.fetch(req("https://relay.test/iot/status"),env);
 assert.equal(res.status,200);assert.equal(envelope.path,"/iot/status");assert.equal(envelope.method,"GET");assert.equal(envelope.clientIp,IP);
});
test("relay exact POST /iot/power passes the JSON body and blocks other IoT paths",async()=>{
 let envelope=null;const env={RELAY_HUB:{getByName:()=>({fetch:async r=>{envelope=await r.json();return Response.json({ok:true});}})}};
 const res=await relay.fetch(req("https://relay.test/iot/power","POST",{deviceId:"ci-device"}),env);
 assert.equal(res.status,200);assert.equal(envelope.path,"/iot/power");assert.equal(envelope.method,"POST");
 assert.deepEqual(JSON.parse(Buffer.from(envelope.bodyBase64,"base64").toString("utf8")),{deviceId:"ci-device"});
 assert.equal((await relay.fetch(req("https://relay.test/iot/internal"),env)).status,404);
});
test("relay restricts methods and handles Origin:null preflight without opening a WebSocket request",async()=>{
 let calls=0;const env={RELAY_HUB:{getByName:()=>({fetch:async()=>{calls++;return Response.json({ok:true});}})}};
 assert.equal((await relay.fetch(req("https://relay.test/iot/status","POST",{}),env)).status,405);
 assert.equal((await relay.fetch(req("https://relay.test/iot/power","GET"),env)).status,405);
 assert.equal((await relay.fetch(req("https://relay.test/iot/power","OPTIONS"),env)).status,204);
 assert.equal(calls,0);
});

test("Admin Bearer token survives Cloudflare Gateway and WebSocket Relay forwarding",async()=>{
 let envelope=null;
 const relayEnv={
  RELAY_SHARED_SECRET:"edge-test",
  RELAY_HUB:{getByName:name=>{
   assert.equal(name,"redmi-db-android-stage");
   return {fetch:async request=>{
    assert.equal(new URL(request.url).pathname,"/proxy");
    envelope=await request.json();
    // RelayHub restores the agent envelope to the final upstream HTTP response.
    return Response.json({ok:true});
   }};
  }}
 };
 const gatewayEnv={
  EDGE_PROXY_SECRET:"edge-test",
  RELAY_SERVICE:{fetch:request=>relay.fetch(request,relayEnv)}
 };
 const request=new Request("https://gateway.test/rest/v1/rpc/admin_rental_accounts_global",{
  method:"POST",
  headers:{
   "CF-Connecting-IP":IP,
   "Origin":"null",
   "Authorization":"Bearer ci-admin-session-token",
   "Content-Type":"application/json"
  },
  body:JSON.stringify({p_org_id:"00000000-0000-4000-8000-000000000001"})
 });
 const response=await gateway.fetch(request,gatewayEnv);
 assert.equal(response.status,200);
 assert.deepEqual(await response.json(),{ok:true});
 assert.equal(envelope?.path,"/rest/v1/rpc/admin_rental_accounts_global");
 assert.equal(envelope?.headers?.authorization,"Bearer ci-admin-session-token");
});
