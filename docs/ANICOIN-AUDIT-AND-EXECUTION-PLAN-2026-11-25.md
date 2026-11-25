# AniCoin — Audit dan Rencana Eksekusi Terpisah

Tanggal: 25 November 2026

Repo otoritatif: https://github.com/anigamesready/Billing_stardesk_custom
Branch audit/implementasi: `feature/admin-androiddb-v0-isolated-20261125`
Main/stable: tidak diubah.

## Ringkasan status aktual

### Redmi / Termux
Screenshot pengguna memperlihatkan installer berhenti dengan:
`STOP: PostgreSQL sudah aktif tetapi tidak dikelola runit. Proses lama dibiarkan utuh; audit service diperlukan.`

Kesimpulan:
- PostgreSQL sedang merespons pada socket lokal.
- Installer tidak menemukan status `sv status postgres` dengan prefix `run:`.
- Installer berhenti sebelum `PG_ADMIN_USER`, backup, dan blok migrasi SQL.
- Migration 025 belum dapat dianggap terpasang di database live.
- Dari urutan source installer saat ini, file backend dan migration sudah disalin ke `$HOME/ani-games-ready-android-db/server` dan `migrations` sebelum pemeriksaan service PostgreSQL ini. Proses PostgreSQL tidak dihentikan oleh cabang stop tersebut. Node API yang sedang hidup mungkin masih menjalankan source lama di memori, tetapi source folder dapat berisi versi baru. Jangan restart Node API sampai proses dan service path diperiksa.

Belum diketahui dari screenshot:
- PGDATA yang benar dan pemilik proses PostgreSQL.
- Command line startup PostgreSQL dan siapa supervisornya.
- Apakah Node API berjalan dari folder yang disalin installer atau dari lokasi lain.
- Database name/port aktif dan migration signature aktual.

Tidak boleh menghapus PID, mematikan PostgreSQL, menjalankan initdb/pg_ctl start/stop, mengubah .env, atau mengulang installer sebelum data ini diaudit.

### Android DB v0
Source menyediakan migration `025_admin_androiddb_v0_coin_domain.sql` dengan 14 tabel dan 20 API function signatures pada schema `androiddb_v0`. CI disposable PostgreSQL lulus untuk fresh install, core-only upgrade, operasi Coin dan regresi timer lama. Ini bukan bukti migration sudah live pada Redmi.

### Pemisahan data
Data pelanggan Coin berada pada `androiddb_v0.rental_accounts`, credentials/session, wallet, top-up orders, lots, ledger, rates, StarDesk links, Host Agent, v0 sessions dan audit. Tidak ada penggunaan saldo detik atau expiry akun rental lama di domain v0.

Shared core yang masih dipakai:
- Owner/Admin authentication dan organisasi.
- Inventaris PC `public.devices`.

Maka pemisahan rental/billing bersifat schema/data/API-domain isolation di satu PostgreSQL Android DB, bukan database fisik atau server kedua. Jangan menambahkan DB1/DB2 atau dual-database switching.

### Admin v0
APK terpisah `com.anigames.billingadmin.androiddbv0`, Preview 0.1.0. Source UI memakai RPC v0 untuk rental, aktivasi, wallet, top-up, tarif, mapping, izin Host dan enrollment. Login Admin menggunakan Owner auth core. Build/CI lulus, tetapi real-device dan live DB belum diuji.

### Remote v0.6.0
Saat ini Remote masih menampilkan field User ID + kode aktivasi perangkat pertama. Native bridge menyimpan token via Android Keystore. Tidak ada tombol/link "Daftar dulu" di halaman login. WhatsApp helper untuk alur top-up sudah ada, tetapi itu bukan pendaftaran akun.

### Billing/session
Tabel `androiddb_v0.sessions` masih kerangka. Tidak ada RPC produksi untuk reserve/start/connected/stop/settlement/watchdog. Remote Connect masih dikunci. Belum ada debit AniCoin berbasis durasi stream yang tervalidasi.

## Keputusan produk AniCoin

Nama satuan yang ditampilkan ke pengguna: **AniCoin**. Semua layar, ringkasan, top-up, tarif, lot, ledger, riwayat dan notifikasi harus konsisten menggunakan nama ini.

Tarif yang telah ditetapkan:
| GPU | Rupiah/jam | AniCoin/jam |
|---|---:|---:|
| GTX 1050 | Rp6.000 | 45 |
| GTX 1660 | Rp6.000 | 45 |
| RTX 3060 | Rp7.000 | 52,5 |
| RTX 5060 | Rp8.000 | 60 |

Kurs dasar Rp8.000 = 60 AniCoin.

Masa berlaku diterapkan pada lot AniCoin, bukan pada umur akun rental. Top-up statis QRIS hanya menjadi saldo setelah Owner mengonfirmasi pembayaran dan approve order. Order dan approval harus idempotent.

## Keputusan autentikasi Remote

Permintaan: tidak perlu pairing ulang untuk pengguna; pengguna masuk dengan User ID rental terdaftar; link "Daftar dulu" membuka WhatsApp 082298316902.

Pengamanan wajib: **User ID saja bukan faktor autentikasi**. User ID bisa diketahui orang lain; jika login hanya dengan ID, orang lain dapat mengambil wallet dan sesi pemilik akun. Desain aman yang tetap sederhana:
1. User ID + PIN/password akun.
2. PIN/password dibuat/dikonfirmasi pada pendaftaran melalui WhatsApp dan disimpan sebagai hash yang sesuai (tidak plaintext).
3. Tidak ada kode pairing per perangkat/client pada alur login pengguna.
4. Token tetap disimpan di Android Keystore, dengan rate limit, revocation, dan pembatasan sesi aktif.
5. Host Agent PC tetap menggunakan enrollment/identity trust terpisah; penghapusan pairing client tidak menghilangkan perlindungan Host PC.
6. Link "Daftar dulu" di bawah tombol login membuka `https://wa.me/6282298316902` dengan teks permintaan pendaftaran tanpa menyertakan password/PIN.

## Tahap kerja di GitHub

1. **Issue #1 — P0 audit PostgreSQL Termux.** Read-only diagnosis proses, PGDATA, socket, supervisor dan Node API. Buat backup setelah akses admin DB aman. Rancang pengelolaan service kompatibel dengan cluster existing; jangan restart mendadak.
2. **Issue #2 — DB AniCoin v0.** Inventaris DB aktif, pastikan target database, backup database/roles, verifikasi signature, apply migration 025, update Node API/allowlist dan health check pada Redmi.
3. **Issue #3 — API/aturan AniCoin.** Samakan skala, tarif, expiry lot, FIFO, saldo wallet/ledger, rounding, idempotency dan transaksi serentak.
4. **Issue #4 — Admin Android DB v0.** Sinkronkan semua menu/tombol ke RPC v0, menambah pengelolaan credential akun, gunakan label AniCoin, dan singkirkan jalur timer/expiry lama hanya dari Admin v0.
5. **Issue #5 — Remote login/registration.** Ganti kode aktivasi client dengan User ID + PIN/password, tambahkan link Daftar dulu ke WhatsApp, hapus pairing client per perangkat, tetap pertahankan enrollment Host Agent.
6. **Issue #6 — AniCoin session billing.** Audit callback StarDesk yang nyata, implementasikan state machine dan debit/refund proporsional durasi, watchdog dan idempotency. Connect tetap dikunci sebelum selesai.
7. **Issue #7 — End-to-end release.** Tes live Redmi, gateway/relay, Admin, Remote, top-up, wallet, PC streaming, debit/stop dan regresi sistem timer lama. Hanya setelah semua gate lulus boleh diberi status production.

## Gate perlindungan sistem lama

- Jangan drop/truncate/rename tabel core atau rental lama.
- Jangan menjalankan migration v0 pada proyek Supabase atau database yang bukan Android DB Termux aktif.
- Jangan mengalihkan DATABASE_URL ke DB lain.
- Jangan membuat cluster kedua.
- Jangan menimpa APK lama atau main branch.
- Semua write migration harus additive; backup/rollback diverifikasi.
- Uji regresi Admin lama, PC Billing, reseller dan timer rental lama sebelum rilis v0.

## Checklist read-only untuk dikirim dari Redmi

Jalankan di Termux. Semua perintah ini hanya membaca status; jangan jalankan `sv up/down`, `pg_ctl start/stop`, atau perintah installer lagi dahulu.

```bash
echo "== PREFIX / Termux =="
echo "$PREFIX"

echo "== PGDATA candidates =="
for d in "$PREFIX/var/lib/postgresql" "$HOME/.postgres"; do
  echo "--- $d"
  if [ -d "$d" ]; then
    [ -f "$d/PG_VERSION" ] && cat "$d/PG_VERSION" || echo "PG_VERSION tidak ada"
    [ -f "$d/postmaster.pid" ] && sed -n '1,8p' "$d/postmaster.pid" || echo "postmaster.pid tidak ada"
  else
    echo "folder tidak ada"
  fi
done

echo "== PostgreSQL processes =="
ps -ef | grep '[p]ostgres'

echo "== Node API processes =="
ps -ef | grep '[n]ode.*server.mjs'

echo "== PostgreSQL ready =="
pg_isready -h "$PREFIX/tmp" -p 5432; echo "pg_isready exit=$?"

echo "== runit postgres status =="
sv status postgres 2>&1

echo "== runit services =="
ls -la "$PREFIX/var/service" 2>/dev/null

echo "== local API health =="
curl -i --max-time 5 http://127.0.0.1:8787/health
```

Jangan kirim isi `.env`, password, API key, token Blynk atau credential database. Jika output memuat nama database/host internal, boleh disamarkan sebagian tetapi pertahankan versi, PID, port, path dan status servicenya.

## Status

Audit source/CI: selesai untuk tahap rencana.
Audit live DB/Termux: terblokir menunggu output read-only.
Migration 025 live: belum terbukti.
Admin/Remote real-device: belum lulus acceptance test.
AniCoin debit session: belum diimplementasikan.
Main branch: tetap tidak diubah.
