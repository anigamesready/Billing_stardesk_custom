# Ani Games Ready — StarDesk Coin Remote Roadmap
Tanggal audit: 28 November 2026
Status dokumen: rencana kerja dan checklist hidup
Repo kerja: https://github.com/anigamesready/Billing_stardesk_custom
Branch kerja awal: feature/stardesk-coin-remote-task1-3-20261128

## A. Keputusan arsitektur yang sudah disepakati

1. Produk bernama **Ani Games Ready**. Remote client Android, Windows Agent, Android DB/API, dan StarDesk harus saling terhubung melalui kontrak yang jelas.
2. Android DB adalah satu-satunya database otoritatif untuk proyek ini. Jangan menghidupkan kembali dual DB, DB1/DB2, primary/backup, atau sinkronisasi antar-database.
3. Windows Agent menjadi pengawas PC/host dan pelaksana perintah host yang memang didukung.
4. Remote APK menjadi antarmuka penyewa: login User ID, saldo/expiry, daftar PC READY/ACTIVE/OFFLINE, pemilihan PC, popup koneksi, dan countdown.
5. Backend/Android DB menjadi satu-satunya penentu otorisasi sesi, tarif yang dikunci, debit Coin, expiry, dan hasil settlement. Timer di HP hanya tampilan.
6. StarDesk tetap menjadi engine remote/streaming selama ada dasar lisensi dan integrasi resmi yang sesuai. Jangan mengganti atau membongkar engine-nya sebagai jalan pintas.
7. Semua perubahan database bersifat additive. Jangan menghapus/mengubah tabel lama secara destruktif sebelum seluruh pemakai, data, relasi, dan migrasi rollback diverifikasi.
8. Build yang hanya lolos compile tetap berstatus TEST. Release memerlukan uji API/DB dan perangkat nyata, termasuk sesi remote sesungguhnya.

## B. Alur produk yang dituju

1. Agent Windows memantau aplikasi desktop StarDesk yang tepat.
2. Setelah snapshot kredensial perangkat tersedia dan valid, Agent mengirim satu bundle atomik yang terikat ke satu PC: Device ID, Verification Code, dan `invite_url` dari tombol Copy & Share. Nilai invite token bersifat rahasia; Agent tidak boleh menulisnya ke log atau status plaintext.
3. Android DB menyimpan identitas PC yang konsisten, status Agent, pairing StarDesk, dan rahasia dalam bentuk terenkripsi.
4. Penyewa login dengan User ID, melihat PC yang tersedia, dan memilih PC.
5. Backend memeriksa akun, saldo, expiry, status PC/Agent, dan izin komersial/integrasi StarDesk sebelum menyiapkan sesi.
6. Remote menampilkan popup kredensial yang hanya diberikan untuk PC/sesi yang telah diotorisasi.
7. Streaming aktif hanya setelah bukti koneksi yang sah. Baru setelah itu billing dimulai.
8. Backend menghitung biaya menggunakan waktu server dan tarif snapshot. Remote hanya menampilkan countdown.
9. Ketika saldo/lease habis, backend memerintahkan disconnect khusus untuk sesi tersebut. Agent mengonfirmasi hasil. Backend menyelesaikan settlement.
10. Setelah sesi berakhir, Agent mendeteksi perubahan kredensial yang nyata dan menyinkronkan snapshot baru.

## C. Kontrak clipboard aktual dan pemisahan jenis link

Contoh tombol Copy & Share yang diberikan Owner pada 28 November 2026 memiliki susunan berikut (semua nilai rahasia disamarkan):

```text
Use StarDesk to initiate remote assistance
Device ID: [DEVICE_ID]
Verification Code: [VERIFICATION_CODE]
Click the link to initiate directly: https://app.stardesk.net/invite/[OPAQUE_INVITE_TOKEN]?lang=en-US
```

Kontrak data yang terbukti dari contoh clipboard adalah:

- `stardesk_device_id`: nilai setelah label `Device ID:`.
- `verification_code`: nilai setelah label `Verification Code:`; rahasia sementara.
- `invite_url`: URL setelah label `Click the link to initiate directly:` dengan host `app.stardesk.net` dan path `/invite/<opaque-token>`; perlakukan seluruh URL/token sebagai rahasia seperti verification code.

Jangan samakan `invite_url` dengan URI aplikasi `device_deep_link`. APK StarDesk 1.6.1 memuat pola statis `stardesk://external/device/control?id=...&source=...&from=...&expire=...`, tetapi nilai/arti parameternya belum diverifikasi dan pola itu bukan URL yang diberikan pada contoh clipboard ini.

Pemeriksa web tidak dapat mengambil halaman invite contoh (cache miss/internal route), sehingga masa berlaku token, apakah token satu-kali-pakai, redirect target, dan perilaku ketika aplikasi Android belum terpasang belum terbukti. Jangan mengasumsikannya. Simpan `invite_url` hanya dalam bentuk terenkripsi, jangan tampilkan di log/status, dan jangan menerbitkan URL itu kecuali sesi telah diotorisasi. Validasi format/host allowlist dan fingerprint harus mencakup ketiga field.

## D. Gate lisensi dan integrasi pihak ketiga

Terms of Use StarDesk versi yang ditemukan dan diperbarui 11 November 2026 kini secara eksplisit menyebut pada Addendum B pasal 10.1 bahwa membership hanya untuk penggunaan pribadi non-komersial; menyediakan remote access/remote support kepada orang lain dengan pembayaran atau menjual kembali akses StarDesk bukan penggunaan pribadi. Pasal 11.1(a)-(c) juga melarang membership untuk resale/keuntungan komersial, menyediakan akun membership kepada pihak ketiga, dan penggunaan cara otomatis (termasuk bot/script) untuk memperoleh atau menggunakan membership; pasal 11.2 memungkinkan penangguhan atau penghentian membership jika dilanggar. Ini bukan lagi sekadar ketidakjelasan umum: model rental Coin yang menjual sesi remote melalui StarDesk bertentangan dengan ketentuan yang dipublikasikan, kecuali StarDesk/GearUP memberi pengecualian/kontrak tertulis. Sebelum implementasi komersial apa pun, minta konfirmasi tertulis atau perjanjian bisnis khusus yang mengizinkan:
- penggunaan host/client untuk layanan rental remote PC berbayar;
- penyimpanan dan distribusi Device ID/Verification Code;
- deep link atau API resmi untuk meluncurkan koneksi;
- API/SDK resmi untuk memantau dan memutus satu sesi.

Jika izin/API yang sesuai tidak tersedia, pilih engine remote yang memberi lisensi komersial dan API host-control yang jelas. Jangan membangun workaround yang menghindari pembatasan aplikasi.

## E. Temuan baseline source per 28 November 2026

- Repo default branch `main`: `950c2fc9858bbcec1a2f9696f72634dd000b45e5`.
- Branch pengembangan Agent/Remote yang menjadi sumber kerja: `feature/remote-agent-sync-auto-discovery-20261127` pada `7a33c8d376924453c479c673305bedf173bd0f4e`.
- Kedua branch divergen: main memiliki 15 commit yang belum berada di branch fitur; branch fitur memiliki sekitar 560 commit yang belum berada di main. Jangan force-push atau merge massal tanpa review. Branch tugas ini dibuat terpisah dari source branch fitur; main tetap tidak disentuh.
- APK StarDesk 1.6.1 diunggah di percakapan dan diperiksa secara statis. Strings DEX menunjukkan kelas/fungsi deep-link dan pola URI di atas. Ini bukan source code dan tidak membuktikan launch/permission/expiry param bekerja.
- Dokumentasi resmi StarDesk Remote Assist menyebut pengguna menyalin Device ID dan Verification Code. Format clipboard mentah Copy & Share belum dibuktikan dari APK statis/dokumentasi.
- Windows Agent saat ini hanya mengirim `stardesk_device_id` + `verification_code` melalui named pipe. API meng-enkripsi verification code AES-256-GCM sebelum database. Tidak ada access-link field pada kontrak 030.
- `androiddb_v0.stardesk_pairings` saat ini dipatok ke `rental_pc_id`, menyimpan Device ID dan verification ciphertext/nonce/tag.
- `androiddb_v0.rental_pcs` dan `agent_devices.rental_pc_id` adalah inventaris PC yang dipakai Agent terbaru. Tarif Agent berada pada `rental_pcs.hourly_rupiah` dan `hourly_coin_units`.
- Migrasi 028 juga masih memelihara `androiddb_v0.pc_coin_rates` yang mengacu ke `public.devices`. Bagian Coin lama dan `androiddb_v0.sessions.device_id` masih berada pada jalur identitas `public.devices`, sedangkan Remote/Agent baru memakai `rental_pcs`. Hubungan keduanya belum menjadi satu identitas kanonis.
- Dashboard Remote di migrasi 030 mengembalikan `available=false`, `host_agent_ready=false`, dan `can_start=false`. Ini adalah pengunci yang benar untuk preview sampai lifecycle session/stream benar-benar tersedia.
- API Agent sync 030 hanya menerima dua data credential. Saat ini tidak ada kolom/kontrak link langsung.
- Belum ada perubahan source, migrasi, database produksi, APK, atau service produksi pada audit awal Task 1–3 ini.

## F. Roadmap tugas dan status

Status: [x] = selesai dengan bukti; [~] = audit sebagian / sedang berjalan; [ ] = belum dikerjakan; [!] = blocker/keputusan eksternal.

### TASK 1 — Baseline, protokol, dan lisensi StarDesk
- [x] Baca skill repo terbaru dari main.
- [x] Bandingkan main dengan branch pengembangan dan catat divergensi.
- [x] Audit kontrak Agent 0.2.6, API 030, dan skema DB 027–030.
- [x] Audit strings/URI statis dari APK StarDesk 1.6.1 yang diunggah.
- [x] Cocokkan alur Remote Assist dengan dokumentasi resmi StarDesk.
- [x] Periksa Terms of Service dan catat risiko lisensi.
- [x] Dapatkan contoh teks clipboard Copy & Share aktual: Device ID + Verification Code + URL undangan `app.stardesk.net/invite/<token>?lang=en-US` (token dan kredensial tidak disimpan di dokumen).
- [ ] Verifikasi handler deep link APK 1.6.1 pada device Android nyata dan nilai parameter `source`, `from`, `expire`.
- [!] Dapatkan pengecualian/perjanjian tertulis dari StarDesk/GearUP untuk rental remote berbayar dan automasi. Terms saat ini secara eksplisit membatasi membership ke penggunaan pribadi non-komersial.
- [ ] Buktikan API/SDK atau mekanisme resmi untuk mendeteksi dan memutus satu sesi.

Acceptance: format clipboard, jenis link, otorisasi, dan batas lisensi terdokumentasi; tidak ada asumsi yang belum dibuktikan.

### TASK 2 — Windows Agent: capture dan sinkronisasi data
- [x] Tetapkan bentuk payload dari contoh clipboard: Device ID + Verification Code + `invite_url`.
- [ ] Implementasikan snapshot konsisten dari satu aksi Copy: Device ID + Verification Code + invite URL.
- [x] Pisahkan `invite_url` dari `device_deep_link`; jangan membuat URL palsu.
- [ ] Validasi relasi ID/kode/link, panjang, scheme, host allowlist, dan expiry.
- [ ] Hindari plaintext credential/invite token dalam log, status file, clipboard history, dan diagnostic.
- [ ] Ganti timer `AutoSyncStarDeskAsync` 4 detik dengan event-driven observer (Windows UI Automation + WinEvent/process/window events); event hanya memicu pemeriksaan dan satu capture setelah transisi stabil.
- [ ] Ketika event menunjukkan sesi berakhir dan StarDesk kembali ke halaman Remote Assist, jalankan Copy & Share satu kali, parse ketiga field, fingerprint ketiga field, lalu sync hanya jika fingerprint berbeda.
- [ ] Jangan menggunakan polling beberapa detik untuk mengirim sync. Retry network hanya untuk snapshot event yang sama dengan idempotency key/backoff; jangan menghasilkan snapshot baru kecuali ada event baru.
- [ ] Kirim snapshot atomik ke Service melalui named pipe; batasi ACL.
- [ ] Enkripsi Verification Code dan setiap link yang mengandung token/credential sebelum disimpan.
- [ ] Tambahkan idempotency/fingerprint dan retry dengan backoff.
- [ ] Tambahkan regression test parser untuk format clipboard aktual, nilai tidak lengkap, URL umum, link kadaluarsa, teks palsu, dan clipboard lama.
- [ ] Build dan smoke test Agent; real-StarDesk runtime test tetap wajib.

Acceptance: tiga data yang benar-benar tersedia tersinkron sebagai satu snapshot yang valid, atau Agent menolak dan memberi diagnosis aman.

### TASK 3 — Identitas PC dan tarif Coin
- [x] Inventarisasi tabel PC Agent dan pairing StarDesk.
- [x] Identifikasi duplikasi jalur tarif lama vs inventaris Agent.
- [x] Identifikasi perbedaan FK `public.devices.id` vs `androiddb_v0.rental_pcs.id`.
- [x] Tetapkan keputusan desain identitas kanonis jalur Agent/Remote: `rental_pc_id`.
- [ ] Rancang jembatan additive untuk data lama `public.devices`; jangan menganggap UUID keduanya sama.
- [ ] Tentukan satu sumber tarif otoritatif untuk PC yang memakai Agent; hindari update dua tarif yang berbeda.
- [ ] Buat migration additive dan rollback notes setelah semua read/write call sites diperiksa.
- [ ] Perbarui RPC Admin/Remote hanya pada jalur Agent/Remote baru; pertahankan fungsi lama.
- [ ] Tambahkan tes FK, org isolation, duplicate link prevention, rate precision/unit x100, dan audit event.
- [ ] Jalankan migrasi pada fixture CI, lalu smoke test DB isolated; jangan langsung ubah live DB.

Acceptance: satu PC Agent memiliki satu `rental_pc_id`, tarif yang dibaca Remote sama dengan tarif yang diubah Admin, dan sistem lama tetap berfungsi tanpa perubahan destruktif.

### TASK 4 — Coin Session Engine (provider-neutral; aktivasi setelah adapter remote disetujui)
- [ ] Request/reserve session idempotent dan kunci `rental_account_id` + `rental_pc_id` + `session_id`.
- [ ] Sesi `requested/connecting` tidak memotong Coin; debit baru dimulai setelah host memberi bukti `connected` yang sah.
- [ ] Snapshot `hourly_coin_units` dari `rental_pcs` saat sesi aktif; perubahan harga Admin tidak mengubah tarif sesi yang sedang berjalan.
- [ ] Debit/settlement dihitung server-side dari waktu aktif sampai event end; gunakan presisi integer/fixed-point sesuai unit tarif yang sudah dipakai migrasi lama.
- [ ] Single-active-session per akun dan per PC dengan transaksi/constraint database, bukan hanya tombol UI.
- [ ] Kunci sesi melekat pada satu akun penyewa dan satu PC; hanya pemilik sesi aktif yang dapat meminta credential/handoff sesi tersebut.
- [ ] Stop/settlement idempotent: event berulang tidak boleh memotong saldo dua kali.
- [ ] Agent heartbeat/session lease dan reconciliation ketika jaringan/Agent offline; jika bukti host hilang, sistem tidak boleh terus menagih tanpa batas.
- [ ] Audit ledger lengkap: reserve, start, debit, end, refund/release, actor, timestamp server, rate snapshot, dan end_reason.
- [ ] Race/concurrency tests untuk dua pengguna memilih satu PC, satu user meminta dua PC, retry RPC, dan event start/end duplikat.

**Invariant billing:** waktu `requested` dan `connecting` tidak ditagih; timer mulai hanya pada bukti sesi host benar-benar `connected`; timer berhenti pada bukti sesi selesai atau batas lease yang aman; countdown HP hanya cerminan deadline server, bukan sumber perhitungan uang.

### TASK 5 — Agent session control dan auto-disconnect
- [ ] Command khusus per session ID, bukan taskkill aplikasi global.
- [ ] Verifikasi sesi/host yang dituju sebelum disconnect.
- [ ] Ack delivered/started/completed/failed/expired.
- [ ] Local lease cutoff jika heartbeat backend habis.
- [ ] Reconciliation jika perintah stop sukses tetapi ACK hilang.

### TASK 6 — Remote APK popup koneksi
- [ ] PC selection hanya jika backend mengizinkan.
- [ ] Popup Device ID, status, Verification Code tersembunyi, link yang tervalidasi.
- [ ] Copy/open action memiliki callback nyata.
- [ ] Secret hanya diberikan untuk sesi/account terotorisasi.
- [ ] Empty balance, expired, offline, unavailable, stale credential diblokir di backend.

### TASK 7 — Countdown dan user experience
- [ ] Countdown berdasarkan server deadline.
- [ ] Refresh dan reconnect tanpa membuat sesi ganda.
- [ ] Peringatan saldo rendah.
- [ ] Tampilan session ended dan settlement.

### TASK 8 — Integrasi menyeluruh
- [ ] Admin, Agent, API, DB, Remote, StarDesk teruji end-to-end.
- [ ] Kode berubah, session active, session end, PC offline, API timeout, Agent restart.
- [ ] Coin cukup/tidak cukup/habis, expiry, multi-client race, tariff update.
- [ ] No secret leak; no legacy regression.

### TASK 9 — Pilot dan rollout
- [ ] Satu PC pilot, test Coin non-produksi, persetujuan pengguna.
- [ ] Monitor error dan reconciliation.
- [ ] Perluasan bertahap setelah seluruh checklist lulus.
- [ ] Rilis final hanya setelah QA device nyata.

## G. Batas pelaksanaan tahap saat ini

Cakupan audit awal Task 1–3 sudah diperbarui dengan contoh clipboard. Implementasi integrasi StarDesk berbayar tetap **NO-GO** sampai ada izin tertulis/perjanjian bisnis yang sesuai; jangan mengotomasi pemakaian membership atau menjual sesi dari akun personal. Pekerjaan aman yang dapat dipersiapkan tanpa mengaktifkan StarDesk adalah menyelesaikan pemetaan PC/tarif kanonis dan mendesain Coin Session Engine yang provider-neutral. Remote tidak boleh menampilkan tombol Play aktif dan tidak boleh memotong Coin sebelum adapter remote yang sah menyediakan bukti sesi `connected`/`ended`.

## H. Catatan perubahan/hasil

- 2026-11-28: audit source dan APK statis dilakukan. Tidak ada source code, schema, database produksi, APK, atau Windows service yang diubah pada tahap audit awal.
- 2026-11-28: pemilik memberikan contoh clipboard Copy & Share yang membuktikan tiga field: Device ID, Verification Code, dan URL undangan `app.stardesk.net/invite/<token>?lang=en-US`. Token asli sengaja tidak disalin ke repo/dokumen.
- 2026-11-28: source Agent versi branch kerja diperiksa. `AgentTrayForm` menjalankan auto-sync timer 4 detik; fingerprint hanya Device ID + Verification Code; `StarDeskCaptureSnapshot`, named-pipe payload, dan RPC backend belum membawa URL undangan. Capture otomatis saat ini berupa pembacaan ulang UI, bukan observer event-driven murni.
- 2026-11-28: Terms of Use yang ditampilkan saat ini (updated 2026-11-11) secara eksplisit membatasi membership ke penggunaan pribadi non-komersial; remote support/access berbayar kepada orang lain dan resale bukan penggunaan pribadi (Addendum B 10.1). Pasal 11.1 melarang resale untuk keuntungan komersial, menyediakan membership kepada pihak ketiga, dan automation untuk memperoleh/menggunakan membership; pasal 11.2 memungkinkan suspend/terminate. Integrasi Coin komersial StarDesk ditahan sampai ada izin tertulis/perjanjian khusus.
- 2026-11-28: pemeriksa web tidak dapat mengambil URL invite contoh (cache miss/internal route). Token expiry, single-use, redirect, dan launcher behavior belum diverifikasi.
- 2026-11-28: keputusan desain untuk jalur Agent/Remote baru adalah memakai `rental_pc_id` sebagai identitas PC kanonis dan `rental_pcs.hourly_coin_units` sebagai sumber tarif Agent; jalur lama `public.devices` tetap dipertahankan tanpa asumsi UUID sama.
- 2026-11-28: pembaruan dokumen/checklist saja. Tidak ada kode Agent, Remote APK, migrasi, database produksi, atau service produksi yang diubah.
