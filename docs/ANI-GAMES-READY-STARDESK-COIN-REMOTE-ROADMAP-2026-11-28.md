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
2. Setelah kredensial perangkat tersedia dan valid, Agent mengirim snapshot terikat satu perangkat: Device ID, Verification Code, dan informasi link jika link khusus perangkat memang disediakan secara resmi dan berhasil dibuktikan.
3. Android DB menyimpan identitas PC yang konsisten, status Agent, pairing StarDesk, dan rahasia dalam bentuk terenkripsi.
4. Penyewa login dengan User ID, melihat PC yang tersedia, dan memilih PC.
5. Backend memeriksa akun, saldo, expiry, status PC/Agent, dan izin komersial/integrasi StarDesk sebelum menyiapkan sesi.
6. Remote menampilkan popup kredensial yang hanya diberikan untuk PC/sesi yang telah diotorisasi.
7. Streaming aktif hanya setelah bukti koneksi yang sah. Baru setelah itu billing dimulai.
8. Backend menghitung biaya menggunakan waktu server dan tarif snapshot. Remote hanya menampilkan countdown.
9. Ketika saldo/lease habis, backend memerintahkan disconnect khusus untuk sesi tersebut. Agent mengonfirmasi hasil. Backend menyelesaikan settlement.
10. Setelah sesi berakhir, Agent mendeteksi perubahan kredensial yang nyata dan menyinkronkan snapshot baru.

## C. Batas antara data link

Jangan mencampur tiga hal berikut:

- `share_url`: URL website/help/share publik dari clipboard atau Share sheet. Ini belum tentu dapat membuka PC.
- `device_deep_link`: URI aplikasi StarDesk khusus perangkat. APK 1.6.1 memuat pola statis `stardesk://external/device/control?id=...&source=...&from=...&expire=...`; nilai dan makna parameternya belum diverifikasi dengan peluncuran nyata.
- `verification_code`: kredensial sementara yang berubah dan harus diperlakukan sebagai rahasia.

Dokumentasi resmi Remote Assist yang diperiksa menyebut Device ID + Verification Code sebagai data yang dibagikan. Dokumentasi itu tidak membuktikan bahwa Copy & Share selalu menghasilkan URL akses PC. Karena itu parser tidak boleh mengarang URL atau parameter deep link. Ambil contoh payload clipboard aktual yang sudah disamarkan dan verifikasi launch di StarDesk 1.6.1 sebelum menyimpan/menampilkan deep link.

## D. Gate lisensi dan integrasi pihak ketiga

StarDesk Terms yang diperiksa pada 28 November 2026 memberikan lisensi personal yang revocable, non-assignable, non-sublicensable, dan non-transferable (pasal 3.1). Ketentuan yang tampil tidak secara eksplisit menjelaskan skema rental komersial ini, sehingga ini adalah risiko/ketidakjelasan lisensi, bukan klaim bahwa pasal tersebut secara eksplisit melarang semua penyewaan PC. Sebelum menjual akses StarDesk kepada penyewa atau mengotomasi pemakaian akun/remote assist, minta konfirmasi tertulis dari StarDesk/GearUp mengenai:
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
- [ ] Dapatkan contoh teks clipboard Copy & Share aktual (nilai rahasia disamarkan, struktur/label/URL tetap dipertahankan).
- [ ] Verifikasi handler deep link APK 1.6.1 pada device Android nyata dan nilai parameter `source`, `from`, `expire`.
- [ ] Dapatkan persetujuan tertulis/konfirmasi lisensi komersial untuk rental akses berbayar dan automasi.
- [ ] Buktikan API/SDK atau mekanisme resmi untuk mendeteksi dan memutus satu sesi.

Acceptance: format clipboard, jenis link, otorisasi, dan batas lisensi terdokumentasi; tidak ada asumsi yang belum dibuktikan.

### TASK 2 — Windows Agent: capture dan sinkronisasi data
- [ ] Tetapkan schema payload dari contoh clipboard aktual.
- [ ] Ambil snapshot konsisten dari satu aksi Copy: Device ID + Verification Code + link yang benar-benar tersedia.
- [ ] Pisahkan `share_url` dan `device_deep_link`; jangan membuat URL palsu.
- [ ] Validasi relasi ID/kode/link, panjang, scheme, host allowlist, dan expiry.
- [ ] Hindari plaintext credential dalam log, status file, dan diagnostic.
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
- [ ] Putuskan satu identitas kanonis baru: `rental_pc_id` untuk jalur Agent/Remote baru.
- [ ] Rancang jembatan additive untuk data lama `public.devices`; jangan menganggap UUID keduanya sama.
- [ ] Tentukan satu sumber tarif otoritatif untuk PC yang memakai Agent; hindari update dua tarif yang berbeda.
- [ ] Buat migration additive dan rollback notes setelah semua read/write call sites diperiksa.
- [ ] Perbarui RPC Admin/Remote hanya pada jalur Agent/Remote baru; pertahankan fungsi lama.
- [ ] Tambahkan tes FK, org isolation, duplicate link prevention, rate precision/unit x100, dan audit event.
- [ ] Jalankan migrasi pada fixture CI, lalu smoke test DB isolated; jangan langsung ubah live DB.

Acceptance: satu PC Agent memiliki satu `rental_pc_id`, tarif yang dibaca Remote sama dengan tarif yang diubah Admin, dan sistem lama tetap berfungsi tanpa perubahan destruktif.

### TASK 4 — Coin Session Engine (sesudah Task 1–3)
- [ ] Request/reserve session idempotent.
- [ ] Konfirmasi streaming aktif sebelum billing mulai.
- [ ] Snapshot tarif saat start.
- [ ] Debit/settlement menggunakan server time dan FIFO expiry lots.
- [ ] Single-active-session per account dan per PC.
- [ ] Heartbeat/session lease dan recovery ketika network/Agent offline.
- [ ] Audit ledger dan end_reason lengkap.
- [ ] Race/concurrency tests.

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

Cakupan pekerjaan awal hanya Task 1–3. Task 4–9 tidak boleh mulai sebelum Task 1–3 memiliki acceptance evidence. Jika lisensi/API StarDesk tidak dikonfirmasi, tahan integrasi komersial StarDesk dan siapkan opsi engine komersial yang didukung.

## H. Catatan perubahan/hasil

- 2026-11-28: audit source dan APK statis dilakukan. Tidak ada source code, schema, database produksi, APK, atau Windows service yang diubah pada tahap audit ini.
- 2026-11-28: temuan penting: dokumentasi resmi hanya mendeskripsikan Device ID + Verification Code; APK string memuat custom deep-link template tetapi parameter belum diverifikasi; lisensi personal non-transferable/non-sublicensable perlu konfirmasi tertulis untuk model rental; DB punya mismatch identitas `rental_pc_id` vs `public.devices.id`.
