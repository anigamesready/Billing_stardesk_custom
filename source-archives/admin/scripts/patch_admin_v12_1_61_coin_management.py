#!/usr/bin/env python3
"""Admin v12.1.61: Android-DB-only Coin Management UI and legacy route cleanup.

Run after patch_admin_v12_1_59_android_db_only.py. All financial operations
use authenticated Android DB RPCs. No existing rental-time or stream-settlement
function is changed by this patch.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("usage: patch_admin_v12_1_61_coin_management.py <admin-project-dir>")

root = Path(sys.argv[1]).resolve()
web = root / "android/app/src/main/assets/web"
admin_path = web / "admin.html"
gradle_path = root / "android/app/build.gradle"
manifest_path = root / "android/app/src/main/AndroidManifest.xml"

for path in (admin_path, gradle_path, manifest_path):
    if not path.is_file():
        raise SystemExit("ADMIN_SOURCE_FILE_MISSING:" + str(path))

page = admin_path.read_text(encoding="utf-8")
if "admin_remote_coin_overview" in page:
    raise SystemExit("COIN_ADMIN_UI_ALREADY_PRESENT")
for marker in ("V12.1.52-REMOTE-PLAY-ADMIN-CONTROLS", "V12.1.53-REMOTE-PLAY-SHARED-DB-PORT-8787", "ANI-ADMIN-V12.1.58-CANONICAL-STAGE-GATEWAY"):
    if marker not in page:
        raise SystemExit("EXPECTED_V12158_BASELINE_MARKER_MISSING:" + marker)

def strip_legacy_database_css(css: str) -> str:
    """Remove only CSS rules whose selector targets retired DB panels."""
    removals: list[tuple[int, int]] = []
    i = 0
    while i < len(css):
        open_pos = css.find("{", i)
        if open_pos < 0:
            break
        boundary = max(css.rfind("}", 0, open_pos), css.rfind("{", 0, open_pos))
        selector = css[boundary + 1:open_pos].strip()
        if ".db-switch" in selector.lower() or "#databasetools" in selector.lower():
            depth = 1
            j = open_pos + 1
            while j < len(css) and depth:
                if css[j] == "{":
                    depth += 1
                elif css[j] == "}":
                    depth -= 1
                j += 1
            if depth:
                raise SystemExit("UNBALANCED_ADMIN_CSS_RULE")
            removals.append((boundary + 1, j))
            i = j
        else:
            # Descend into @media/@supports blocks so nested rules are inspected.
            i = open_pos + 1
    for start, end in reversed(removals):
        css = css[:start] + css[end:]
    return css


def remove_div_with_class(source: str, class_name: str) -> str:
    start_tag = re.compile(r"<div\b[^>]*>", re.I)
    close_tag = re.compile(r"</div\s*>", re.I)
    for match in start_tag.finditer(source):
        attrs = match.group(0)
        class_match = re.search(r"""\bclass\s*=\s*["']([^"']*)["']""", attrs, re.I)
        if not class_match or class_name not in class_match.group(1).split():
            continue
        depth = 1
        for token in re.finditer(r"</?div\b[^>]*>", source[match.end():], re.I):
            if token.group(0).startswith("</"):
                depth -= 1
            else:
                depth += 1
            if depth == 0:
                end = match.end() + token.end()
                return source[:match.start()] + source[end:]
        raise SystemExit("UNBALANCED_DIV_CLASS:" + class_name)
    return source

# Remove the actual obsolete database switch node, not merely hide it with CSS.
page = remove_div_with_class(page, "db-switch")
legacy_hide_comment = "/* DB Android branch: legacy Supabase DB1/DB2 route UI is intentionally unavailable. */"
if legacy_hide_comment not in page:
    raise SystemExit("EXPECTED_LEGACY_DB_HIDE_COMMENT_NOT_FOUND")
hide_start = page.index(legacy_hide_comment)
hide_end = page.find("}", hide_start)
if hide_end < 0:
    raise SystemExit("EXPECTED_LEGACY_DB_HIDE_RULE_END_NOT_FOUND")
page = page[:hide_start] + page[hide_end + 1:]
# Remove only obsolete CSS rules, scoped to each style element. Never run a
# page-wide brace regex: that can consume markup and JavaScript after a CSS rule.
style_pattern = re.compile(r"(?is)(<style\b[^>]*>)(.*?)(</style>)")
page, style_count = style_pattern.subn(
    lambda m: m.group(1) + strip_legacy_database_css(m.group(2)) + m.group(3),
    page
)
if style_count < 1:
    raise SystemExit("ADMIN_STYLE_BLOCKS_NOT_FOUND")
page = page.replace("function openDbSelector(){requestGlobalDbSwitch()} ", "")
page = page.replace("function openDbSelector(){requestGlobalDbSwitch()}", "")
# Remove only the retired databaseTools interception from the mobile tab wrapper.
legacy_tab_intercept = "if(id==='databaseTools'){msg('Konfigurasi Android DB tidak tersedia pada cabang DB Android.',true);return;}"
if legacy_tab_intercept not in page:
    raise SystemExit("LEGACY_DATABASE_TOOLS_TAB_INTERCEPT_NOT_FOUND")
page = page.replace(legacy_tab_intercept, "", 1)
page = page.replace("Database aktif seluruh sistem:", "Database Android aktif:")
page = page.replace("Memeriksa route-control DB1/DB2…", "Menggunakan satu Android DB…")
page = page.replace("DB1 • Utama", "Android DB")
page = page.replace("Pastikan DB2 sudah menerima migrasi SQL pemulihan jika DB2 digunakan.", "Pastikan Android DB gateway dan migrasi pemulihan sudah aktif.")
page = page.replace("pada database yang sedang dipilih", "pada Android DB")
page = page.replace("di database yang sedang dipilih", "di Android DB")
page = page.replace("pada proyek Supabase DB tersebut", "pada Android DB")
page = page.replace("database lokal Ani Games Ready", "Android DB Ani Games Ready")
page = page.replace("Token Blynk belum diatur pada Supabase Secret BLYNK_AUTH_TOKEN.", "Token Blynk belum dikonfigurasi pada Android DB Gateway.")
page = page.replace("Koneksi ke Supabase gagal; perintah belum dapat diverifikasi.", "Koneksi ke Android DB Gateway gagal; perintah belum dapat diverifikasi.")
page = page.replace("Relay Supabase", "relay notifikasi")
page = page.replace("Supabase login", "relay authentication")

# Add the Coin menu in the existing Admin sidebar, replacing the retired
# placeholder StarDesk settings card with a functional Coin + device mapping page.
nav_anchor = '<button data-tab="stardesk" onclick="tab(\'stardesk\')">⚙️ StarDesk</button>'
nav_replacement = '<button id="coinManagementNav" data-tab="coinManagement" onclick="tab(\'coinManagement\')">🪙 Coin & StarDesk</button>'
if page.count(nav_anchor) != 1:
    raise SystemExit("ADMIN_SIDEBAR_STARDESK_ANCHOR_MISMATCH")
page = page.replace(nav_anchor, nav_replacement, 1)
role_ui_anchor = "function applyRemotePlayRoleUI(){const nav=$('remotePlayAdminNav');if(nav)nav.classList.toggle('hidden',!isRemotePlayOwner());}"
role_ui_next = "function applyRemotePlayRoleUI(){const allowed=isRemotePlayOwner(),nav=$('remotePlayAdminNav'),coin=$('coinManagementNav');if(nav)nav.classList.toggle('hidden',!allowed);if(coin)coin.classList.toggle('hidden',!allowed);}"
if page.count(role_ui_anchor) != 1:
    raise SystemExit("ADMIN_REMOTE_PLAY_ROLE_UI_ANCHOR_MISMATCH")
page = page.replace(role_ui_anchor, role_ui_next, 1)

old_stardesk = re.compile(r'<section id="stardesk" class="section">.*?</section>', re.I | re.S)
page, stardesk_count = old_stardesk.subn("", page, count=1)
if stardesk_count != 1:
    raise SystemExit("OLD_STAR_DESK_PLACEHOLDER_SECTION_MISSING")

coin_section = """<section id="coinManagement" class="section">
 <div class="card" style="margin-top:12px">
  <div class="top"><div><h2 style="margin:0">🪙 Coin Management</h2><div class="muted">Top-up, saldo, masa berlaku coin, tarif GPU, dan identitas perangkat StarDesk. Semua transaksi melalui satu Android DB.</div></div><button class="primary" type="button" onclick="loadCoinAdmin()">↻ Refresh</button></div>
  <div id="coinAdminStatus" class="msg" role="status" aria-live="polite" style="margin-top:10px">Tekan Refresh untuk membaca data Coin dari Android DB.</div>
  <div class="cards2" style="margin-top:12px">
   <div class="card"><div class="label">Top-up Menunggu</div><div class="stat" id="coinPendingCount">—</div><div class="muted" id="coinPendingAmount">Nominal menunggu: —</div></div>
   <div class="card"><div class="label">Top-up Disetujui</div><div class="stat" id="coinApprovedCount">—</div><div class="muted">Transaksi terkonfirmasi</div></div>
   <div class="card"><div class="label">Top-up Ditolak / Kedaluwarsa</div><div class="stat" id="coinRejectedCount">—</div><div class="muted">Tidak menambah saldo</div></div>
   <div class="card"><div class="label">Wallet Pengguna</div><div class="stat" id="coinWalletCount">—</div><div class="muted">Akun yang memiliki wallet</div></div>
  </div>
 </div>
 <div class="card" style="margin-top:12px">
  <div class="top"><div><h3 style="margin:0">💳 Permintaan Top-up</h3><div class="muted">Periksa bukti pembayaran melalui kanal pembayaran. Approve hanya setelah pembayaran benar-benar diterima.</div></div></div>
  <div class="table-wrap"><table><thead><tr><th>User ID</th><th>Nominal</th><th>Coin</th><th>Masa Lot</th><th>Status</th><th>Dibuat</th><th>Aksi</th></tr></thead><tbody id="coinTopupRows"><tr><td colspan="7" class="empty">Tekan Refresh.</td></tr></tbody></table></div>
 </div>
 <div class="card" style="margin-top:12px">
  <div class="top"><div><h3 style="margin:0">🖥 Tarif GPU & Pemetaan StarDesk</h3><div class="muted">Setiap PC memiliki satu tarif. Pastikan Device ID StarDesk cocok dengan PC fisik yang benar sebelum dipakai.</div></div></div>
  <div class="table-wrap"><table><thead><tr><th>PC</th><th>Status PC</th><th>GPU / Tarif</th><th>StarDesk Device ID</th><th>Mapping aktif</th><th>Aksi</th></tr></thead><tbody id="coinDeviceRows"><tr><td colspan="6" class="empty">Tekan Refresh.</td></tr></tbody></table></div>
 </div>
 <div class="card" style="margin-top:12px">
  <div class="top"><div><h3 style="margin:0">👤 Wallet Rental & Riwayat</h3><div class="muted">Baca saldo yang dapat dipakai, lot beserta kedaluwarsa, riwayat ledger, dan top-up per akun.</div></div></div>
  <div class="row" style="margin-top:10px"><select id="coinWalletRental" aria-label="Pilih akun rental untuk detail wallet" style="flex:1;min-width:180px"><option value="">Pilih akun rental…</option></select><button class="primary" type="button" onclick="loadCoinAdminWallet()">Tampilkan Wallet</button></div>
  <div id="coinWalletStatus" class="msg" role="status" aria-live="polite" style="margin-top:10px">Pilih akun untuk melihat detail wallet.</div>
  <div class="cards2" style="margin-top:10px"><div class="card"><div class="label">Saldo Dapat Dipakai</div><div class="stat" id="coinWalletBalance">—</div></div><div class="card"><div class="label">Lot Aktif</div><div class="stat" id="coinWalletLotCount">—</div></div></div>
  <h4>Lot Coin & Kedaluwarsa</h4>
  <div class="table-wrap"><table><thead><tr><th>Dibuat</th><th>Coin Awal</th><th>Sisa</th><th>Kedaluwarsa</th><th>Status</th></tr></thead><tbody id="coinWalletLotRows"><tr><td colspan="5" class="empty">Belum memilih akun.</td></tr></tbody></table></div>
  <h4>Ledger Transaksi</h4>
  <div class="table-wrap"><table><thead><tr><th>Waktu</th><th>Jenis</th><th>Jumlah</th><th>Saldo Setelah</th><th>Referensi</th></tr></thead><tbody id="coinWalletLedgerRows"><tr><td colspan="5" class="empty">Belum memilih akun.</td></tr></tbody></table></div>
 </div>
</section>
"""
account_anchor = '<section id="accounts" class="section">'
if page.count(account_anchor) != 1:
    raise SystemExit("ADMIN_RENTAL_SECTION_INSERTION_ANCHOR_MISMATCH")
page = page.replace(account_anchor, coin_section + account_anchor, 1)

# Add a role-gated loader to the existing sidebar router. No new auth path or
# storage is introduced: rpc() uses the existing Android DB Admin access token.
tab_pattern = re.compile(r"(?ms)^function tab\(id\)\{.*?^\}")
tab_fn = """function tab(id){
 if((id==='pairing'||id==='remotePlay'||id==='coinManagement')&&!isRemotePlayOwner())return;
 document.querySelectorAll('.section').forEach(x=>x.classList.remove('active'));
 const section=$(id);if(!section)return;
 section.classList.add('active');
 document.querySelectorAll('.nav button').forEach(x=>x.classList.toggle('active',x.dataset.tab===id));
 if(id==='pairing')applyPairingRoleUI();
 if(id==='devices')loadDevices();
 if(id==='accounts')loadGlobalRentalAccounts();
 if(id==='reports')loadReport();
 if(id==='billingUsers')loadBillingUsers().then(()=>bindBillingUserActions());
 if(id==='remotePlay')loadRemotePlayAdmin();
 if(id==='coinManagement')loadCoinAdmin();
}"""
page, tab_count = tab_pattern.subn(lambda _: tab_fn, page, count=1)
if tab_count != 1:
    raise SystemExit("ADMIN_TAB_ROUTER_REPLACEMENT_FAILED")

coin_js = r"""
// V12.1.61-ANDROIDDB-COIN-MANAGEMENT — owner-only Admin controls.
let coinAdminOverview=null,coinAdminRentalRows=[];
function coinAdminOwner(){return typeof isRemotePlayOwner==='function'&&isRemotePlayOwner()===true;}
function coinAdminUuid(value){const id=String(value||'');return /^[0-9a-f-]{36}$/i.test(id)?id:'';}
function coinAdminDate(value){if(!value)return '-';const d=new Date(value);return Number.isNaN(d.getTime())?'-':d.toLocaleString('id-ID');}
function coinAdminScale(){return Math.max(1,Number(coinAdminOverview?.coin_unit_scale)||1);}
function coinAdminNumber(value){const n=Number(value);return Number.isFinite(n)?n:0;}
function coinAdminCoin(value){return new Intl.NumberFormat('id-ID',{maximumFractionDigits:4}).format(coinAdminNumber(value)/coinAdminScale());}
function coinAdminMoney(value){return 'Rp '+new Intl.NumberFormat('id-ID',{maximumFractionDigits:0}).format(coinAdminNumber(value));}
function coinAdminMessage(message,bad=false){const el=$('coinAdminStatus');if(!el)return;el.textContent=String(message||'');el.style.borderLeftColor=bad?'#ff4d6d':'var(--a)';}
function coinWalletMessage(message,bad=false){const el=$('coinWalletStatus');if(!el)return;el.textContent=String(message||'');el.style.borderLeftColor=bad?'#ff4d6d':'var(--a)';}
function coinAdminRateOptions(selected){const classes=['GTX 1050','GTX 1660','RTX 3060','RTX 5060'];return '<option value="">Pilih GPU…</option>'+classes.map(x=>'<option value="'+x+'" '+(x===selected?'selected':'')+'>'+x+'</option>').join('');}
function renderCoinAdmin(data){
 const summary=data.summary||{},scale=Math.max(1,Number(data.coin_unit_scale)||1);
 $('coinPendingCount').textContent=String(summary.pending_orders||0);
 $('coinPendingAmount').textContent='Nominal menunggu: '+coinAdminMoney(summary.pending_amount_rupiah||0);
 $('coinApprovedCount').textContent=String(summary.approved_orders||0);
 $('coinRejectedCount').textContent=String((summary.rejected_orders||0)+' / '+(summary.expired_orders||0));
 $('coinWalletCount').textContent=String(summary.wallet_accounts||0);
 const orders=Array.isArray(data.orders)?data.orders:[];
 $('coinTopupRows').innerHTML=orders.map(o=>{
  const id=coinAdminUuid(o.id);if(!id)return '';
  const pending=o.status==='pending';
  const actions=pending?'<button class="mini primary" onclick="approveCoinTopup(\''+id+'\')">Approve</button> <button class="mini danger" onclick="rejectCoinTopup(\''+id+'\')">Reject</button>':'—';
  return '<tr><td><b>'+esc(o.rental_code||'-')+'</b><div class="muted">'+esc(o.client_label||'-')+'</div></td><td>'+coinAdminMoney(o.amount_rupiah)+'</td><td>'+coinAdminCoin(o.coin_amount)+'</td><td>'+esc(o.expiry_days||0)+' hari</td><td><span class="pill '+(pending?'warn':o.status==='approved'?'online':'offline')+'">'+esc(String(o.status||'-').toUpperCase())+'</span></td><td>'+coinAdminDate(o.created_at)+'</td><td>'+actions+'</td></tr>';
 }).join('')||'<tr><td colspan="7" class="empty">Belum ada permintaan top-up.</td></tr>';
 const devices=Array.isArray(data.devices)?data.devices:[];
 $('coinDeviceRows').innerHTML=devices.map(d=>{
  const id=coinAdminUuid(d.device_id);if(!id)return '';
  const rateClass=String(d.gpu_class||'');
  const starId=String(d.stardesk_device_id||'');
  const status=String(d.status||'offline').toLowerCase();
  const online=status==='online';
  const rate=d.rate_enabled?esc(rateClass)+' • '+coinAdminMoney(d.hourly_rupiah)+'/jam • '+coinAdminCoin(d.hourly_coins)+' coin/jam':'Belum diatur';
  return '<tr><td><b>'+esc(d.device_name||'-')+'</b><div class="muted">'+esc(d.client_id||'-')+'</div></td><td><span class="pill '+(online?'online':'offline')+'">'+esc(status.toUpperCase())+'</span></td><td><select id="coinGpu_'+id+'" aria-label="Tarif GPU '+esc(d.device_name||'PC')+'">'+coinAdminRateOptions(rateClass)+'</select><div class="muted">'+rate+'</div></td><td><input id="coinStarDesk_'+id+'" maxlength="180" value="'+esc(starId)+'" placeholder="StarDesk Device ID" aria-label="StarDesk Device ID"></td><td><label><input id="coinMapEnabled_'+id+'" type="checkbox" '+(d.stardesk_link_enabled?'checked':'')+'> Aktif</label><div class="muted">'+(d.stardesk_link_enabled?'Terhubung':'Belum aktif')+'</div></td><td><div class="row"><button class="mini primary" onclick="saveCoinGpuRate(\''+id+'\')">Simpan Tarif</button><button class="mini" onclick="saveCoinStarDeskLink(\''+id+'\')">Simpan ID</button></div></td></tr>';
 }).join('')||'<tr><td colspan="6" class="empty">Belum ada PC pada workspace.</td></tr>';
 const select=$('coinWalletRental'),previous=select.value;
 select.innerHTML='<option value="">Pilih akun rental…</option>'+coinAdminRentalRows.map(r=>'<option value="'+esc(r.id)+'">'+esc(r.code||'-')+' • '+esc(r.client_label||r.category||'-')+'</option>').join('');
 if(coinAdminRentalRows.some(r=>String(r.id)===previous))select.value=previous;
}
async function loadCoinAdmin(){
 if(!coinAdminOwner()){coinAdminMessage('Menu Coin hanya untuk Master/Owner.',true);return null;}
 if(!currentOrg?.id){coinAdminMessage('Workspace belum dipilih. Pilih workspace lalu buka ulang Coin Management.',true);return null;}
 coinAdminMessage('Membaca top-up, tarif GPU, mapping StarDesk, dan wallet dari Android DB…');
 $('coinTopupRows').innerHTML='<tr><td colspan="7" class="empty">Memuat data dari Android DB…</td></tr>';
 $('coinDeviceRows').innerHTML='<tr><td colspan="6" class="empty">Memuat daftar PC…</td></tr>';
 try{
  const overview=await rpc('admin_remote_coin_overview',{p_limit:200});
  if(!overview||overview.ok!==true||!Array.isArray(overview.orders)||!Array.isArray(overview.devices)||!Array.isArray(overview.rentals)||!overview.summary)throw new Error('Respons Coin Overview dari Android DB tidak lengkap.');
  coinAdminOverview=overview;coinAdminRentalRows=overview.rentals;
  renderCoinAdmin(overview);
  coinAdminMessage('Data berhasil diperbarui dari Android DB • '+coinAdminDate(overview.server_time),false);
  return overview;
 }catch(e){
  coinAdminMessage('Gagal memuat Coin Management: '+String(e?.message||e||'unknown error').slice(0,180),true);
  $('coinTopupRows').innerHTML='<tr><td colspan="7" class="empty">Data tidak dapat diverifikasi. Coba Refresh.</td></tr>';
  $('coinDeviceRows').innerHTML='<tr><td colspan="6" class="empty">Data tidak dapat diverifikasi. Coba Refresh.</td></tr>';
  return null;
 }
}
async function approveCoinTopup(orderId){
 if(!coinAdminOwner())return coinAdminMessage('Hanya Master/Owner yang dapat menyetujui top-up.',true);
 const id=coinAdminUuid(orderId);if(!id)return;
 if(!confirm('Pastikan pembayaran untuk order ini sudah benar-benar diterima. Setujui dan tambahkan coin ke wallet?'))return;
 try{
  const result=await rpc('admin_remote_coin_approve_topup',{p_order_id:id});
  if(result?.ok!==true||result.status!=='approved')throw new Error('Android DB tidak mengonfirmasi approval.');
  coinAdminMessage(result.idempotent?'Order sudah pernah disetujui; tidak ada kredit ganda.':'Top-up disetujui dan dicatat ke wallet.',false);
  await loadCoinAdmin();
 }catch(e){coinAdminMessage('Approve gagal: '+String(e?.message||e).slice(0,180),true);}
}
async function rejectCoinTopup(orderId){
 if(!coinAdminOwner())return coinAdminMessage('Hanya Master/Owner yang dapat menolak top-up.',true);
 const id=coinAdminUuid(orderId);if(!id)return;
 const reason=prompt('Alasan penolakan top-up (wajib diisi):','Bukti pembayaran belum valid');
 if(reason===null)return;
 if(!String(reason).trim())return coinAdminMessage('Alasan penolakan wajib diisi.',true);
 try{
  const result=await rpc('admin_remote_coin_reject_topup',{p_order_id:id,p_reason:String(reason).trim().slice(0,180)});
  if(result?.ok!==true||result.status!=='rejected')throw new Error('Android DB tidak mengonfirmasi penolakan.');
  coinAdminMessage('Top-up ditolak. Wallet tidak menerima coin.',false);
  await loadCoinAdmin();
 }catch(e){coinAdminMessage('Reject gagal: '+String(e?.message||e).slice(0,180),true);}
}
async function saveCoinGpuRate(deviceId){
 if(!coinAdminOwner())return coinAdminMessage('Hanya Master/Owner yang dapat mengubah tarif.',true);
 const id=coinAdminUuid(deviceId);if(!id)return;
 const gpu=$('coinGpu_'+id)?.value||'';
 if(!gpu)return coinAdminMessage('Pilih kelas GPU sebelum menyimpan tarif.',true);
 try{
  const result=await rpc('admin_remote_coin_set_device_rate',{p_device_id:id,p_gpu_class:gpu});
  if(result?.ok!==true||result.enabled!==true)throw new Error('Android DB tidak mengonfirmasi tarif baru.');
  coinAdminMessage('Tarif '+gpu+' disimpan untuk PC ini.',false);
  await loadCoinAdmin();
 }catch(e){coinAdminMessage('Gagal menyimpan tarif: '+String(e?.message||e).slice(0,180),true);}
}
async function saveCoinStarDeskLink(deviceId){
 if(!coinAdminOwner())return coinAdminMessage('Hanya Master/Owner yang dapat mengubah mapping StarDesk.',true);
 const id=coinAdminUuid(deviceId);if(!id)return;
 const starId=String($('coinStarDesk_'+id)?.value||'').trim();
 const enabled=$('coinMapEnabled_'+id)?.checked===true;
 if(!starId||starId.length>180)return coinAdminMessage('StarDesk Device ID wajib diisi (maksimal 180 karakter).',true);
 try{
  const result=await rpc('admin_remote_coin_link_stardesk_device',{p_device_id:id,p_stardesk_device_id:starId,p_enabled:enabled});
  if(result?.ok!==true||result.enabled!==enabled)throw new Error('Android DB tidak mengonfirmasi mapping.');
  coinAdminMessage(enabled?'Mapping StarDesk PC berhasil diaktifkan.':'Mapping StarDesk PC dinonaktifkan.',false);
  await loadCoinAdmin();
 }catch(e){coinAdminMessage('Gagal menyimpan mapping: '+String(e?.message||e).slice(0,180),true);}
}
async function loadCoinAdminWallet(){
 if(!coinAdminOwner())return coinWalletMessage('Hanya Master/Owner yang dapat membaca wallet detail.',true);
 const rentalId=coinAdminUuid($('coinWalletRental')?.value);
 if(!rentalId)return coinWalletMessage('Pilih akun rental yang valid.',true);
 for(const id of ['coinWalletLotRows','coinWalletLedgerRows'])$(id).innerHTML='<tr><td colspan="5" class="empty">Memuat dari Android DB…</td></tr>';
 coinWalletMessage('Membaca saldo dan histori wallet dari Android DB…');
 try{
  const data=await rpc('admin_remote_coin_wallet',{p_rental_account_id:rentalId,p_history_limit:100});
  if(!data||data.ok!==true||!data.wallet||!Array.isArray(data.lots)||!Array.isArray(data.ledger)||!Array.isArray(data.orders))throw new Error('Respons wallet dari Android DB tidak lengkap.');
  const account=data.rental_account||{},scale=Math.max(1,Number(data.coin_unit_scale)||1);
  $('coinWalletBalance').textContent=coinAdminCoin(data.wallet.balance);
  const activeLots=data.lots.filter(x=>!x.expired&&coinAdminNumber(x.remaining_coins)>0);
  $('coinWalletLotCount').textContent=String(activeLots.length);
  $('coinWalletLotRows').innerHTML=data.lots.map(x=>'<tr><td>'+coinAdminDate(x.created_at)+'</td><td>'+new Intl.NumberFormat('id-ID',{maximumFractionDigits:4}).format(coinAdminNumber(x.original_coins)/scale)+'</td><td>'+new Intl.NumberFormat('id-ID',{maximumFractionDigits:4}).format(coinAdminNumber(x.remaining_coins)/scale)+'</td><td>'+coinAdminDate(x.expires_at)+'</td><td><span class="pill '+(x.expired?'offline':'online')+'">'+(x.expired?'KEDALUWARSA':'AKTIF')+'</span></td></tr>').join('')||'<tr><td colspan="5" class="empty">Belum ada lot coin.</td></tr>';
  $('coinWalletLedgerRows').innerHTML=data.ledger.map(x=>'<tr><td>'+coinAdminDate(x.created_at)+'</td><td>'+esc(x.event_type||'-')+'</td><td>'+new Intl.NumberFormat('id-ID',{maximumFractionDigits:4}).format(coinAdminNumber(x.amount_coins)/scale)+'</td><td>'+new Intl.NumberFormat('id-ID',{maximumFractionDigits:4}).format(coinAdminNumber(x.balance_after)/scale)+'</td><td>'+esc(x.reference_type||'-')+'<div class="muted">'+esc(x.reference_id||'-')+'</div></td></tr>').join('')||'<tr><td colspan="5" class="empty">Belum ada transaksi.</td></tr>';
  coinWalletMessage('Wallet '+String(account.code||'-')+' • status '+String(account.status||'-')+' • saldo dan histori dibaca dari Android DB.');
 }catch(e){
  $('coinWalletBalance').textContent='—';$('coinWalletLotCount').textContent='—';
  $('coinWalletLotRows').innerHTML='<tr><td colspan="5" class="empty">Wallet tidak dapat diverifikasi.</td></tr>';
  $('coinWalletLedgerRows').innerHTML='<tr><td colspan="5" class="empty">Ledger tidak dapat diverifikasi.</td></tr>';
  coinWalletMessage('Gagal membaca wallet: '+String(e?.message||e).slice(0,180),true);
 }
}
"""
# Keep the new Coin handlers inside the existing Admin WebView script.
# Function declarations remain available to the HTML action handlers, and no
# existing login/navigation/core script is split or rewritten.
inline_scripts = list(re.finditer(r'<script\b(?![^>]*\bsrc=)[^>]*>.*?</script>', page, re.I | re.S))
if len(inline_scripts) != 1:
    raise SystemExit("ADMIN_INLINE_SCRIPT_BOUNDARY_INVALID:" + str(len(inline_scripts)))
inline_end = inline_scripts[0].end() - len("</script>")
page = page[:inline_end] + "\n" + coin_js + page[inline_end:]

# Restore password recovery visibility; its own hidden class controls state.
page = page.replace(",#recovery{display:none!important}", "")
page = page.replace("#recovery{display:none!important}", "")
page = page.replace("button[onclick*=\"databaseTools\"]", "")
# Keep all remaining dual-route UI identifiers out of the produced HTML.
for forbidden in ("globalDbTarget", "requestGlobalDbSwitch", "DB1", "DB2", "databaseTools", "dualDbReadinessPanel", "startDualDbAdmin"):
    if forbidden.lower() in page.lower():
        raise SystemExit("LEGACY_DUAL_DATABASE_HTML_REMAINS:" + forbidden)
# Blynk relay authentication remains a sidecar; user-facing errors must not
# imply it is a second database or ask operators to configure Supabase DBs.
for forbidden in ("Supabase DB", "Supabase Secret", "Koneksi ke Supabase", "Pastikan DB2", "route-control DB1", "DB1/DB2"):
    if forbidden.lower() in page.lower():
        raise SystemExit("LEGACY_DATABASE_COPY_REMAINS:" + forbidden)

admin_path.write_text(page, encoding="utf-8")

# Candidate package is unique so installing it cannot overwrite the selected
# 12.1.58 SAFE-TEST baseline.
gradle = gradle_path.read_text(encoding="utf-8")
gradle, n1 = re.subn(r"applicationId\s+['\"][^'\"]+['\"]", "applicationId 'com.anigames.billingadmin.v161online'", gradle, count=1)
gradle, n2 = re.subn(r"versionCode\s+\d+", "versionCode 88", gradle, count=1)
gradle, n3 = re.subn(r"versionName\s+['\"][^'\"]+['\"]", "versionName '12.1.61-ANDROIDDB-COIN'", gradle, count=1)
if (n1,n2,n3)!=(1,1,1):
    raise SystemExit("ADMIN_V12161_VERSION_METADATA_PATCH_FAILED:" + repr((n1,n2,n3)))
gradle_path.write_text(gradle, encoding="utf-8")

manifest = manifest_path.read_text(encoding="utf-8")
manifest, n = re.subn(r'android:label="[^"]+"', 'android:label="AniGames Admin V12.1.61 Android DB Coin"', manifest, count=1)
if n != 1:
    raise SystemExit("ADMIN_V12161_MANIFEST_LABEL_PATCH_FAILED")
manifest_path.write_text(manifest, encoding="utf-8")

# Final static requirements and JS syntax source.
scripts = re.findall(r'<script\b(?![^>]*\bsrc=)[^>]*>(.*?)</script>', page, re.I | re.S)
if len(scripts) != 1:
    raise SystemExit("ADMIN_V12161_INLINE_SCRIPT_COUNT_INVALID:" + str(len(scripts)))
Path("/tmp/admin-v1261-check.js").write_text(scripts[0], encoding="utf-8")
for required in ("coinManagement", "admin_remote_coin_overview", "admin_remote_coin_wallet",
                 "admin_remote_coin_approve_topup", "admin_remote_coin_reject_topup",
                 "admin_remote_coin_set_device_rate", "admin_remote_coin_link_stardesk_device",
                 "function approveCoinTopup", "function loadCoinAdminWallet",
                 "coin_unit_scale"):
    if required not in page:
        raise SystemExit("ADMIN_V12161_FEATURE_WIRING_MISSING:" + required)
for forbidden in ("globalDbTarget", "requestGlobalDbSwitch", "DB1", "DB2",
                  "databaseTools", "dualDbReadinessPanel", "startDualDbAdmin",
                  "supabase.co", "supabase.createClient", "sb.from(", "sb.rpc(",
                  "DB1_URL", "DB2_URL", "DB_TARGET", "SB_FUNCTION_URL", "SB_KEY"):
    if forbidden.lower() in page.lower():
        raise SystemExit("ADMIN_V12161_FORBIDDEN_REFERENCE:" + forbidden)
if 'id="recovery"' not in page:
    raise SystemExit("ADMIN_PASSWORD_RECOVERY_PANEL_MISSING")
if '#recovery{display:none!important}' in page:
    raise SystemExit("ADMIN_PASSWORD_RECOVERY_STILL_HIDDEN")
print("PASS: Admin v12.1.61 Coin UI, Android DB RPCs, wallet detail, GPU/StarDesk mapping, single-DB cleanup, and password-recovery visibility.")
