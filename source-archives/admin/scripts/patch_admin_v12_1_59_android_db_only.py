#!/usr/bin/env python3
"""Convert the Admin v12.1.58-derived source to Android DB only.

This script runs AFTER the historical 12.1.58 source patches. It changes only
the Admin app source in this repo: DB Android is the sole API, all relay RPCs
go through the Android DB, and the default local service is 127.0.0.1:8787.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("usage: patch_admin_v12_1_59_android_db_only.py <admin-project-dir>")

root = Path(sys.argv[1]).resolve()
web = root / "android/app/src/main/assets/web"
gradle_path = root / "android/app/build.gradle"
manifest_path = root / "android/app/src/main/AndroidManifest.xml"
main_path = root / "android/app/src/main/java/com/anigames/billingadmin/MainActivity.java"

for needed in (web / "admin.html", web / "index.html", web / "admin-control.html", gradle_path, manifest_path, main_path):
    if not needed.is_file():
        raise SystemExit("ADMIN_SOURCE_FILE_MISSING:" + str(needed))

LOCAL_API = "http://127.0.0.1:8787"
STAGE_GATEWAY = "https://ani-games-db-android-stage-gateway.anigamesready.workers.dev"
STAGE_RELAY = "ani-games-db-android-stage-ws-relay.anigamesready.workers.dev"

api_config = r"""
const LOCAL_API_KEY='ani_games_ready_db_android_api_url_v1';
const ONLINE_GATEWAY_URL='http://127.0.0.1:8787';
const LEGACY_RELAY_HOST='legacy-stage-relay-disabled.invalid';
function localApiBase(){
 let saved='';
 try{saved=String(localStorage.getItem(LOCAL_API_KEY)||'').trim()}catch(_){}
 const target=saved||ONLINE_GATEWAY_URL;
 let u;
 try{u=new URL(target)}catch(_){throw new Error('ALAMAT_API_ANDROID_DB_TIDAK_VALID')}
 const host=String(u.hostname||'').toLowerCase();
 const loopback=['127.0.0.1','localhost','::1'].includes(host);
 if(!['http:','https:'].includes(u.protocol)||(!loopback&&u.protocol!=='https:'))
   throw new Error('API_DI_LUAR_PERANGKAT_WAJIB_HTTPS');
 return u.href.replace(/\/+$/,'');
}
function saveLocalApiUrl(){
 try{
  const value=String($('localApiInput')?.value||'').trim(),u=new URL(value);
  const loopback=['127.0.0.1','localhost','::1'].includes(u.hostname);
  if(!['http:','https:'].includes(u.protocol)||(!loopback&&u.protocol!=='https:'))
    throw new Error('Alamat server di luar perangkat wajib HTTPS.');
  localStorage.setItem(LOCAL_API_KEY,u.href.replace(/\/+$/,''));
  if($('localApiInput'))$('localApiInput').value=localApiBase();
  ensureActiveDbRouteForAuth();
 }catch(e){loginMsg('Alamat API tidak valid: '+String(e?.message||e).slice(0,140))}
}
"""

auth = r"""
let session=null,ctx=null,orgs=[],currentOrg=null,devicesCache=[],selectedDeviceId=null,selectedDevice=null;
function secureGet(key){
 try{const v=window.AniAdminNative?.getSecureValue(key);if(v)return v}catch(_){}
 try{return sessionStorage.getItem(key)||''}catch(_){return ''}
}
function secureSet(key,value){
 try{if(window.AniAdminNative?.setSecureValue(key,String(value)))return true}catch(_){}
 try{sessionStorage.setItem(key,String(value));return true}catch(_){return false}
}
function secureRemove(key){
 try{window.AniAdminNative?.removeSecureValue(key)}catch(_){}
 try{sessionStorage.removeItem(key)}catch(_){}
}
function setAdminAuthEnabled(enabled){
 const root=$('login');if(!root)return;
 root.querySelectorAll('input,button').forEach(control=>{control.disabled=enabled!==true});
}
async function localJson(path,body=null,method='POST',token=''){
 const headers={'content-type':'application/json','accept':'application/json'};
 if(token)headers.authorization='Bearer '+token;
 let response;
 try{
  response=await fetch(localApiBase()+path,{method,headers,cache:'no-store',
   ...(body===null?{}:{body:JSON.stringify(body)})});
 }catch(e){throw new Error('ANDROID_DB_NETWORK_ERROR: '+String(e?.message||e).slice(0,120))}
 const raw=await response.text().catch(()=>''),data=(()=>{try{return raw?JSON.parse(raw):{}}catch(_){return {message:raw.slice(0,160)}}})();
 if(!response.ok)throw new Error(String(data.error||data.message||'ANDROID_DB_HTTP_ERROR')+' [HTTP '+response.status+']');
 return data;
}
async function ensureActiveDbRouteForAuth(){
 setAdminAuthEnabled(false);
 try{
  const base=localApiBase(),health=await localJson('/health',null,'GET');
  if(health?.api!=='online'||health?.database!=='online')throw new Error('ANDROID_DB_NOT_ONLINE');
  if($('localApiInput'))$('localApiInput').value=base;
  setAdminAuthEnabled(true);return true;
 }catch(e){
  setAdminAuthEnabled(true);
  loginMsg('Server Android DB belum siap: '+String(e?.message||e).slice(0,180));
  return false;
 }
}
async function storeAdminRefreshToken(value){
 if(!value){secureRemove('admin_refresh_token');return true}
 return secureSet('admin_refresh_token',value)===true;
}
async function refreshLocalAdminSession(refreshToken){
 const data=await localJson('/auth/v1/token?grant_type=refresh_token',{refresh_token:refreshToken});
 if(!data?.access_token||!data?.refresh_token)throw new Error('ADMIN_REFRESH_SESSION_INVALID');
 if(!(await storeAdminRefreshToken(data.refresh_token)))throw new Error('ADMIN_REFRESH_STORAGE_FAILED');
 return data;
}
async function relayAccessToken(){return session?.access_token||''}
async function login(){
 const button=$('login')?.querySelector('button.primary');
 if(button)button.disabled=true;
 session=null;
 try{
  if(!(await ensureActiveDbRouteForAuth()))return false;
  const username=String($('email')?.value||'').trim(),password=String($('password')?.value||'');
  if(!username||!password)throw new Error('USERNAME_OR_PASSWORD_REQUIRED');
  session=await localJson('/auth/v1/token?grant_type=password',{email:username,password});
  if(!session?.access_token||!session?.refresh_token)throw new Error('ADMIN_LOGIN_RESPONSE_INVALID');
  if(!(await storeAdminRefreshToken(session.refresh_token)))throw new Error('ADMIN_REFRESH_STORAGE_FAILED');
  return await boot();
 }catch(e){
  session=null;loginMsg('Login Admin gagal: '+String(e?.message||e).slice(0,180));return false;
 }finally{if(button)button.disabled=false}
}
async function signup(){loginMsg('Pembuatan akun dilakukan melalui Setup lokal Android DB oleh Owner.')}
async function logout(){
 try{if(session?.access_token)await localJson('/auth/v1/logout',{},'POST',session.access_token)}catch(_){}
 await storeAdminRefreshToken('');session=null;ctx=null;
 try{sessionStorage.clear()}catch(_){}
 location.reload();
}
async function resetPassword(){loginMsg('Reset password dikelola Owner melalui pengaturan akun Android DB.')}
async function rpc(name,args={}){
 const access=session?.access_token||args?.p_session_token||'',payload={...args};
 delete payload.p_session_token;
 const headers={'content-type':'application/json'};if(access)headers.authorization='Bearer '+access;
 const response=await fetch(localApiBase()+'/rest/v1/rpc/'+encodeURIComponent(name),{
  method:'POST',headers,cache:'no-store',body:JSON.stringify(payload)
 });
 const data=await response.json().catch(()=>({}));
 if(!response.ok)throw new Error(data.error||data.message||('ANDROID_DB_HTTP_'+response.status));
 return data;
}
async function boot(){
 try{
  if(!session){
   const refresh=secureGet('admin_refresh_token');
   if(refresh){try{session=await refreshLocalAdminSession(refresh)}catch(_){await storeAdminRefreshToken('');session=null}}
  }
  if(!session?.access_token){
   $('login').classList.remove('hidden');$('app').classList.add('hidden');return false;
  }
  if(!(await ensureActiveDbRouteForAuth()))throw new Error('ANDROID_DB_NOT_READY');
  ctx=await rpc('admin_context');orgs=ctx.orgs||[];
  if(!orgs.length)throw new Error('ORGANIZATION_NOT_FOUND');
  $('login').classList.add('hidden');$('app').classList.remove('hidden');
  $('who').textContent=session.user?.email||session.user?.user_metadata?.username||'Admin';
  $('role').textContent=ctx.role||'admin';
  renderOrgs();applyPairingRoleUI();
  currentOrg=orgs[0];
  if($('orgSelect'))$('orgSelect').value=currentOrg.id;
  await refresh();
  if(ctx.role==='owner'){refreshIoTStatus();ensureNativeNotificationPermission()}
  return true;
 }catch(e){
  $('app').classList.add('hidden');$('login').classList.remove('hidden');
  loginMsg('Gagal memuat dashboard Android DB: '+String(e?.message||e).slice(0,180));
  return false;
 }
}
"""

auth += "\nasync function startLocalAdmin(){setAdminAuthEnabled(true);await boot()}\n"

for name in ("admin.html","index.html","admin-control.html"):
    path = web / name
    page = path.read_text(encoding="utf-8")
    # Remove the Supabase SDK include if the upstream baseline has it.
    page = re.sub(r'<script\b[^>]*src=["\']https://cdn\.jsdelivr\.net/npm/@supabase/supabase-js@2[^>]*></script>', '', page, flags=re.I)
    page = page.replace(STAGE_GATEWAY, LOCAL_API)
    page = page.replace("https://" + STAGE_RELAY, "https://legacy-stage-relay-disabled.invalid")
    # Remove hostnames even when an older patch stored them without a scheme.
    page = page.replace("ani-games-db-android-stage-gateway.anigamesready.workers.dev", "127.0.0.1:8787")
    page = page.replace("ani-games-db-android-stage-ws-relay.anigamesready.workers.dev", "legacy-stage-relay-disabled.invalid")
    page = page.replace("Alamat Gateway DB Android", "Alamat API Android DB")
    page = page.replace("ALAMAT GATEWAY DB ANDROID", "ALAMAT API ANDROID DB")
    # The V12.1.58 gateway repair replaced the original API routing guard.
    local_api_base_fn = """function localApiBase(){
 let saved='';
 try{saved=String(localStorage.getItem(LOCAL_API_KEY)||'').trim()}catch(_){}
 const target=saved||ONLINE_GATEWAY_URL;
 let u;
 try{u=new URL(target)}catch(_){throw new Error('ALAMAT_API_ANDROID_DB_TIDAK_VALID')}
 const host=String(u.hostname||'').toLowerCase();
 const loopback=['127.0.0.1','localhost','::1'].includes(host);
 if(!['http:','https:'].includes(u.protocol)||(!loopback&&u.protocol!=='https:'))
   throw new Error('API_DI_LUAR_PERANGKAT_WAJIB_HTTPS');
 return u.href.replace(/\\/+$/,'');
}"""
    api_fn = re.compile(r"(?ms)^function localApiBase\\(\\)\\s*\\{.*?^\\}")
    if api_fn.search(page):
        page, n = api_fn.subn(lambda _: local_api_base_fn, page, count=1)
        if n != 1:
            raise SystemExit("LOCAL_API_BASE_REPAIR_FAILED:" + name)
    # Keep the endpoint input useful and give localhost the main Android DB port.
    page = page.replace("value=\"https://ani-games-db-android-stage-gateway.anigamesready.workers.dev\"", "value=\"http://127.0.0.1:8787\"")
    page = page.replace("https://ani-games-db-android-stage-gateway.anigamesready.workers.dev", LOCAL_API)
    if name == "admin.html":
        # Replace the complete legacy DB1/DB2/Supabase routing config with one local API config.
        start = page.find("const LOCAL_API_KEY=")
        end = page.find("const GLOBAL_DEVICE_KEY=", start)
        if start < 0 or end < 0:
            raise SystemExit("ADMIN_LOCAL_API_CONFIG_BLOCK_NOT_FOUND")
        page = page[:start] + api_config + "\n" + page[end:]
        # Replace the old Supabase-backed auth/RPC adapter with token-bound Android DB calls.
        start = page.find("async function ensureActiveDbRouteForAuth(){")
        end = page.find("async function fetchIoTWithTimeout", start)
        if start < 0 or end <= start:
            raise SystemExit("ADMIN_AUTH_ADAPTER_BLOCK_NOT_FOUND")
        page = page[:start] + auth + "\n" + page[end:]
        # All Blynk status/power calls now go through this local Android DB API.
        page = page.replace("SB_FUNCTION_URL+'/iot/status'", "localApiBase()+'/iot/status'")
        page = page.replace("SB_FUNCTION_URL+'/iot/power'", "localApiBase()+'/iot/power'")
        page = page.replace("apikey:SB_KEY,", "")
        # All RPC calls must pass through the authenticated Android DB API adapter.
        page = re.sub(r"\bsb\.rpc\s*\(", "rpc(", page)
        # Redirect the old boot caller to the new Android DB adapter.
        page, n = re.subn(r"startDualDbAdmin\(\);", "startLocalAdmin();", page, count=1)
        if n == 0 and "startLocalAdmin();" not in page:
            raise SystemExit("ADMIN_STARTUP_ENTRYPOINT_NOT_FOUND")
        # Remove the retired dual-DB menu/panel nodes if present.
        patterns = [
            r'<(?:a|button)\b[^>]*(?:data-tab|onclick)[^>]*databaseTools[^>]*>.*?</(?:a|button)>',
            r'<section\b[^>]*id=["\']databaseTools[^>]*>.*?</section>',
            r'<div\b[^>]*id=["\']dualDbReadinessPanel["\'][^>]*>.*?</div>',
        ]
        for pattern in patterns:
            page = re.sub(pattern, "", page, flags=re.I|re.S)
        page = page.replace("Database & Sync DB1/DB2", "Konfigurasi Android DB")
        page = page.replace("Database & Sync", "Android DB")
        page = page.replace("Supabase Direct", "Android DB")
        page = page.replace("Supabase Auth", "Admin Android DB")
        # Legacy alert text used DB_TARGET only to label the former DB1/DB2 route.
        # It is presentation-only and now reports the sole Android DB.
        page = page.replace("DB_TARGET==='backup'?'DB2':'DB1'", "'Android DB'")
        page = page.replace("String(DB_TARGET||'primary')", "'Android DB'")
        page = page.replace("DB_TARGET||'primary'", "'android_db'")
    path.write_text(page, encoding="utf-8")

# The APK identity remains Admin v12.1.58-derived, but uses a new package id so
# it can be installed alongside the selected baseline without overwriting it.
gradle = gradle_path.read_text(encoding="utf-8")
gradle, n1 = re.subn(r"applicationId\s+['\"][^'\"]+['\"]",
                     "applicationId 'com.anigames.billingadmin.v159dbonly'", gradle, count=1)
gradle, n2 = re.subn(r"versionCode\s+\d+", "versionCode 86", gradle, count=1)
gradle, n3 = re.subn(r"versionName\s+['\"][^'\"]+['\"]", "versionName '12.1.59-DBANDROID'", gradle, count=1)
if (n1,n2,n3)!=(1,1,1):
    raise SystemExit("ADMIN_VERSION_METADATA_PATCH_FAILED:" + repr((n1,n2,n3)))
gradle_path.write_text(gradle, encoding="utf-8")

manifest = manifest_path.read_text(encoding="utf-8")
manifest = re.sub(r'android:label="[^"]+"', 'android:label="AniGames Admin V12.1.59 Android DB"', manifest, count=1)
manifest_path.write_text(manifest, encoding="utf-8")

# Static release-candidate gates. No Supabase URL/client, stage route, DB1/DB2
# selector, or old local-port default is permitted in any shipped Admin HTML.
for name in ("admin.html","index.html","admin-control.html"):
    page=(web/name).read_text(encoding="utf-8")
    lower=page.lower()
    for forbidden in ("supabase.co","supabase.createclient","sb.schema(","sb.from(","ani-games-db-android-stage","127.0.0.1:8788","DB1_URL","DB2_URL","SB_FUNCTION_URL","SB_KEY"):
        if forbidden.lower() in lower:
            raise SystemExit("FORBIDDEN_ADMIN_BACKEND_REFERENCE:"+name+":"+forbidden)
    if re.search(r"\bsb\.", page, re.I):
        refs=[f"{i+1}:{line.strip()[:220]}" for i,line in enumerate(page.splitlines()) if re.search(r"\bsb\.", line, re.I)]
        raise SystemExit("LEGACY_SUPABASE_CLIENT_REFERENCES:"+name+":"+" || ".join(refs[:30]))
    if "DB_TARGET" in page:
        refs=[f"{i+1}:{line.strip()[:220]}" for i,line in enumerate(page.splitlines()) if "DB_TARGET" in line]
        raise SystemExit("LEGACY_DB_TARGET_REFERENCES:"+name+":"+" || ".join(refs[:30]))
    if "http://127.0.0.1:8787" not in page and "ONLINE_GATEWAY_URL" in page:
        raise SystemExit("ANDROID_DB_MAIN_PORT_DEFAULT_MISSING:"+name)
    scripts=re.findall(r'<script\b(?![^>]*\bsrc=)[^>]*>(.*?)</script>',page,re.I|re.S)
    if name=="admin.html":
        if len(scripts)!=1: raise SystemExit("ADMIN_INLINE_SCRIPT_COUNT_INVALID")
        Path("/tmp/admin-v1259.js").write_text(scripts[0],encoding="utf-8")
    if name=="index.html" and "localApiBase" not in page:
        raise SystemExit("ADMIN_LOGIN_ENTRY_ANDROID_DB_CONFIG_MISSING")
    if name=="admin-control.html" and "localApiBase" not in page:
        raise SystemExit("ADMIN_CONTROL_ANDROID_DB_CONFIG_MISSING")

print("PASS: V12.1.58-derived Admin now routes Admin, WoL relay RPC, and Blynk proxy through Android DB only.")
print("INFO: new app id com.anigames.billingadmin.v159dbonly, versionCode 86, versionName 12.1.59-DBANDROID.")
