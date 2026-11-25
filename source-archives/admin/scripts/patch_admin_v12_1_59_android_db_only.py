#!/usr/bin/env python3
"""Convert the Admin v12.1.58-derived source to Android DB only.

This script runs AFTER the historical 12.1.58 source patches. It changes only
the Admin app source in this repo: Android DB is the sole API. All Admin,
Blynk and WoL requests use the fixed online HTTPS gateway. The Termux API
remains private behind the relay and is never a client-side endpoint.
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

ONLINE_API = "https://ani-games-db-android-stage-gateway.anigamesready.workers.dev"
STAGE_GATEWAY = ONLINE_API
STAGE_RELAY = "ani-games-db-android-stage-ws-relay.anigamesready.workers.dev"

api_config = r"""
const LOCAL_API_KEY='ani_games_ready_db_android_api_url_v1';
const ONLINE_GATEWAY_URL='https://ani-games-db-android-stage-gateway.anigamesready.workers.dev';
const LEGACY_RELAY_HOST='ani-games-db-android-stage-ws-relay.anigamesready.workers.dev';
function localApiBase(){
  try{localStorage.setItem(LOCAL_API_KEY,ONLINE_GATEWAY_URL)}catch(_){}
  return ONLINE_GATEWAY_URL;
}
function saveLocalApiUrl(){
  if($('localApiInput'))$('localApiInput').value='';
  loginMsg('Gateway Android DB online dikonfigurasi otomatis.');
}
"""

auth = r"""
// Reuse the single shared Admin state declared by the original page.
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

auth += "\nfunction hideAdminApiEditor(){
 const input=$('localApiInput');if(!input)return;
 input.value='';
 let node=input.parentElement;
 while(node&&node!==$('login')){
  const inputs=Array.from(node.querySelectorAll('input'));
  const buttons=Array.from(node.querySelectorAll('button'));
  const onlyApiInput=inputs.length===1&&inputs[0]===input;
  const onlyApiButtons=buttons.every(b=>/saveLocalApiUrl|gateway|server|api|simpan/i.test(String(b.textContent||'')+' '+String(b.getAttribute('onclick')||'')));
  if(onlyApiInput&&onlyApiButtons){
   const previous=node.previousElementSibling;
   node.remove();
   if(previous&&previous.tagName==='LABEL'&&previous.htmlFor==='localApiInput')previous.remove();
   document.querySelectorAll('label[for="localApiInput"]').forEach(x=>x.remove());
   return;
  }
  node=node.parentElement;
 }
 document.querySelectorAll('label[for="localApiInput"]').forEach(x=>x.remove());
 input.remove();
}
async function startLocalAdmin(){hideAdminApiEditor();setAdminAuthEnabled(true);await boot()}\n"

for name in ("admin.html","index.html","admin-control.html"):
    path = web / name
    page = path.read_text(encoding="utf-8")
    # Remove the Supabase SDK include if the upstream baseline has it.
    page = re.sub(r'<script\b[^>]*src=["\']https://cdn\.jsdelivr\.net/npm/@supabase/supabase-js@2[^>]*></script>', '', page, flags=re.I)
    page = page.replace(STAGE_GATEWAY, ONLINE_API)
    page = page.replace("https://" + STAGE_RELAY, "https://legacy-stage-relay-disabled.invalid")
    # Remove hostnames even when an older patch stored them without a scheme.
    page = page.replace("ani-games-db-android-stage-gateway.anigamesready.workers.dev", ONLINE_API)
    page = page.replace("ani-games-db-android-stage-ws-relay.anigamesready.workers.dev", "legacy-stage-relay-disabled.invalid")
    page = page.replace("Alamat Gateway DB Android", "Alamat API Android DB")
    page = page.replace("ALAMAT GATEWAY DB ANDROID", "ALAMAT API ANDROID DB")
    # The V12.1.58 gateway repair replaced the original API routing guard.
    local_api_base_fn = """function localApiBase(){
 try{localStorage.setItem(LOCAL_API_KEY,ONLINE_GATEWAY_URL)}catch(_){}
 return ONLINE_GATEWAY_URL;
}"""
    api_fn = re.compile(r"(?ms)^function localApiBase\\(\\)\\s*\\{.*?^\\}")
    if api_fn.search(page):
        page, n = api_fn.subn(lambda _: local_api_base_fn, page, count=1)
        if n != 1:
            raise SystemExit("LOCAL_API_BASE_REPAIR_FAILED:" + name)
    # Keep the endpoint input useful and give localhost the main Android DB port.
    page = page.replace("value=\"https://ani-games-db-android-stage-gateway.anigamesready.workers.dev\"", "value=\"http://127.0.0.1:8787\"")
    page = page.replace("https://ani-games-db-android-stage-gateway.anigamesready.workers.dev", ONLINE_API)
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
                     "applicationId 'com.anigames.billingadmin.v160online'", gradle, count=1)
gradle, n2 = re.subn(r"versionCode\s+\d+", "versionCode 87", gradle, count=1)
gradle, n3 = re.subn(r"versionName\s+['\"][^'\"]+['\"]", "versionName '12.1.60-ANDROIDDB-ONLINE'", gradle, count=1)
if (n1,n2,n3)!=(1,1,1):
    raise SystemExit("ADMIN_VERSION_METADATA_PATCH_FAILED:" + repr((n1,n2,n3)))
gradle_path.write_text(gradle, encoding="utf-8")

manifest = manifest_path.read_text(encoding="utf-8")
manifest = re.sub(r'android:label="[^"]+"', 'android:label="AniGames Admin V12.1.60 Android DB Online"', manifest, count=1)
manifest_path.write_text(manifest, encoding="utf-8")

# Static release-candidate gates. No Supabase URL/client, stage route, DB1/DB2
# selector, or old local-port default is permitted in any shipped Admin HTML.
for name in ("admin.html","index.html","admin-control.html"):
    page=(web/name).read_text(encoding="utf-8")
    lower=page.lower()
    for forbidden in ("supabase.co","supabase.createclient","sb.schema(","sb.from(","ani-games-db-android-stage-ws-relay","127.0.0.1:8787","127.0.0.1:8788","localhost:8787","DB1_URL","DB2_URL","SB_FUNCTION_URL","SB_KEY"):
        if forbidden.lower() in lower:
            raise SystemExit("FORBIDDEN_ADMIN_BACKEND_REFERENCE:"+name+":"+forbidden)
    if re.search(r"\bsb\.", page, re.I):
        refs=[f"{i+1}:{line.strip()[:220]}" for i,line in enumerate(page.splitlines()) if re.search(r"\bsb\.", line, re.I)]
        raise SystemExit("LEGACY_SUPABASE_CLIENT_REFERENCES:"+name+":"+" || ".join(refs[:30]))
    if "DB_TARGET" in page:
        refs=[f"{i+1}:{line.strip()[:220]}" for i,line in enumerate(page.splitlines()) if "DB_TARGET" in line]
        raise SystemExit("LEGACY_DB_TARGET_REFERENCES:"+name+":"+" || ".join(refs[:30]))
    if ONLINE_API not in page and "ONLINE_GATEWAY_URL" not in page:
        raise SystemExit("ANDROID_DB_ONLINE_GATEWAY_DEFAULT_MISSING:"+name)
    scripts=re.findall(r'<script\b(?![^>]*\bsrc=)[^>]*>(.*?)</script>',page,re.I|re.S)
    if name=="admin.html":
        if len(scripts)!=1: raise SystemExit("ADMIN_INLINE_SCRIPT_COUNT_INVALID")
        Path("/tmp/admin-v1259.js").write_text(scripts[0],encoding="utf-8")
    if name=="index.html" and "localApiBase" not in page:
        raise SystemExit("ADMIN_LOGIN_ENTRY_ANDROID_DB_CONFIG_MISSING")
    if name=="admin-control.html" and "localApiBase" not in page:
        raise SystemExit("ADMIN_CONTROL_ANDROID_DB_CONFIG_MISSING")


# Port the PC Billing V11 cloud sidecar to the same Android DB API.
# This keeps the existing offline-first billing UI and changes only its sync transport.
billing_html_path = web / "billing.html"
cloud_js_path = web / "v11-cloud.js"
if not billing_html_path.is_file() or not cloud_js_path.is_file():
    raise SystemExit("ANDROID_DB_BILLING_ASSETS_MISSING")
billing_html = billing_html_path.read_text(encoding="utf-8")
cloud_ui_anchor = '<div class="form-grid">\n                        <div class="form-group" style="grid-column: 1 / -1;">\n                            <label>Kode Pairing / Enrollment PC</label>'
cloud_api_ui = '''<div class="form-grid">
                        <div class="form-group" style="grid-column: 1 / -1;">
                            <small class="theme-help">Gateway Android DB online dikonfigurasi otomatis. Pairing PC dan sinkronisasi berjalan melalui server online tanpa alamat manual.</small>
                        </div>
                        <div class="form-group" style="grid-column: 1 / -1;">
                            <label>Kode Pairing / Enrollment PC</label>'''
if "id=\"v11-api-base\"" not in billing_html:
    if cloud_ui_anchor not in billing_html:
        raise SystemExit("ANDROID_DB_BILLING_API_UI_ANCHOR_MISSING")
    billing_html = billing_html.replace(cloud_ui_anchor, cloud_api_ui, 1)
billing_html = billing_html.replace("<h3>☁️ Cloud V11</h3>", "<h3>🔗 Android DB</h3>")
billing_html = billing_html.replace("Billing tetap berjalan offline. Saat online, data dan perintah admin disinkronkan otomatis ke cloud.", "Billing tetap berjalan offline. Saat server HTTPS Android DB tersambung, heartbeat, sesi, dan perintah Admin disinkronkan ke database Android.")
billing_html = billing_html.replace("Hubungkan PC ke Cloud", "Hubungkan PC ke Android DB")
billing_html = billing_html.replace("Cek Status Cloud", "Cek Status Android DB")
billing_html = billing_html.replace("Cloud belum dipairing.", "Android DB belum dipairing.")

billing_bridge = r"""
// V11 Android DB bridge: expose the real timer state and execute Admin commands.
window.v11GetActiveCode = () => currentActiveCode || null;
window.v11GetUser = code => dbUsers[String(code || '').trim().toUpperCase()] || null;
window.v11ApplyRemoteCommand = async (command, payload = {}) => {
    const cmd = String(command || '').trim().toLowerCase();
    try {
        if (cmd === 'refresh') {
            setTimeout(() => location.reload(), 1500);
            return {ok:true, message:'Billing page refresh dijadwalkan'};
        }
        if (cmd === 'pause' || cmd === 'stop') {
            const code = currentActiveCode || String(localStorage.getItem('billing_remote_paused_code') || '').trim().toUpperCase();
            if (currentActiveCode) stopActiveSession();
            if (cmd === 'stop' && !code) return {ok:false, error:'NO_ACTIVE_OR_PAUSED_SESSION'};
            return {ok:true, command:cmd, rentalCode:code || null, remainingSeconds:code ? Number(dbUsers[code]?.remainingSeconds) || 0 : 0};
        }
        if (cmd === 'resume') {
            const code = String(localStorage.getItem('billing_remote_paused_code') || '').trim().toUpperCase();
            if (!code || !dbUsers[code]) return {ok:false, error:'NO_PAUSED_RENTAL_ON_PC'};
            const input = document.getElementById('user-code-input');
            if (!input) return {ok:false, error:'BILLING_LOGIN_INPUT_MISSING'};
            input.value = code;
            startSession();
            if (currentActiveCode !== code) return {ok:false, error:'RESUME_REJECTED_BY_BILLING_RULES'};
            localStorage.removeItem('billing_remote_paused_code');
            return {ok:true, command:cmd, rentalCode:code};
        }
        if (cmd === 'logout') {
            const code = currentActiveCode || String(localStorage.getItem('billing_remote_paused_code') || '').trim().toUpperCase();
            if (currentActiveCode) pauseSession(false);
            localStorage.removeItem('billing_remote_paused_code');
            writeSystemLog('Logout Billing diperintahkan oleh Admin Android DB.');
            return {ok:true, command:cmd, rentalCode:code || null, remainingSeconds:code ? Number(dbUsers[code]?.remainingSeconds) || 0 : 0};
        }
        if (cmd === 'restart_billing') {
            if (!window.electronAPI?.restartBilling) return {ok:false, error:'ELECTRON_RESTART_UNAVAILABLE'};
            persistActiveSession(); saveDB(); writeSystemLog('Restart Billing diperintahkan oleh Admin Android DB.');
            setTimeout(() => { try { window.electronAPI.restartBilling(); } catch (_) {} }, 1500);
            return {ok:true, message:'Restart Billing dijadwalkan'};
        }
        if (cmd === 'logoff' || cmd === 'restart_pc' || cmd === 'shutdown') {
            const action = cmd === 'restart_pc' ? 'restart' : cmd;
            if (!window.electronAPI?.powerAction) return {ok:false, error:'ELECTRON_POWER_ACTION_UNAVAILABLE'};
            persistActiveSession(); saveDB(); writeSystemLog('Aksi Windows '+action+' diperintahkan oleh Admin Android DB.');
            await Promise.resolve(window.electronAPI.powerAction(action));
            return {ok:true, command:cmd};
        }
        return {ok:false, error:'UNSUPPORTED_REMOTE_COMMAND', command:cmd};
    } catch (error) {
        return {ok:false, error:String(error?.message || error).slice(0,180), command:cmd};
    }
};
"""
billing_scripts = re.findall(r'(<script\b(?![^>]*\bsrc=)[^>]*>)(.*?)(</script>)', billing_html, re.I | re.S)
if len(billing_scripts) != 1:
    raise SystemExit("BILLING_INLINE_SCRIPT_COUNT_INVALID:" + str(len(billing_scripts)))
def inject_billing_bridge(match):
    return match.group(1) + match.group(2) + "\n" + billing_bridge + "\n" + match.group(3)
billing_html, bridge_count = re.subn(r'(<script\b(?![^>]*\bsrc=)[^>]*>)(.*?)(</script>)', inject_billing_bridge, billing_html, count=1, flags=re.I | re.S)
if bridge_count != 1:
    raise SystemExit("BILLING_REMOTE_COMMAND_BRIDGE_INJECTION_FAILED")
Path("/tmp/billing-v1259.js").write_text(billing_scripts[0][1] + "\n" + billing_bridge, encoding="utf-8")

delete_pattern = re.compile(r"(?ms)^        function deleteUser\(code\)\s*\{.*?^        \}")
delete_replacement = """        function deleteUser(code) {
            if (confirm('Apakah Anda yakin ingin menghapus user ' + code + '?')) {
                delete dbUsers[code];
                try { window.v11DeleteRental?.(code); } catch (_) {}
            }
            saveDB();
            renderUserTable();
        }"""
billing_html, delete_count = delete_pattern.subn(lambda _: delete_replacement, billing_html, count=1)
if delete_count != 1:
    raise SystemExit("BILLING_DELETE_RENTAL_HOOK_ANCHOR_MISSING")

billing_html_path.write_text(billing_html, encoding="utf-8")

cloud_js = r"""(() => {
  const CLOUD_KEY='billing_v11_cloud_config';
  const ONLINE_API_BASE='https://ani-games-db-android-stage-gateway.anigamesready.workers.dev';
  const CLIENT_KEY='billing_v11_client_id';
  const APP='V12.1.60-ANDROID-DB-ONLINE';
  let heartbeatTimer=null,syncBusy=false;
  const read=()=>{try{return JSON.parse(localStorage.getItem(CLOUD_KEY)||'{}')}catch(_){return{}}};
  const save=v=>localStorage.setItem(CLOUD_KEY,JSON.stringify(v||{}));
  const clientId=()=>{let v=localStorage.getItem(CLIENT_KEY);if(!v){v='PC-'+crypto.randomUUID().slice(0,8).toUpperCase();localStorage.setItem(CLIENT_KEY,v)}return v};
  const queue=()=>{try{return JSON.parse(localStorage.getItem('billing_v11_outbox')||'[]')}catch(_){return[]}};
  const saveQueue=q=>localStorage.setItem('billing_v11_outbox',JSON.stringify(q.slice(-1000)));
  const status=t=>{const e=document.getElementById('v11-cloud-status');if(e)e.textContent=t};
  function apiBase(){return ONLINE_API_BASE;}
  async function checkApi(){
    const r=await fetch(apiBase()+'/health',{method:'GET',cache:'no-store'});
    const d=await r.json().catch(()=>({}));
    if(!r.ok||d.api!=='online'||d.database!=='online')throw new Error(d.error||'ANDROID_DB_API_OR_DATABASE_OFFLINE');
    return d;
  }
  async function v11SaveAndroidDbApi(){
    try{
      const h=await checkApi();
      status('ANDROID DB ONLINE • API/database siap • gateway otomatis');
      return h;
    }catch(e){
      status('ANDROID DB BELUM SIAP • '+String(e?.message||e));
      window.showCustomModal?.('Cek server gagal: '+String(e?.message||e),'SERVER ANDROID DB',true,'⚠️');
      return null;
    }
  }
  function setPcState(state,text){
    const b=document.getElementById('pc-state-badge'),d=document.getElementById('pc-state-dot'),e=document.getElementById('pc-state-text');
    if(!b||!e)return;const s=String(state||'pending');b.classList.remove('online','offline','pending');b.classList.add(s);
    e.textContent=text||({online:'STATUS PC: AKTIF',offline:'STATUS PC: OFF / TIDAK TERHUBUNG',pending:'STATUS PC: MENUNGGU KONEKSI'}[s]||'STATUS PC: MENUNGGU KONEKSI');
    if(d)d.setAttribute('aria-label',s);
  }
  window.v11SetPcState=setPcState;
  async function request(path,body){
    const r=await fetch(apiBase()+path,{method:'POST',headers:{'content-type':'application/json'},cache:'no-store',body:JSON.stringify(body||{})});
    const d=await r.json().catch(()=>({}));
    if(!r.ok)throw new Error(d.error||d.message||'ANDROID_DB_HTTP_'+r.status);
    return d;
  }
  function enqueue(ev){
    const q=queue();q.push({...ev,sourceEventId:ev.sourceEventId||crypto.randomUUID(),occurredAt:ev.occurredAt||new Date().toISOString()});
    saveQueue(q);syncNow();
  }
  function enqueueRentalSnapshot(code){
    const c=String(code||'').toUpperCase(),u=window.v11GetUser?.(c);if(!c||!u)return;
    enqueue({eventType:'rental_account_upsert',dataClass:'configuration',code:c,category:u.category||'reguler',
      payload:{source:'pc',remainingSeconds:Math.max(0,Number(u.remainingSeconds)||0),expiryDate:u.expiryDate||'',clientLabel:u.clientLabel||null},
      remainingSeconds:Math.max(0,Number(u.remainingSeconds)||0),expiryDate:u.expiryDate||'',clientLabel:u.clientLabel||null});
  }
  async function syncNow(){
    if(syncBusy)return;const c=read(),q=queue();if(!c.token||!q.length)return;
    syncBusy=true;try{const d=await request('/device/sync',{token:c.token,events:q.slice(0,100)});
      const ok=new Set(d.acceptedSourceEventIds||[]);saveQueue(q.filter(x=>!ok.has(x.sourceEventId)));
      status('ANDROID DB ONLINE • '+ok.size+' event tersinkron');
    }catch(e){status('ANDROID DB OFFLINE • Billing tetap lokal • '+String(e?.message||e));setPcState('offline','STATUS PC: SERVER ANDROID DB TIDAK TERHUBUNG')}
    finally{syncBusy=false}
  }
  async function heartbeat(){
    const c=read();if(!c.token)return;
    try{
      const activeCode=window.v11GetActiveCode?.()||null;
      const pausedCode=String(localStorage.getItem('billing_remote_paused_code')||'').toUpperCase()||null;
      const u=activeCode?window.v11GetUser?.(activeCode):pausedCode?window.v11GetUser?.(pausedCode):null;
      const d=await request('/device/heartbeat',{token:c.token,appVersion:APP,metadata:{
        clientId:c.clientId,activeCode,activeRemainingSeconds:activeCode&&u?Math.max(0,Number(u.remainingSeconds)||0):0,
        pausedCode,pausedRemainingSeconds:pausedCode&&u?Math.max(0,Number(u.remainingSeconds)||0):0,
        activeCategory:u?.category||null,activeExpiryDate:u?.expiryDate||null,activeClientLabel:u?.clientLabel||null
      }});
      status('ANDROID DB ONLINE • '+(d.commands?.length||0)+' perintah • '+new Date().toLocaleTimeString('id-ID'));
      setPcState('online','STATUS PC: AKTIF');
      for(const cmd of d.commands||[]){
        let result;try{result=window.v11ApplyRemoteCommand?await window.v11ApplyRemoteCommand(cmd.command,cmd.payload):{ok:false,message:'Bridge perintah Admin belum tersedia di PC.'}}
        catch(e){result={ok:false,message:e?.message||'Command execution failed'}}
        try{await request('/device/ack',{token:c.token,commandId:cmd.id,status:result.ok?'completed':'failed',result})}catch(_){}
      }
      await syncNow();
    }catch(e){status('ANDROID DB OFFLINE • Billing tetap lokal • '+String(e?.message||e));setPcState('offline','STATUS PC: SERVER ANDROID DB TIDAK TERHUBUNG')}
  }
  function start(){if(heartbeatTimer)clearInterval(heartbeatTimer);heartbeat();heartbeatTimer=setInterval(heartbeat,20000)}
  async function v11EnrollDevice(){
    const input=document.getElementById('v11-enrollment-code'),code=(input?.value||'').trim().toUpperCase();
    if(code.length<6)return window.showCustomModal?.('Masukkan kode pairing dari Admin Android DB.','PAIRING ANDROID DB',true,'🔗');
    try{
      await checkApi();const id=clientId();
      const d=await request('/device/enroll',{code,clientId:id,deviceName:id,appVersion:APP});
      save({token:d.token,deviceId:d.device_id,orgId:d.org_id,clientId:d.client_id||id});
      if(input)input.value='';status('ANDROID DB TERHUBUNG • '+id);start();
      window.showCustomModal?.('PC berhasil dipairing ke database Android.','ANDROID DB TERHUBUNG',false,'✅');
    }catch(e){window.showCustomModal?.('Pairing Android DB gagal: '+e.message,'PAIRING GAGAL',true,'⚠️')}
  }
  async function v11CloudStatus(){
    const c=read();
    try{await checkApi();status(c.token?'ANDROID DB ONLINE • Pairing tersimpan • '+c.clientId:'ANDROID DB ONLINE • Belum dipairing');setPcState(c.token?'pending':'pending',c.token?'STATUS PC: MENUNGGU HEARTBEAT':'STATUS PC: BELUM TERHUBUNG');if(c.token)heartbeat()}
    catch(e){status('ANDROID DB BELUM SIAP • '+String(e?.message||e));setPcState('offline','STATUS PC: SERVER ANDROID DB TIDAK TERHUBUNG')}
  }
  function v11DisconnectDevice(){
    localStorage.removeItem(CLOUD_KEY);if(heartbeatTimer)clearInterval(heartbeatTimer);heartbeatTimer=null;
    status('Pairing Android DB diputus. Billing tetap lokal.');setPcState('pending','STATUS PC: BELUM TERHUBUNG');
  }
  Object.assign(window,{v11EnrollDevice,v11CloudStatus,v11DisconnectDevice,v11SaveAndroidDbApi});
  window.addEventListener('load',()=>{
    if(input)input.value=configured;
    const c=read();
    if(c.token){status('Pairing Android DB tersimpan • '+c.clientId);setPcState('pending','STATUS PC: MENUNGGU HEARTBEAT');start()}
    else{setPcState('pending','STATUS PC: BELUM TERHUBUNG')}
    const wrap=(name,make)=>{
      const original=window[name];if(typeof original!=='function')return;
      window[name]=function(...args){const before=window.v11GetActiveCode?.()||null,r=original.apply(this,args);
        try{const after=window.v11GetActiveCode?.()||null,ev=make(before,after);if(ev)enqueue(ev)}catch(_){}return r};
    };
    wrap('startSession',(b,a)=>{if(a)localStorage.removeItem('billing_remote_paused_code');return a?{eventType:'session_started',dataClass:'usage',category:window.v11GetUser?.(a)?.category||'reguler',code:a,payload:{source:'pc'}}:null});
    wrap('startTenMinuteTest',(b,a)=>a==='__TEST10__'?{eventType:'free_test_started',dataClass:'usage',category:'free_test',code:'__TEST10__',durationSeconds:600,payload:{source:'pc'}}:null);
    wrap('pauseSession',(b)=>{const u=window.v11GetUser?.(b);if(b&&b!=='__TEST10__'&&(Number(u?.remainingSeconds)||0)>0)localStorage.setItem('billing_remote_paused_code',b);else localStorage.removeItem('billing_remote_paused_code');return b?{eventType:'session_ended',dataClass:'usage',code:b,payload:{source:'pc'}}:null});
    wrap('saveUserAdmin',()=>({eventType:'billing_database_changed',dataClass:'transaction',payload:{source:'pc-admin'}}));
    window.v11SyncRental=enqueueRentalSnapshot;
    window.v11DeleteRental=code=>{const value=String(code||'').toUpperCase();if(value)enqueue({eventType:'rental_account_delete',dataClass:'configuration',code:value,payload:{source:'pc'}})};
    setInterval(syncNow,30000);
  });
})();
"""
cloud_js_path.write_text(cloud_js, encoding="utf-8")
# These old icon-directory HTML copies are not referenced by the live WebView. Keep
# image assets intact, but remove obsolete Supabase-backed copies so they cannot be
# loaded accidentally by an alternate path.
icon_dir = web / "icon"
for legacy_name in ("admin.html","admin-control.html","billing.html","index.html","v11-cloud.js"):
    legacy_file = icon_dir / legacy_name
    if legacy_file.exists():
        legacy_file.unlink()
for name in ("billing.html","admin.html","index.html","admin-control.html"):
    page = (web / name).read_text(encoding="utf-8")
    lower = page.lower()
    for forbidden in ("supabase.co","supabase.createclient","sb.schema(","sb.from(","sb.rpc(","ani-games-db-android-stage-ws-relay","127.0.0.1:8787","127.0.0.1:8788","localhost:8787","DB1_URL","DB2_URL","DB_TARGET","SB_FUNCTION_URL","SB_KEY"):
        if forbidden.lower() in lower:
            raise SystemExit("FORBIDDEN_ANDROID_DB_ONLY_HTML_REFERENCE:"+name+":"+forbidden)
cloud = cloud_js_path.read_text(encoding="utf-8")
for forbidden in ("supabase.co","supabase.createclient","sb.schema(","sb.from(","sb.rpc(","SUPABASE","SB_FUNCTION_URL","apikey"):
    if forbidden.lower() in cloud.lower():
        raise SystemExit("FORBIDDEN_ANDROID_DB_ONLY_CLOUD_JS_REFERENCE:"+forbidden)
if "https://"+ "x" in cloud or "/device/sync" not in cloud or "/device/heartbeat" not in cloud or "/device/enroll" not in cloud or "/device/ack" not in cloud:
    raise SystemExit("ANDROID_DB_DEVICE_API_CONTRACT_MISSING")
if "v11GetActiveCode" not in billing_html or "v11ApplyRemoteCommand" not in billing_html:
    raise SystemExit("BILLING_REMOTE_COMMAND_BRIDGE_MISSING")
if 'id="v11-api-base"' in billing_html or "v11SaveAndroidDbApi" not in cloud_js:
    raise SystemExit("ANDROID_DB_API_CONFIGURATION_UI_MISSING")

print("PASS: V12.1.58-derived Admin now routes Admin, WoL relay RPC, and Blynk proxy through Android DB only.")
print("INFO: new app id com.anigames.billingadmin.v160online, versionCode 87, versionName 12.1.60-ANDROIDDB-ONLINE.")
