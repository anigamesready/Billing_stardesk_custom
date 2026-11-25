# Audit Integrasi StarDesk Remote Android + Admin + Host Agent
Tanggal: 25 November 2026

## Status keputusan
**Belum sinkron penuh dan belum layak mengaktifkan Connect/Coin billing.** Source Remote dan Admin sudah memiliki jalur RPC yang cocok untuk login, wallet, top-up, dan Admin Coin; database Android aktif dan koneksi relay Termux belum dapat diverifikasi dari lingkungan audit. Jalur mulai/berhenti streaming StarDesk serta pemotongan Coin per sesi belum tersedia.

Tidak ada perubahan pada branch `main`, APK stabil, Admin/Billing master, database aktif, atau installer StarDesk Desktop 1.6.0.

## Source yang diaudit
- Repo utama: `anigamesready/Billing_stardesk_custom`
- Remote Android: `feature/remote-auto-url-coin-ui-20261125` — `8eb15a8e70311ef9f4a5393a20a77dde04fedf5c`
- Admin Coin: `feature/admin-androiddb-coin-api-20261125` — `1ef65a182d6f003573a37285d2a3aef95d93ef12`
- Perbaikan audit terisolasi: `feature/stardesk-agent-integration-audit-20261125`
- Branch `main` tetap tidak diubah.

## Kecocokan fungsi Remote dan Admin

| Bagian | Remote Android | Admin | Backend Android DB | Hasil |
|---|---|---|---|---|
| Login | User ID + aktivasi pertama; refresh token | Admin username/password dan token | RPC auth terpisah | Kontrak jalur login terpisah, bukan saling berbagi token |
| Dashboard Coin | `remote_coin_dashboard` | — | RPC wallet/host summary | Nama dan route cocok |
| Wallet/riwayat | `remote_coin_wallet`, `remote_coin_history` | `admin_remote_coin_wallet` | Migrasi 020/023 | Cocok pada source |
| Order top-up | `remote_coin_create_topup` | `admin_remote_coin_topups`, approve/reject | Migrasi 020 | Cocok pada source |
| Tarif GPU | Menampilkan tarif dari dashboard | `admin_remote_coin_set_device_rate` | Tabel `pc_coin_rates` | Cocok pada source |
| Mapping StarDesk | Menampilkan mapping | `admin_remote_coin_link_stardesk_device` | Tabel `stardesk_device_links` | Cocok pada source |
| Connect | Tombol sengaja dikunci | Admin dapat mengatur izin/mapping | Belum ada Coin-session start/settle | Belum tersambung |
| Status host nyata | Saat ini memakai status `public.devices` | Menu Host lama memakai model Sunshine | Heartbeat host lama | Belum cukup untuk status StarDesk |
| Potong Coin | Belum dipanggil | Belum ada kontrol sesi Coin | Tidak ada RPC/ledger settlement sesi Coin | Belum tersedia |

### Pengaman yang ditemukan
- UI Android memeriksa status akun dan tanggal kedaluwarsa.
- Fungsi lama `api.remote_coin_dashboard(text)` pada migrasi 020 hanya menolak `disabled/deleted/inactive`, tetapi tidak menolak `expired`, tanggal kedaluwarsa di masa lalu, atau tanggal expiry kosong. Itu celah otorisasi server-side.
- Source lama punya `remote_play.sessions` dan settlement berbasis detik rental. Settlement tersebut **tidak boleh dipakai** untuk Coin karena saldo waktu rental akan ikut terpotong.
- Daftar PC pada dashboard Coin menghitung ketersediaan dari status perangkat Billing, izin Host, rate, mapping, dan sesi lama. Ia belum mensyaratkan heartbeat Agent StarDesk yang valid, sehingga status READY bisa menjadi false-positive.
- `remote_play_host_heartbeat` menyimpan `sunshine_ready`; itu kontrak Host versi Sunshine/Moonlight, bukan bukti stream StarDesk.

## Perubahan audit yang sudah dibuat di branch terisolasi
1. Tambah `backend/android-db/migrations/024_remote_coin_expiry_guard.sql`. Dashboard Coin kini mengharuskan saldo positif, status bukan disabled/deleted/inactive/expired, expiry terisi dan masih di masa depan, serta tidak ada sesi terbuka. Fungsi diberi marker `ani_remote_coin_expiry_guard_v1`.
2. Perbaiki test `015_remote_coin_wallet_smoke.sql`: akun expired/past expiry harus ditolak; akun active dengan expiry future dapat lolos gate; sesudah expired kembali, gate harus menolak.
3. Perbarui installer Termux untuk memasang migrasi 023 (dua RPC baca Admin Coin) dan 024 pada instalasi baru maupun jalur upgrade core-only. Installer mengecek kedua RPC Admin dan marker expiry guard, serta tetap meminta backup tervalidasi dan konfirmasi APPLY pada database lama.
4. Perbarui dokumentasi installer dan workflow supaya migration 024, pemeriksaan sintaks shell, dan branch audit ikut diuji.
5. Tambah skrip diagnostik read-only `tools/stardesk-host-diagnostics/Collect-StarDeskHostDiagnostics.ps1` untuk mengidentifikasi lokasi instalasi, proses, service, scheduled task, folder, event provider dan versi file StarDesk. Skrip tidak menjalankan/mematikan/mengubah StarDesk, dan tidak mengumpulkan password/token.

**Hasil regression:** GitHub Actions run [45599526734](https://github.com/anigamesready/Billing_stardesk_custom/actions/runs/45599526734) lulus seluruh langkah. Termasuk `bash -n` installer, fresh PostgreSQL migrations, login/pairing, admin permissions, watchdog, authenticated stream-clock tests lama, wallet/top-up/lot expiry/GPU rate/StarDesk mapping, Admin Coin read API, serta upgrade dari database Android core-only. Ini tes disposable PostgreSQL, bukan tes database Redmi live.

## Gateway dan relay
- Worker Cloudflare `ani-games-db-android-stage-gateway` dan `ani-games-db-android-stage-ws-relay` ditemukan terpasang di akun Cloudflare.
- Gateway mempunyai binding ke service relay dan health route mengharuskan relay online, `agent_connected=true`, API online, dan database online.
- Worker relay menggunakan satu Durable Object hub bernama `redmi-db-android-stage` dengan protokol `ani-db-relay-v1`.
- Installer Termux saat ini memasang PostgreSQL + Node API lokal, tetapi **tidak memasang client WebSocket relay** yang harus menjaga koneksi Redmi ke Cloudflare. Source client relay pusat belum ditemukan pada paket installer yang diaudit.
- Host Agent Windows berbeda dari relay pusat Redmi. PC Agent tidak boleh menggantikan atau menjalankan relay database pusat.

## Database yang dapat dan tidak dapat diverifikasi
- Koneksi Supabase yang tersedia dalam audit menunjuk ke proyek lama **Billing Ani Games Ready**, bukan PostgreSQL Android DB lokal di Redmi.
- Proyek Supabase itu memiliki tabel Remote Play lama tetapi tidak memiliki tabel Coin Wallet; fungsi StarDesk Client API lamanya masih mengembalikan `connectEnabled:false`. Itu membuktikan proyek Supabase lama bukan backend Coin Android DB yang diinginkan.
- Database Termux Android DB di Redmi tidak dapat diakses langsung dari lingkungan ini. Karena itu status migrasi 020–024, akun/PC nyata, RPC live, dan koneksi relay Redmi **belum dapat dikonfirmasi**. Jangan menerapkan migrasi pada Supabase lama untuk mencoba memperbaikinya.

## StarDesk Desktop 1.6.0 dan bukti integrasi
- File yang diberikan: `StarDesk-1.6.0-13j6BjxC.exe`, SHA-256 `902512568bac4bd8aec788c97f5ff831ec97a086e67d1bf85c20ab5fe5a2673f`. Pemeriksaan statis mengidentifikasinya sebagai installer NSIS 3.12. Tidak dijalankan dan payload lokal tidak berhasil diekstrak dengan tool yang tersedia.
- Dokumentasi resmi StarDesk menyatakan Remote Access memakai akun StarDesk yang sama pada host dan client. StarDesk juga mendokumentasikan mode Remote Assist yang memakai Device ID + Verification Code untuk menghubungkan dua akun berbeda. Sumber:
  - https://www.stardesk.net/help/step-2.html
  - https://www.stardesk.net/blog/easyway-remotely-help-fix-pcproblems.html
- Dokumentasi publik yang ditinjau belum memberi API/SDK/webhook resmi untuk membaca status host, mengambil verification code, atau menerima event stream-start/stream-stop dari Agent pihak ketiga.
- Deep link `stardesk://external/device/control?id=...` hanya pernah teramati di catatan integrasi aplikasi; belum ada bukti bahwa deep link itu membawa kredensial Remote Assist, mengautentikasi pelanggan, atau menghasilkan callback sesi.
- Karena itu deteksi proses `StarDesk.exe` saja **tidak boleh dianggap** sebagai stream aktif. Ia juga tidak membuktikan client sudah login, host siap, atau koneksi benar-benar berjalan.

## Mengapa Windows Host Agent produksi belum dibangun
Membangun Agent yang sekadar mengirim heartbeat, menganggap proses StarDesk aktif sebagai stream aktif, atau memakai API lama `sunshine_ready` akan berisiko menampilkan PC READY padahal tidak bisa diakses dan memotong Coin tanpa sesi nyata. Integrasi juga belum punya relay pusat Android DB yang terbukti online.

Tahap berikut yang aman:
1. Jalankan skrip diagnostik di satu PC StarDesk 1.6.0 dan kirim ZIP hasilnya setelah ditinjau. Ini untuk menemukan executable, service, log/event dan identifier host yang memang tersedia pada instalasi nyata.
2. Pastikan relay client pusat pada Redmi aktif, health lengkap lulus, dan jalur Admin/Remote mengarah ke satu Android DB yang sama.
3. Buat adapter StarDesk berdasarkan antarmuka lokal/resmi yang terbukti dapat membaca Device ID + Verification Code atau event sesi. Jangan memakai scraping/mengubah binary proprietary.
4. Tambah siklus Coin terpisah: reserve/start → bukti stream connected → heartbeat → stop/timeout/recovery → idempotent settle dari durasi stream aktual. Kunci account expiry, saldo, tarif snapshot dan satu sesi per akun/PC di database.
5. Baru aktifkan tombol Connect setelah real device acceptance tests: Android install/login, host enrollment, koneksi StarDesk, start/stop, reconnect/crash/offline, expiry, saldo nol, dan debit Coin tepat sekali.

## Batasan rilis
Remote v0.5.0 dan Admin v12.1.61 tetap kandidat Preview/SAFE-TEST. Build CI tidak membuktikan instalasi HP/PC, login live, transfer stream, atau pembayaran nyata. Tidak ada migrasi yang diterapkan ke database live dan tidak ada perubahan pada Desktop 1.6.0.
