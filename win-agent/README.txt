ANI GAMES READY — STAR DESK WINDOWS AGENT
Preview version 0.2.8 — Windows x64

ISI PAKET
- Agent.Service/AniGamesReady.Agent.Service.exe : Windows Service (host/API/coin meter).
- Agent.Tray/AniGamesReady.Agent.Tray.exe         : UI watcher pada sesi desktop Windows.
- Agent.Tray/tessdata/eng.traineddata             : data OCR.
- install.ps1                                     : install/upgrade Windows Service + Tray.
- uninstall.ps1                                   : uninstall program, mempertahankan credential Agent di ProgramData.

PERSYARATAN
- Windows 10 atau Windows 11 x64.
- Internet HTTPS ke API StarDesk Custom yang sudah menjalankan migrasi DB 031.
- Hak Administrator untuk install/upgrade.
- StarDesk Desktop terpasang oleh pemilik PC dari sumber resmi dan sudah login sesuai akun StarDesk milik pengguna PC.

INSTALL / UPGRADE
1. Ekstrak seluruh ZIP ini ke folder biasa, misalnya Downloads\StarDesk-Agent-0.2.8.
2. Buka PowerShell sebagai Administrator.
3. Jalankan:
   powershell -ExecutionPolicy Bypass -File .\install.ps1
4. Agent Service dipasang atau diperbarui; Tray dijalankan pada sesi pengguna Windows.
5. Pada instalasi pertama, salin kode pairing 8 digit di jendela Agent lalu masukkan di Admin > Agent PC.
6. Untuk PC yang sudah paired, upgrade mempertahankan credential DPAPI di ProgramData. Tidak perlu pairing ulang selama file credential tidak dihapus.

CARA KERJA EVENT-DRIVEN
- Agent 0.2.8 tidak lagi menjalankan auto-sync Copy & Share setiap 4 detik.
- Tray memakai Windows WinEvent untuk memantau perubahan jendela StarDesk. Event yang beruntun digabung dengan debounce singkat.
- Pemeriksaan status sesi membaca UI tanpa menekan Copy & Share dan tidak pernah memanggil perintah Windows untuk menampilkan/memulihkan jendela StarDesk.
- Saat sesi remote terdeteksi aktif, Agent standby: tidak membaca/copy/sync kredensial. Jendela StarDesk boleh tetap diminimalkan tanpa dibuka ulang oleh Agent.
- Copy & Share hanya dicoba satu kali setelah PC terbukti idle saat StarDesk baru dibuka, sesi remote selesai, atau pairing berubah.
- Jika sesi berakhir ketika jendela masih minimized, event sync ditahan sampai StarDesk ditampilkan kembali oleh pengguna. Agent tidak membuka jendela secara otomatis.
- Jika sync gagal, Agent menampilkan kode penyebab backend yang sudah difilter; tidak menampilkan token undangan atau Verification Code.
- Snapshot atomik berisi Device ID, Verification Code, dan Invite URL. URL hanya diterima dari host https://app.stardesk.net dengan path /invite/<token> dan parameter lang opsional.
- Fingerprint tiga field dibandingkan. Snapshot yang sama tidak ditulis ulang ke DB.
- Verification Code dan Invite URL dienkripsi AES-256-GCM oleh API sebelum disimpan.
- Log/status Agent tidak menampilkan Verification Code atau Invite URL.

COIN SESSION
- User memilih PC dan meminta sesi dari Remote APK. DB membuat reservasi requested dan mengunci satu akun + satu PC.
- Debit hanya dimulai setelah Agent melihat status StarDesk remote benar-benar aktif dan DB mengikat event itu ke reservasi PC yang sedang menunggu.
- Tarif disalin dari rental_pcs.hourly_coin_units saat reservasi. Perubahan tarif berikutnya tidak mengubah tarif sesi berjalan.
- Debit server dihitung prorata per detik dengan unit internal 1 Coin = 100 unit.
- Contoh: 60 Coin/jam = 1 Coin/menit. Timer UI HP bukan sumber tagihan.
- Event sesi berakhir yang terkonfirmasi menutup tagihan dan melepas lock PC. Jika Agent/monitor hilang, meter membatasi waktu tak terkonfirmasi maksimal 45 detik lalu menutup billing, tetapi PC tetap terkunci sampai Agent kembali dan memastikan StarDesk idle/tertutup.
- Heartbeat monitor lokal/DB dan meter Coin berkala adalah jalur status/billing terpisah; keduanya TIDAK menekan Copy & Share dan tidak mengirim ulang kredensial.

STATUS DAN BATASAN
- Agent Online hanya menunjukkan Service/API heartbeat; kesiapan host juga mensyaratkan Tray monitor dan pairing tersedia.
- Build 0.2.8 adalah kandidat perubahan. Kelulusan CI dan hasil build EXE harus diperiksa pada workflow terbaru sebelum instalasi. Build berhasil pun belum membuktikan UI StarDesk terdeteksi konsisten pada semua tampilan/versi/overlay Windows.
- Uji perangkat nyata tetap wajib untuk sesi mulai, sesi berakhir, aplikasi ditutup, minimize, remote reconnect, dan API/network loss.
- Remote APK belum dihubungkan pada tahap build ini ke API request-session/status; tombol Play/countdown belum dirilis.
- Saat saldo habis, DB menghentikan billing dan menutup lifecycle Coin. Agent belum mempunyai kontrol resmi untuk memutus streaming StarDesk; jangan menganggap stream sudah pasti terputus.
- Undangan StarDesk belum terbukti single-use atau tak bisa diteruskan. Kunci akun/PC pada DB bukan jaminan bahwa provider mengunci invite URL ke satu pengguna secara kriptografis.
- Jangan gunakan PC yang sedang dipakai pelanggan untuk pengujian awal Agent/upgrade.

UNINSTALL
Jalankan sebagai Administrator:
   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1

Uninstaller menghapus Service, Tray, shortcut, dan folder program, tetapi sengaja mempertahankan credential/identitas Agent di ProgramData agar reinstall dapat memakai pairing yang sama. Cabut pairing melalui Admin bila PC dipensiunkan.

