ANI GAMES READY — STAR DESK WINDOWS AGENT
Preview version 0.2.5

PERSYARATAN
- Windows 10 / Windows 11 x64.
- Koneksi internet HTTPS.
- Izin Administrator untuk memasang Windows Service.

CARA INSTAL PALING MUDAH (SATU KLIK)
1. Unduh file Ani-Games-Ready-StarDesk-Agent-Setup-0.2.5-win-x64.exe.
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
- Agent memantau StarDesk otomatis setiap 4 detik. Bila teks UI Automation tidak lengkap, Agent menekan tombol Copy milik StarDesk untuk menyalin Device ID dan Verification Code langsung dari aplikasi.
- Jika StarDesk diminimalkan atau disembunyikan ke tray tetapi prosesnya masih berjalan, Agent membangunkan jendela tanpa mengambil fokus, melakukan Copy, lalu mengembalikan keadaan jendela semula. Kode baru harus stabil sebelum dikirim. Tombol manual tetap tersedia sebagai fallback.
- Device ID bernomor yang tampil berkelompok (contoh 259 397 349) dinormalisasi menjadi 259397349 saat disimpan. Kode temporer hanya berada di memori selama proses capture dan tidak dicatat ke log atau file status.
- Agent mengirim kode baru melalui local named pipe ber-ACL ke Windows Service. API Android DB mengenkripsi verification code dengan AES-256-GCM sebelum disimpan; plaintext tidak disimpan di file status Agent dan tidak dikirim ke Remote APK. Watcher tidak melakukan request jaringan selama kode tidak berubah.
- Device ID disimpan untuk pemetaan PC. Verification code bersifat sensitif dan bisa berubah/berakhir; ciphertext-nya tidak dipakai sebagai kode Remote Assist permanen.
- Belum ada kontrol streaming atau callback mulai/berhenti sesi. Agent Online bukan bukti streaming aktif dan belum ada pemotongan AniCoin.
- GPU name hardware masih dapat belum terdeteksi otomatis; Owner memilih kelas GPU/tarif dari Admin.
- Uji perintah shutdown/logoff hanya pada PC uji yang tidak sedang dipakai.

UNINSTALL
Jalankan sebagai Administrator:
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1

Identitas dan credential di ProgramData dipertahankan agar reinstall dapat memakai Agent Device ID yang sama. Cabut pairing dari Admin sebelum PC dipensiunkan.


UPDATE DARI PREVIEW 0.1.0 KE 0.2.5 (TANPA PAIRING ULANG)\n\nCara paling mudah: jalankan Setup.exe satu kali. Setup mendeteksi service lama, menghentikannya sementara, mengganti Agent, lalu menjalankannya kembali tanpa menghapus credential atau pairing. Tidak perlu menjalankan update.ps1 secara manual.
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


FITUR OTOMATIS 0.2.5
- Auto-sync membaca halaman Remote Support setiap 4 detik selama tray Agent berjalan.
- Verification Code 8 karakter diambil berdasarkan posisi di bawah label Verification Method; Device ID dinormalisasi otomatis.
- Jika UI menyatakan PC sedang dikontrol, sinkronisasi ditahan sampai sesi selesai. Nilai harus stabil dua pembacaan; bila status sesi tidak terdeteksi, Agent menunggu setidaknya 15 detik dan empat pembacaan.
- Hanya kode yang berubah (atau transisi sesi aktif ke selesai) dikirim ke server. Tidak ada polling jaringan selama kode tetap sama.
- Kode plaintext hanya berada di memori dan dikirim lewat named pipe lokal; API mengenkripsi kode sebelum database menyimpan ciphertext.


CATATAN 0.2.5
- Parser tidak pernah menerima "STARDESK" atau kata generik lain sebagai verification code.
- Copy button automation memakai Windows UI Automation InvokePattern. Isi clipboard pengguna dipulihkan setelah pembacaan.
- Jika proses StarDesk benar-benar keluar (bukan hanya hidden/minimized), Agent belum dapat membaca kode baru sampai StarDesk dijalankan lagi.


PEMBACAAN STAR DESK 0.2.5
- Jendela utama dipilih dari HWND top-level milik proses StarDesk, diprioritaskan berdasarkan judul dan ukuran jendela. Agent tidak berhenti hanya karena menemukan jendela helper pertama.
- Device ID hanya diterima dari pola Device ID yang cocok dan pembacaan terikat posisi label; angka dari Recent Connections tidak boleh dipilih secara acak.
- Verification Code hanya diterima dari label yang eksplisit atau elemen yang berada pada baris tepat di bawah Verification Method. Pencarian urutan descendant yang sebelumnya dapat mengambil kata "KARAKTER" sudah dihapus.
- Tombol Copy harus benar-benar ditemukan dan berhasil Invoke/LegacyIAccessible, lalu nomor urut clipboard Windows harus berubah. Clipboard lama tidak akan dipakai sebagai hasil baru.
- Hasil Copy harus berisi Device ID dan kode yang terlabel atau berada pada satu baris khusus yang berisi tepat 8 karakter. Clipboard lama pengguna dipulihkan kecuali telah berubah lagi oleh aplikasi lain.
- Dialog fallback menampilkan status diagnostik aman: jumlah jendela, jumlah elemen UIA, status ID/kode, tombol Copy, dan perubahan clipboard. Isi kode tidak ditulis ke log.
- Auto-copy dibatasi satu percobaan per 25 detik; tombol manual memaksa satu percobaan baru.


STAR DESK WATCHER + OCR LOKAL 0.2.5
- Hanya proses desktop utama yang namanya diawali StarDesk dan bukan USBIP/Monitor/Helper/Updater/Crash yang menjadi kandidat. Proses StarDeskUsbipDeviceMonitor diabaikan.
- Jendela utama diprioritaskan melalui Process.MainWindowHandle dan HWND pada PID proses utama. Pencarian berdasarkan judul "StarDesk" dari proses helper sudah dihapus.
- Jika UI Automation dan tombol Copy tidak memberi pasangan lengkap, Agent menangkap gambar jendela dengan PrintWindow dan menjalankan Tesseract OCR lokal di memori PC. Screenshot, teks OCR, dan kode tidak diunggah atau disimpan ke file.
- OCR hanya menerima satu baris yang berisi Device ID 9 digit dan satu token kode 8 karakter di sebelah kanannya, setelah label Remote Support, This Device, dan Verification Method dikenali.
- Jika jendela tersembunyi/minimized tidak bisa dirender oleh Windows PrintWindow, Agent melaporkan alasan dan tidak mengirim data tebakan.
- Model English berada dalam folder tessdata yang ikut paket Tray. Engine TesseractOCR membutuhkan Microsoft Visual C++ 2015-2022 x64; Setup memeriksa runtime dan memasangnya dari Microsoft bila belum tersedia.
- Auto OCR dibatasi satu kali setiap 6 detik. Timer status tetap berjalan setiap 4 detik; tombol manual memaksa capture baru.
