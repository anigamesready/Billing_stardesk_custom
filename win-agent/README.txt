ANI GAMES READY — STAR DESK WINDOWS AGENT
Preview version 0.1.0

PERSYARATAN
- Windows 10 / Windows 11 x64.
- Koneksi internet HTTPS.
- Jalankan install.ps1 menggunakan PowerShell Administrator.

CARA INSTAL
1. Ekstrak seluruh isi ZIP ke satu folder.
2. Klik kanan PowerShell, pilih Run as administrator.
3. Jalankan:
   powershell -ExecutionPolicy Bypass -File .\install.ps1
4. Aplikasi Agent akan muncul di taskbar / system tray.
5. Buka Agent dan salin kode pairing 8 digit.
6. Masuk ke Admin Android DB v0 > Agent PC.
7. Isi kode, nama PC dan kelas GPU, lalu tekan Setujui & pasangkan Agent.
8. Tunggu Agent menampilkan ONLINE.

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
- Belum memvalidasi StarDesk Device ID/custom code dan belum membuktikan host streaming.
- Tidak ada auto-login StarDesk, tidak ada kontrol stream, dan tidak ada pemotongan AniCoin.
- GPU name hardware masih dapat belum terdeteksi otomatis; Owner memilih kelas GPU/tarif dari Admin.
- Uji perintah shutdown/logoff hanya pada PC uji yang tidak sedang dipakai.

UNINSTALL
Jalankan sebagai Administrator:
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1

Identitas dan credential di ProgramData dipertahankan agar reinstall dapat memakai Agent Device ID yang sama. Cabut pairing dari Admin sebelum PC dipensiunkan.
