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

test("StarDesk path prefix reaches an independent Gateway relay hub while old path is unchanged",async()=>{
 let paths=[],auths=[];
 const env={EDGE_PROXY_SECRET:"edge-test",RELAY_SERVICE:{fetch:async r=>{
   paths.push(new URL(r.url).pathname);auths.push(r.headers.get("x-ani-gateway-auth"));
   return Response.json({message:"AUTH_REQUIRED"},{status:401});
 }}};
 const legacy=await gateway.fetch(req("https://gateway.test/rest/v1/rpc/admin_context"),env);
 const stardesk=await gateway.fetch(req("https://gateway.test/stardesk/rest/v1/rpc/admin_context"),env);
 assert.equal(legacy.status,401);assert.equal(stardesk.status,401);
 assert.equal(paths[0],"/rest/v1/rpc/admin_context");
 assert.equal(paths[1],"/stardesk/rest/v1/rpc/admin_context");
 assert.deepEqual(auths,["edge-test","edge-test"]);
});

test("StarDesk Gateway health uses its own relay hub, not the legacy hub",async()=>{
 let path="";
 const env={EDGE_PROXY_SECRET:"edge-test",RELAY_SERVICE:{fetch:async r=>{
   path=new URL(r.url).pathname;
   return Response.json({relay:"online",agent_connected:true,api:"online",database:"online"});
 }}};
 const res=await gateway.fetch(req("https://gateway.test/stardesk/_ani_gateway/health"),env);
 assert.equal(res.status,200);assert.equal(path,"/_relay/stardesk/health");
 const d=await res.json();assert.equal(d.upstream_active,true);assert.equal(d.database,"online");
});

test("StarDesk Gateway blocks loopback-only Owner bootstrap while preserving allowed RPC routing",async()=>{
 let calls=0;
 const env={EDGE_PROXY_SECRET:"edge-test",RELAY_SERVICE:{fetch:async r=>{calls++;return Response.json({ok:true});}}};
 const denied=await gateway.fetch(req("https://gateway.test/stardesk/api/admin/bootstrap","POST",{}),env);
 assert.equal(denied.status,403);assert.equal(calls,0);
 const ok=await gateway.fetch(req("https://gateway.test/stardesk/rest/v1/rpc/androiddb_v0_admin_dashboard","POST",{}),env);
 assert.equal(ok.status,200);assert.equal(calls,1);
});

test("Relay forwards the StarDesk prefix to a separate Durable Object name and strips it from the local API envelope",async()=>{
 let hubName="",path="",method="";
 const env={RELAY_HUB:{getByName:name=>{
   hubName=name;
   return {fetch:async r=>{path=new URL(r.url).pathname;if(path==="/proxy"){const body=await r.json();method=body.path;}return Response.json({ok:true});}};
 }}};
 const res=await relay.fetch(req("https://relay.test/stardesk/rest/v1/rpc/admin_context"),env);
 assert.equal(res.status,200);assert.equal(hubName,"redmi-stardesk-custom");
 assert.equal(path,"/proxy");assert.equal(method,"/rest/v1/rpc/admin_context");
});

test("Relay health checks the dedicated StarDesk hub only",async()=>{
 const names=[],paths=[];
 const env={RELAY_HUB:{getByName:name=>{
  names.push(name);
  return {fetch:async r=>{
    const p=new URL(typeof r==="string"?r:r.url).pathname;paths.push(p);
    if(p==="/status")return Response.json({connected:true,connected_since:"test"});
    return Response.json({api:"online",database:"online"});
  }};
 }}};
 const res=await relay.fetch(req("https://relay.test/_relay/stardesk/health"),env);
 assert.equal(res.status,200);assert.equal(names[0],"redmi-stardesk-custom");
 assert.equal(paths[0],"/status");assert.equal(paths[1],"/proxy");
 const d=await res.json();assert.equal(d.api,"online");assert.equal(d.database,"online");
});
