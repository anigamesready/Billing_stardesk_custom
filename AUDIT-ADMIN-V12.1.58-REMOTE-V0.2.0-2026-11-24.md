# Audit statis APK StarDesk — 24 November 2026

## Ringkasan keputusan

Dua APK yang dipilih pengguna sebagai baseline sudah diperiksa secara statis dari binary yang tersimpan di repository ini. **Keduanya belum boleh dinyatakan sebagai rilis produksi.** APK Admin masih membawa sisa konsep DB1/DB2 dalam HTML/JavaScript yang hanya disembunyikan oleh CSS, sedangkan APK Remote secara eksplisit masih berupa preview dengan data contoh dan belum terhubung ke Android DB.

Tidak ada APK baru yang dibangun dalam audit ini. Repository saat ini berisi APK dan dokumentasi, tetapi belum menyediakan source Android/Gradle yang cukup untuk mengubah dan membangun ulang aplikasi secara aman. Tidak ada pengujian instalasi/perangkat nyata, login ke backend, transaksi DB, atau sesi remote aktual yang dapat diklaim lulus.

## Sumber dan identitas artefak

Repo: https://github.com/anigamesready/Billing_stardesk_custom  
Default branch saat audit: `main`  
Commit upload kedua APK: `5c2a4e14dbbad696ddd30e348b48c149a8b8f36a`

| Aplikasi | File | Git blob SHA |
|---|---|---|
| Admin | `AniGames-Admin-Online-V12.1.58-SAFE-TEST.apk` | `448314b7adf5f5445092610c7a90ba9f36b1a066` |
| Remote | `Ani-Games-Ready-Remote-AndroidDB-Preview-v0.2.0.apk` | `0d8c84047af58090792e703de87d4fd7bc27c6ee` |

## 1. Admin v12.1.58 — hasil audit statis

### Metadata APK
- Package: `com.anigames.billingadmin.v158online`
- Version name/code: `12.1.58 / 85`
- Min SDK / target SDK: `26 / 35`
- Permissions: `INTERNET`, `POST_NOTIFICATIONS`, `VIBRATE`
- Application label: `AniGames Admin Online V12.1.58 SAFE TEST`
- Manifest menetapkan `android:debuggable=true`.
- Manifest menetapkan `usesCleartextTraffic=false`.
- Activity memiliki launcher intent dan custom deep link `anigamesadmin://recovery`.

### Temuan arsitektur dan UI
- Paket memuat layar/admin logic utama sebagai aset web: `assets/web/admin.html` (224,742 byte setelah ekstraksi), `admin-control.html`, `index.html`, `billing.html`, dan `v11-cloud.js`.
- Kode legacy dual DB masih ada di `admin.html`: terdapat `dualDbReadinessPanel`, referensi DB1/DB2, `globalDbTarget`, `databaseTools`, dan fungsi pergantian target. Sebagian navigasi/panel disembunyikan menggunakan CSS. Menyembunyikan elemen saja belum memenuhi keputusan proyek untuk membersihkan total konsep DB1/DB2 dari menu dan implementasi yang tidak dipakai.
- `admin-control.html` menggunakan gateway bernama `ani-games-db-android-stage-gateway.anigamesready.workers.dev` dan relay bernama `ani-games-db-android-stage-ws-relay.anigamesready.workers.dev`. Konfigurasi environment `stage` wajib diverifikasi terhadap endpoint Android DB yang memang akan dipakai untuk produksi.
- Paket juga menyertakan `billing.html` bergaya PC Billing V11 dengan pola `localStorage` untuk `billing_db_users` dan mekanisme backup IndexedDB/local. Pastikan apakah halaman ini memang bagian aktif aplikasi Admin baru; bila tidak, jangan bawa aset dan alur legacy tersebut ke rilis StarDesk Android DB.
- Sumber eksternal CDN terlihat dipakai untuk library UI/admin. Ketergantungan jaringan/CDN dan kegagalan saat offline belum diuji runtime.

### Status Admin
**BELUM LULUS gerbang rilis produksi.** Blocker: debug build flag masih aktif; kode dual DB masih ikut dibundel; endpoint stage belum diverifikasi untuk produksi; aset Billing V11 lokal perlu ditelusuri; belum ada uji instalasi, login, CRUD DB, tombol, dan navigasi di perangkat.

## 2. Remote v0.2.0-preview — hasil audit statis

### Metadata APK
- Package: `com.anigamesready.stardeskclient`
- Version name/code: `0.2.0-preview / 2`
- Min SDK / target SDK: `26 / 35`
- Permission: `INTERNET`
- Application label: `Ani Games Ready Remote`
- Manifest menetapkan `android:debuggable=true` dan `allowBackup=false`.
- Main activity dipaksa ke orientasi landscape.
- Launcher activity menyediakan custom URI scheme `anigamesremote`.

### Temuan fungsi dan UI
- Aset utama hanya `assets/index.html` (17,308 byte setelah ekstraksi) dan gambar QRIS.
- Halaman login menyebut User ID rental dan dashboard saldo, tetapi halaman itu sendiri secara eksplisit menampilkan pemberitahuan: mode pratinjau menggunakan data contoh, belum mengakses Android DB, dan belum membuat transaksi sungguhan.
- Daftar PC/GPU dan status READY/DIPAKAI/OFFLINE yang terlihat merupakan data contoh dalam HTML, bukan status live yang terbukti berasal dari DB.
- Tidak ditemukan pemanggilan `fetch`/XHR atau referensi deep link `stardesk://external/device/control` di aset HTML yang diekstrak. Integrasi native lain belum diverifikasi, sehingga tidak boleh dinyatakan berfungsi.
- UI memberi keterangan bahwa akun lama yang expired tetap dapat login; alur pembatasan akses aktual pada titik koneksi belum terbukti. Aturan proyek tetap: akun expired atau saldo nol harus ditolak saat otorisasi koneksi, bukan hanya disembunyikan di UI.

### Status Remote
**BELUM LULUS gerbang rilis produksi.** Ini masih preview/demo; integrasi Android DB, verifikasi saldo/expired, data PC live, pemetaan device ID, deep link/launch StarDesk, dan sesi remote aktual belum terbukti. Debug build flag juga masih aktif.

## 3. Source dan build reproducible

Pada `main`, file yang tersedia di root adalah APK StarDesk upstream, dua APK Ani Games, dan README singkat. Pemeriksaan lokasi Android source umum pada branch `stardesk-androiddb-preview-v2`, `stardesk-client-v1`, dan `stardesk-ui-v1` tidak menemukan `settings.gradle`, `app/build.gradle`, atau `app/src/main/AndroidManifest.xml` di path standar. Karena source proyek editable/build pipeline tidak tersedia, tidak aman mengubah binary APK secara langsung atau mengklaim telah membangun APK baru dari source terbaru.

## 4. Syarat sebelum kandidat rilis

1. Masukkan source Android/Gradle lengkap untuk Admin dan Remote ke repo ini.
2. Jadikan Android DB satu-satunya jalur DB; hapus markup, fungsi, konfigurasi, dan menu dual DB yang tersisa—bukan sekadar menyembunyikannya dengan CSS.
3. Verifikasi dan pisahkan konfigurasi stage/production; jangan memasukkan endpoint stage ke rilis produksi tanpa persetujuan/verifikasi.
4. Pastikan Remote terhubung ke Android DB nyata, memuat status PC live, memvalidasi saldo dan expired di server/authorization boundary, memetakan device ID, lalu meluncurkan StarDesk dengan handoff yang sudah diuji.
5. Matikan debuggable untuk build rilis, periksa signing, permissions, exported components, backup, dan keamanan konfigurasi.
6. Install kandidat APK baru pada perangkat Android; uji semua tombol, login sukses/gagal, DB read/write, empty/offline/timeout, saldo nol/expired, refresh PC, pemilihan PC, logout, dan sesi remote aktual.
7. Catat versi/hash kandidat dan bukti uji. APK tetap berstatus TEST sampai semua pemeriksaan wajib lulus.

## Kesimpulan

v12.1.58 Admin dipakai sebagai **baseline audit Admin saat ini**, bukan sebagai rilis produksi yang sudah disetujui. Remote v0.2.0 dipakai sebagai **baseline preview Remote**, bukan aplikasi operasional. Tidak ada source-level changes atau APK baru yang dibuat dalam audit ini; dua APK di repository tetap utuh.
