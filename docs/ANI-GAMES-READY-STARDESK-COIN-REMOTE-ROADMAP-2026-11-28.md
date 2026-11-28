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

Terms of Use StarDesk yang ditemukan diperbarui 11 November 2026 memuat batas penggunaan membership pribadi/non-komersial pada Addendum B pasal 10.1, serta pembatasan pada resale, penyediaan membership kepada pihak ketiga, dan otomasi pada pasal 11.1. Owner menjelaskan model bisnis yang dimaksud: penyewa mengunduh/menggunakan StarDesk dengan akun miliknya sendiri, sedangkan Coin Ani Games Ready dibayar untuk sewa PC/waktu host, bukan penjualan membership StarDesk. Catatan ini merekam kedua fakta tersebut tanpa membuat kesimpulan hukum final. Untuk kepastian operasional, ketentuan tertulis provider atau nasihat hukum tetap diperlukan; kode proyek tidak mengubah APK/desktop StarDesk. Sebelum implementasi komersial apa pun, minta konfirmasi tertulis atau perjanjian bisnis khusus yang mengizinkan:
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
- [x] Implementasikan snapshot konsisten dari satu aksi Copy: Device ID + Verification Code + invite URL.
- [x] Pisahkan `invite_url` dari `device_deep_link`; jangan membuat URL palsu.
- [~] Validasi relasi ID/kode/link, panjang, scheme, dan host allowlist. Expiry token belum dapat diverifikasi dari format clipboard.
- [x] Hindari plaintext credential/invite token dalam log, status file, dan diagnostic; kode/link dienkripsi AES-256-GCM sebelum disimpan DB.
- [x] Ganti timer `AutoSyncStarDeskAsync` 4 detik dengan observer WinEvent; event hanya memicu pemeriksaan/debounce.
- [x] Ketika sesi berakhir dan StarDesk kembali idle, Agent melakukan Copy & Share satu kali, parse ketiga field, fingerprint, dan sync hanya bila berubah.
- [x] Sinkronisasi Copy & Share tidak memakai polling beberapa detik. Heartbeat pemantau lokal dan Coin meter terpisah dari copy/sync.
- [x] Kirim snapshot atomik ke Service melalui named pipe terpisah dengan ACL.
- [x] Enkripsi Verification Code dan Invite URL sebelum disimpan; plaintext hanya melewati memori/pipe lokal untuk pemrosesan.
- [~] Fingerprint DB dan event ID idempotent tersedia; retry network/backoff untuk capture snapshot masih perlu ditambahkan.
- [x] Tes kontrak statis untuk tiga field, event watcher, encryption, session lifecycle, dan Coin berhasil; uji kasus parser pada runtime dan Windows UI nyata masih menunggu.
- [x] Build Windows Agent 0.2.7 sedang diperiksa oleh GitHub Actions; belum ada hasil final saat catatan ini dibuat.
- [ ] Uji runtime pada perangkat Windows dengan StarDesk 1.6.x; khusus transisi connected, idle, close app, minimize, dan dialog overlay.

Acceptance: source kontrak tiga data dan event-driven sync tersedia; real-StarDesk runtime test tetap wajib.

### TASK 3 — Identitas PC dan tarif Coin
- [x] Inventarisasi tabel PC Agent dan pairing StarDesk.
- [x] Identifikasi duplikasi jalur tarif lama vs inventaris Agent.
- [x] Identifikasi perbedaan FK `public.devices.id` vs `androiddb_v0.rental_pcs.id`.
- [x] Tetapkan keputusan desain identitas kanonis jalur Agent/Remote: `rental_pc_id`.
- [x] Pastikan tarif Agent memakai satu sumber otoritatif: `androiddb_v0.rental_pcs.hourly_coin_units`; nilai dikunci ke sesi saat request.
- [x] Buat migration additive 031 untuk kolom Invite URL terenkripsi dan tabel Coin session baru; jalur `androiddb_v0.sessions` lama tidak diubah.
- [x] RPC Agent/Remote baru menggunakan `rental_pc_id`; tidak mengasumsikan UUID sama dengan `public.devices.id`.
- [x] Contract test memeriksa FK, org scoping, unique active PC/account, tarif x100 dan session event. Fixture PostgreSQL dan concurrency test belum dijalankan.
- [x] Jalankan migration 031 pada PostgreSQL 16 disposable dan smoke test DB isolated; jangan langsung ubah live DB.

Acceptance: source memakai satu `rental_pc_id` dan satu sumber tarif untuk jalur Agent/Remote; verifikasi DB nyata/fixture masih menjadi gerbang.

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

Pemilik menjelaskan model operasional yang digunakan: setiap penyewa mengunduh dan memakai StarDesk dengan akun miliknya sendiri; Ani Games Ready menjual waktu sewa PC melalui Coin, bukan membership atau akun StarDesk. Source project tidak memodifikasi APK maupun desktop StarDesk. Catatan ini merekam model dan batas teknis tersebut, bukan opini hukum final. Pemeriksaan ketentuan provider tetap menjadi risiko operasional terpisah yang harus diselesaikan oleh pemilik sebelum rollout komersial. Fondasi DB/Agent boleh disiapkan, tetapi Remote Play belum aktif sampai request-session, bukti connected/ended, UI, dan QA perangkat nyata lengkap.

## H. Catatan perubahan/hasil

- 2026-11-28: audit source dan APK statis dilakukan. Tidak ada source code, schema, database produksi, APK, atau Windows service yang diubah pada tahap audit awal.
- 2026-11-28: pemilik memberikan contoh clipboard Copy & Share yang membuktikan tiga field: Device ID, Verification Code, dan URL undangan `app.stardesk.net/invite/<token>?lang=en-US`. Token asli sengaja tidak disalin ke repo/dokumen.
- 2026-11-28: source Agent versi branch kerja diperiksa. `AgentTrayForm` menjalankan auto-sync timer 4 detik; fingerprint hanya Device ID + Verification Code; `StarDeskCaptureSnapshot`, named-pipe payload, dan RPC backend belum membawa URL undangan. Capture otomatis saat ini berupa pembacaan ulang UI, bukan observer event-driven murni.
- 2026-11-28: pemilik menyatakan penyewa memakai akun StarDesk mereka sendiri dan pembayaran Ani Games Ready hanya untuk waktu sewa PC. Ani Games Ready tidak menjual membership StarDesk dan tidak mengubah aplikasi resmi. Terms of Use provider pernah ditinjau dan dicatat sebagai risiko/ketidakpastian operasional; catatan ini tidak menyimpulkan pelanggaran atau memberi kepastian hukum.
- 2026-11-28: pemeriksa web tidak dapat mengambil URL invite contoh (cache miss/internal route). Token expiry, single-use, redirect, dan launcher behavior belum diverifikasi.
- 2026-11-28: keputusan desain untuk jalur Agent/Remote baru adalah memakai `rental_pc_id` sebagai identitas PC kanonis dan `rental_pcs.hourly_coin_units` sebagai sumber tarif Agent; jalur lama `public.devices` tetap dipertahankan tanpa asumsi UUID sama.
- 2026-11-28: pembaruan dokumen/checklist saja. Tidak ada kode Agent, Remote APK, migrasi, database produksi, atau service produksi yang diubah.

- 2026-11-28 (implementasi branch): migration additive 031 ditambahkan untuk `invite_url` terenkripsi, Agent monitor lease, Coin rental sessions yang FK-nya ke `rental_pc_id`, idempotent billing events, server-side prorated debit, dan API request/session status. Database produksi belum disentuh.
- 2026-11-28 (implementasi branch): Windows Agent source dinaikkan ke 0.2.7. Capture tiga data memakai parser clipboard ketat; timer polling 4 detik diganti WinEvent watcher + debounce. Copy & Share dijalankan hanya saat StarDesk baru dibuka/idle setelah sesi berakhir/perubahan pairing terdeteksi. Monitor lease lokal/DB dan Coin meter 15 detik adalah heartbeat terpisah, bukan copy/sync kredensial.
- 2026-11-28 (CI): workflow `StarDesk Coin 031 — Windows Agent 0.2.7 Candidate` berjalan pada commit `dc95d4580c1cc06a2b15ea56a67a274380265a9c`. Job kontrak lulus: `node --check`, `bash -n` untuk skrip Termux, dan `node --test tests/stardesk-agent-coin-contract.test.mjs`. Job Windows x64 publish masih berjalan saat catatan ini dibuat.
- 2026-11-28: skrip upgrade existing `upgrade-stardesk-coin-031.sh` dan urutan migrasi fresh install 031 ditambahkan. Tidak ada migrasi yang dijalankan ke Android/DB owner; perlu jalur apply dan smoke test terpisah setelah artifact dan DB fixture lolos.
- 2026-11-28: Remote APK belum dihubungkan ke `androiddb_v0_remote_request_session` / `androiddb_v0_remote_session_status`; UI Play, countdown, dan tampilan saldo aktif masih tahap berikutnya. Backend source belum berarti APK telah menjalankan sesi.
- 2026-11-28: koneksi StarDesk tidak dapat diputus paksa oleh DB saat saldo habis hanya dengan menandai sesi ended. Pemutusan stream yang benar membutuhkan kontrol host/API resmi atau tindakan yang didukung StarDesk; implementasi saat ini menghentikan billing server dan menutup lifecycle Coin.
- 2026-11-28: penguncian akun/PC ada di DB (satu sesi requested/connected per akun dan PC, hanya token sesi renter mendapat invite URL), tetapi invite URL StarDesk sendiri belum terbukti single-use atau tak bisa diteruskan. Jangan mengklaim undangan provider terkunci secara kriptografis pada satu user sebelum ada dukungan provider.

- 2026-11-28 (validasi PostgreSQL): migration 031 berhasil dijalankan pada PostgreSQL 16 disposable. Smoke test berhasil memeriksa reservasi tanpa debit awal, event Connected, prorata 30 detik pada tarif 60 Coin/jam, tick idempotent, event Ended, batas 45 detik saat monitor hilang, host tetap locked setelah `monitor_lost`, expiry reservation, dan host yang sudah aktif sebelum booking. Tidak ada perubahan ke DB produksi.
- 2026-11-28 (validasi source): Node API syntax, Termux shell syntax, dan static contract tests lulus pada CI. Windows Agent build 0.2.7 untuk commit terbaru masih menunggu job publish x64.
- 2026-11-28: Agent Tray restart mencoba membersihkan host lock yang stale hanya setelah StarDesk dipastikan tertutup atau UI idle. Event `monitor_lost` menghentikan billing tetapi tidak melepaskan host lock.

- 2026-11-28 (CI final kandidat): run `46134622175` selesai sukses untuk `contract-tests`, `postgres-smoke`, dan `windows-agent`. Artifact Windows x64 Agent 0.2.7 berhasil dibuat dan checksum paket diverifikasi terhadap checksum CI.
- Artifact kandidat: `Ani-Games-Ready-StarDesk-Coin-Agent-0.2.7-win-x64-package.zip`; checksum disertakan pada file `SHA256-WINDOWS-AGENT-0.2.7.txt` dari artifact CI.
- Batas uji: build dan PostgreSQL disposable lulus, tetapi Agent belum diuji pada PC Windows nyata dengan StarDesk. Status Connected/Idle/exit, restore/navigasi Remote Assistance, dan copy clipboard tiga field harus diuji langsung sebelum dipakai untuk rental.
- Perubahan Task 2–3 belum digabung ke `main`, belum diterapkan ke DB produksi, dan belum dihubungkan ke Remote APK. Stable Billing tetap tidak disentuh.
