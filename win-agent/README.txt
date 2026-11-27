ANI GAMES READY — STAR DESK WINDOWS AGENT
Preview version 0.2.1

PERSYARATAN
- Windows 10 / Windows 11 x64.
- Koneksi internet HTTPS.
- Izin Administrator untuk memasang Windows Service.

CARA INSTAL PALING MUDAH (SATU KLIK)
1. Unduh file Ani-Games-Ready-StarDesk-Agent-Setup-0.2.1-win-x64.exe.
2. Klik dua kali Setup.exe.
3. Saat Windows menampilkan UAC, pilih Yes.
4. Installer otomatis memasang atau memperbarui Windows Service dan tray Agent.
5. Jendela Ani Games Ready StarDesk Agent akan terbuka. Pada instalasi pertama, salin kode pairing 8 digit dan pasangkan melalui Admin > Agent PC.
6. Bila Agent versi lama sudah terpasang, installer akan mempertahankan credential DPAPI dan pairing; tidak perlu pairing ulang.
7. Agent otomatis berjalan kembali saat Windows boot dan tray terbuka saat pengguna Windows login.

Tidak perlu mengekstrak ZIP, membuka PowerShell, atau mengetik perintah untuk pemasangan normal. ZIP update dan skrip manual tetap disediakan untuk troubleshooting/admin lanjutan.

FITUR
- Windows Service otomatis mulai saat Windows boot.
- Tray UI otomatis mulai saat user Windows login.
- Tutup jendela / X hanya menyembunyikan UI ke system tray; service tidak dihentikan.
- Heartbeat Agent terpisah dari PC Billing lama.
- Owner dapat mengganti nama PC dan kelas GPU/tarif dari Admin.
- Perintah allowlist: pesan, logoff Windows, restart Windows dan shutdown.
- Akses token Agent dilindungi Windows DPAPI untuk akun Windows Service LocalSystem.
- Restart dan shutdown dijadwalkan 10 detik tanpa opsi force-close aplikasi.
- Pesan Windows dilaporkan sebagai accepted/delivered by msg.exe; tampilan yang benar-benar terlihat pengguna tidak dapat diverifikasi.
- Revoke pairing dari Admin untuk memutus akses Agent.

BATASAN PREVIEW
- Agent Online hanya berarti heartbeat Windows aktif.
- Tombol **Sinkronkan StarDesk** mencoba membaca Device ID dan Verification Code dari jendela StarDesk memakai Windows UI Automation.
- Jika salah satu nilai tidak terbaca, Agent membuka form fallback untuk mengisi Device ID dan Verification Code secara manual; nilai yang sempat terbaca otomatis akan diisikan.
- Device ID bernomor yang tampil berkelompok (contoh 861 260 101) dinormalisasi menjadi 861260101 saat disimpan.
- Agent mengirim hasil melalui local named pipe ber-ACL ke Windows Service. API Android DB mengenkripsi verification code dengan AES-256-GCM sebelum disimpan; plaintext tidak disimpan di file status Agent dan tidak dikirim ke Remote APK.
- Device ID disimpan untuk pemetaan PC. Verification code bersifat sensitif dan bisa berubah/berakhir; ciphertext-nya tidak dipakai sebagai kode Remote Assist permanen.
- Belum ada kontrol streaming atau callback mulai/berhenti sesi. Agent Online bukan bukti streaming aktif dan belum ada pemotongan AniCoin.
- GPU name hardware masih dapat belum terdeteksi otomatis; Owner memilih kelas GPU/tarif dari Admin.
- Uji perintah shutdown/logoff hanya pada PC uji yang tidak sedang dipakai.

UNINSTALL
Jalankan sebagai Administrator:
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1

Identitas dan credential di ProgramData dipertahankan agar reinstall dapat memakai Agent Device ID yang sama. Cabut pairing dari Admin sebelum PC dipensiunkan.


UPDATE DARI PREVIEW 0.1.0 KE 0.2.1 (TANPA PAIRING ULANG)\n\nCara paling mudah: jalankan Setup.exe satu kali. Setup mendeteksi service lama, menghentikannya sementara, mengganti Agent, lalu menjalankannya kembali tanpa menghapus credential atau pairing. Tidak perlu menjalankan update.ps1 secara manual.
1. Ekstrak ZIP update ke satu folder.
2. Klik kanan PowerShell, pilih Run as administrator.
3. Jalankan:
   powershell -ExecutionPolicy Bypass -File .\update.ps1
4. Script menghentikan Windows Service dan tray sebentar, mengganti binary, lalu menjalankan kembali.
5. Credential Agent dan Agent Device ID yang dilindungi DPAPI tetap dipakai. Jangan jalankan uninstall.ps1 dan jangan hapus folder ProgramData.
6. Buka StarDesk Windows > Remote Support untuk melihat Device ID; pastikan Verification/Custom Code yang dipakai pada PC tersebut sudah diketahui.
7. Buka tray Ani Games Ready StarDesk Agent, klik **Sinkronkan StarDesk**.
8. Agent mencoba membaca nilai otomatis. Jika tidak lengkap, form manual muncul untuk mengisi nilai yang belum terbaca.
9. Bila berhasil, Device ID dan waktu sinkron tampil di tray dan menu Agent PC Admin. Verification Code tidak ditampilkan kembali.
