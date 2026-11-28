using System.Drawing;
using System.Windows.Forms;
using AniGamesReady.Agent.Shared;

namespace AniGamesReady.Agent.Tray;

public sealed class AgentTrayForm : Form
{
    private readonly Label stateLabel = new();
    private readonly Label detailLabel = new();
    private readonly Label deviceIdLabel = new();
    private readonly Label codeLabel = new();
    private readonly Button copyButton = new();
    private readonly Button refreshButton = new();
    private readonly Button syncButton = new();
    private readonly Label starDeskLabel = new();
    private readonly Label autoSyncLabel = new();
    private readonly NotifyIcon trayIcon;
    private readonly System.Windows.Forms.Timer refreshTimer = new();
    private readonly System.Windows.Forms.Timer monitorHeartbeatTimer = new();
    private AgentStatus? currentStatus;
    private bool allowClose;
    private bool manualSyncBusy;
    private bool monitorHeartbeatBusy;
    private string lastSyncedFingerprint = "";
    private string lastObservedPairFingerprint = "";
    private bool? previousSessionActive;
    private bool remoteSessionStateKnown;
    private bool remoteSessionActive;
    private bool pendingSyncAfterIdle;
    private bool starDeskWindowWasOpen;
    private CancellationTokenSource? starDeskEventDebounce;
    private StarDeskWindowEventWatcher? starDeskWatcher;
    private readonly SemaphoreSlim sessionEventGate = new(1, 1);

    public AgentTrayForm()
    {
        Text = "Ani Games Ready — StarDesk Agent";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = true;
        ClientSize = new Size(520, 382);
        BackColor = Color.FromArgb(7, 16, 31);
        ForeColor = Color.FromArgb(237, 246, 255);
        Font = new Font("Segoe UI", 9F);

        var brand = new Label
        {
            Text = "ANI GAMES READY  •  STAR DESK AGENT",
            ForeColor = Color.FromArgb(85, 216, 255),
            Font = new Font("Segoe UI", 12F, FontStyle.Bold),
            AutoSize = false,
            Location = new Point(22, 18),
            Size = new Size(475, 30)
        };
        Controls.Add(brand);

        stateLabel.SetBounds(22, 62, 470, 36);
        stateLabel.Font = new Font("Segoe UI", 16F, FontStyle.Bold);
        stateLabel.Text = "MEMUAT STATUS…";
        Controls.Add(stateLabel);

        detailLabel.SetBounds(22, 105, 475, 52);
        detailLabel.ForeColor = Color.FromArgb(160, 184, 207);
        detailLabel.Text = "Service Windows bekerja di latar belakang.";
        detailLabel.AutoEllipsis = true;
        Controls.Add(detailLabel);

        deviceIdLabel.SetBounds(22, 168, 475, 34);
        deviceIdLabel.ForeColor = Color.FromArgb(181, 209, 232);
        Controls.Add(deviceIdLabel);

        codeLabel.SetBounds(22, 207, 475, 42);
        codeLabel.Font = new Font("Consolas", 22F, FontStyle.Bold);
        codeLabel.ForeColor = Color.FromArgb(142, 233, 255);
        Controls.Add(codeLabel);

        copyButton.Text = "Salin kode pairing";
        copyButton.SetBounds(22, 302, 160, 38);
        copyButton.Click += (_, _) => CopyPairingCode();
        Controls.Add(copyButton);

        starDeskLabel.SetBounds(22, 246, 475, 18);
        starDeskLabel.ForeColor = Color.FromArgb(151, 225, 255);
        starDeskLabel.Text = "StarDesk: belum disinkronkan";
        starDeskLabel.AutoEllipsis = true;
        Controls.Add(starDeskLabel);

        autoSyncLabel.SetBounds(22, 268, 475, 20);
        autoSyncLabel.ForeColor = Color.FromArgb(112, 237, 189);
        autoSyncLabel.AutoEllipsis = true;
        autoSyncLabel.Text = "Auto-sync: menunggu Windows Agent dipasangkan.";
        Controls.Add(autoSyncLabel);

        refreshButton.Text = "Refresh status";
        refreshButton.SetBounds(190, 302, 135, 38);
        refreshButton.Click += (_, _) => RefreshStatus();
        Controls.Add(refreshButton);

        syncButton.Text = "Sinkronkan StarDesk";
        syncButton.SetBounds(335, 302, 162, 38);
        syncButton.Click += async (_, _) => await SyncStarDeskAsync();
        syncButton.Enabled = false;
        Controls.Add(syncButton);

        var foot = new Label
        {
            Text = "Tutup jendela atau tekan X untuk menyembunyikan ke system tray. Service Agent tetap berjalan.",
            ForeColor = Color.FromArgb(125, 151, 178),
            AutoSize = false,
            Location = new Point(22, 350),
            Size = new Size(475, 24),
            Font = new Font("Segoe UI", 8F)
        };
        Controls.Add(foot);

        var menu = new ContextMenuStrip();
        menu.Items.Add("Buka Ani Games Ready Agent", null, (_, _) => ShowWindow());
        menu.Items.Add("Salin kode pairing", null, (_, _) => CopyPairingCode());
        menu.Items.Add("Sinkronkan StarDesk", null, async (_, _) => await SyncStarDeskAsync());
        menu.Items.Add("Sembunyikan ke tray", null, (_, _) => HideWindow());

        trayIcon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "Ani Games Ready StarDesk Agent",
            Visible = true,
            ContextMenuStrip = menu
        };
        trayIcon.DoubleClick += (_, _) => ShowWindow();

        refreshTimer.Interval = 2000;
        refreshTimer.Tick += (_, _) => RefreshStatus();
        refreshTimer.Start();

        // Local liveness only: this does not copy credentials or sync the pairing.
        monitorHeartbeatTimer.Interval = 15000;
        monitorHeartbeatTimer.Tick += async (_, _) => await SendMonitorHeartbeatAsync();
        monitorHeartbeatTimer.Start();

        try
        {
            starDeskWatcher = new StarDeskWindowEventWatcher();
            starDeskWatcher.StarDeskChanged += OnStarDeskWindowChanged;
            autoSyncLabel.Text = "Event sync: memantau perubahan jendela StarDesk.";
        }
        catch
        {
            autoSyncLabel.Text = "Event sync belum aktif. Restart Agent setelah memeriksa izin Windows.";
        }

        Shown += async (_, _) =>
        {
            RefreshStatus();
            if (currentStatus?.IsPaired == true &&
                System.Diagnostics.Process.GetProcessesByName("StarDesk").Length == 0)
            {
                // Reconcile a host that may have been left locked by a previous monitor_lost.
                // A service restart or Tray restart must not leave the PC stuck indefinitely.
                await SendSessionEventOnceAsync("ended", CancellationToken.None);
                previousSessionActive = false;
            }
            await ProbeStarDeskAsync(null, CancellationToken.None);
        };
        FormClosing += OnFormClosing;
        Resize += (_, _) => { if (WindowState == FormWindowState.Minimized) HideWindow(); };
    }

    private void RefreshStatus()
    {
        currentStatus = AgentStorage.ReadStatus();
        if (currentStatus is null)
        {
            stateLabel.Text = "SERVICE BELUM SIAP";
            stateLabel.ForeColor = Color.FromArgb(255, 209, 139);
            detailLabel.Text = "Pastikan Windows Service Ani Games Ready StarDesk Agent sudah terpasang dan berjalan.";
            deviceIdLabel.Text = "";
            codeLabel.Text = "";
            copyButton.Enabled = false;
            syncButton.Enabled = false;
            starDeskLabel.Text = "StarDesk: service belum siap";
            return;
        }

        stateLabel.Text = currentStatus.State;
        stateLabel.ForeColor = currentStatus.State switch
        {
            "ONLINE" => Color.FromArgb(112, 237, 189),
            "MENUNGGU OWNER" => Color.FromArgb(255, 209, 139),
            "REVOKED" or "ERROR" => Color.FromArgb(255, 157, 176),
            _ => Color.FromArgb(85, 216, 255)
        };
        detailLabel.Text = currentStatus.Message +
            (currentStatus.LastHeartbeatUtc.HasValue
                ? Environment.NewLine + "Heartbeat: " + currentStatus.LastHeartbeatUtc.Value.ToLocalTime().ToString("dd MMM yyyy HH:mm:ss")
                : "");
        deviceIdLabel.Text = "Agent Device ID: " + currentStatus.AgentDeviceId;
        codeLabel.Text = currentStatus.IsPaired || string.IsNullOrWhiteSpace(currentStatus.PairingCode)
            ? "PAIRING SUDAH SELESAI"
            : "KODE: " + currentStatus.PairingCode;
        copyButton.Enabled = !currentStatus.IsPaired && !string.IsNullOrWhiteSpace(currentStatus.PairingCode);
        // Disable manual capture while a remote user is connected. The state is kept
        // conservatively when a minimized window cannot be inspected.
        syncButton.Enabled = currentStatus.IsPaired &&
            (!remoteSessionStateKnown || !remoteSessionActive) && !manualSyncBusy;
        starDeskLabel.Text = string.IsNullOrWhiteSpace(currentStatus.StarDeskDeviceId)
            ? "StarDesk: belum disinkronkan"
            : "StarDesk ID: " + currentStatus.StarDeskDeviceId + " • " + (currentStatus.LastStarDeskSyncUtc?.ToLocalTime().ToString("dd MMM HH:mm:ss") ?? "tersimpan");
        autoSyncLabel.Text = currentStatus.IsPaired
            ? autoSyncLabel.Text
            : "Event sync: menunggu pairing Owner.";
        trayIcon.Text = "Ani Games Ready Agent • " + currentStatus.State;
    }

    private void CopyPairingCode()
    {
        RefreshStatus();
        var code = currentStatus?.PairingCode ?? "";
        if (code.Length != 8)
        {
            MessageBox.Show("Kode pairing belum tersedia atau Agent sudah dipasangkan.",
                "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        Clipboard.SetText(code);
        MessageBox.Show("Kode pairing berhasil disalin. Masukkan kode ini pada menu Agent PC di Admin Owner.",
            "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private static string Fingerprint(StarDeskCaptureSnapshot capture)
    {
        var material = capture.DeviceId + "\0" + capture.VerificationCode + "\0" + capture.InviteUrl;
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(material))).ToLowerInvariant();
    }

    private static string PairFingerprint(StarDeskCaptureSnapshot capture)
    {
        var material = capture.DeviceId + "\0" + capture.VerificationCode;
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(material))).ToLowerInvariant();
    }

    private async Task SendMonitorHeartbeatAsync()
    {
        if (monitorHeartbeatBusy || AgentStorage.ReadStatus()?.IsPaired != true)
            return;
        monitorHeartbeatBusy = true;
        try
        {
            await AgentCapturePipeClient.SendMonitorHeartbeatAsync();

            // Safety net: if the StarDesk process exits without a final WinEvent callback,
            // close any active Coin session. This check never reads/copies credentials.
            if (previousSessionActive == true &&
                System.Diagnostics.Process.GetProcessesByName("StarDesk").Length == 0)
            {
                await SendSessionEventOnceAsync("ended", CancellationToken.None);
                previousSessionActive = false;
                starDeskWindowWasOpen = false;
                autoSyncLabel.Text = "StarDesk sudah ditutup • sesi Coin dihentikan oleh watchdog.";
            }
        }
        catch
        {
            // The Windows Service expires the monitor lease if this local heartbeat stops.
        }
        finally
        {
            monitorHeartbeatBusy = false;
        }
    }

    private void OnStarDeskWindowChanged(object? sender, StarDeskWindowEventArgs e)
    {
        if (IsDisposed || Disposing) return;
        if (InvokeRequired)
        {
            try { BeginInvoke(new Action(() => QueueStarDeskProbe(e))); } catch { }
            return;
        }
        QueueStarDeskProbe(e);
    }

    private void QueueStarDeskProbe(StarDeskWindowEventArgs? e)
    {
        starDeskEventDebounce?.Cancel();
        starDeskEventDebounce?.Dispose();
        starDeskEventDebounce = new CancellationTokenSource();
        var token = starDeskEventDebounce.Token;
        _ = ProcessDebouncedStarDeskEventAsync(e, token);
    }

    private async Task ProcessDebouncedStarDeskEventAsync(
        StarDeskWindowEventArgs? e, CancellationToken cancellationToken)
    {
        try
        {
            // Coalesce bursts of WinEvent notifications into one state transition.
            await Task.Delay(TimeSpan.FromMilliseconds(850), cancellationToken);
            await ProbeStarDeskAsync(e, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception ex)
        {
            autoSyncLabel.Text = "Event sync gagal • " + SafeReason(ex.Message);
        }
    }

    private async Task ProbeStarDeskAsync(
        StarDeskWindowEventArgs? windowEvent, CancellationToken cancellationToken)
    {
        if (currentStatus?.IsPaired != true && AgentStorage.ReadStatus()?.IsPaired != true)
        {
            autoSyncLabel.Text = "Event sync: menunggu pairing Owner.";
            return;
        }

        if (windowEvent?.MainWindowDestroyed == true)
        {
            remoteSessionStateKnown = true;
            remoteSessionActive = false;
            starDeskWindowWasOpen = false;
            if (previousSessionActive == true)
            {
                pendingSyncAfterIdle = true;
                await SendSessionEventOnceAsync("ended", cancellationToken);
                previousSessionActive = false;
                autoSyncLabel.Text = "StarDesk ditutup • sesi rental dihentikan; sync menunggu StarDesk dibuka lagi.";
            }
            else
            {
                autoSyncLabel.Text = "Jendela StarDesk ditutup • tidak ada sesi aktif yang ditagih.";
            }
            RefreshStatus();
            return;
        }

        // Read UI state only. This pass never presses Copy & Share or changes clipboard.
        var observed = await Task.Run(
            () => StarDeskUiCapture.ReadPartial(allowCopy: false), cancellationToken);
        if (observed.RemoteSessionStateKnown)
        {
            remoteSessionStateKnown = true;
            remoteSessionActive = observed.RemoteSessionActive;
            RefreshStatus();
        }

        if (observed.RemoteSessionStateKnown && observed.RemoteSessionActive)
        {
            starDeskWindowWasOpen = true;
            if (previousSessionActive != true)
                await SendSessionEventOnceAsync("connected", cancellationToken);
            previousSessionActive = true;
            autoSyncLabel.Text = "SESI REMOTE AKTIF • Agent standby; tidak menyalin/sync kredensial. Meter Coin server tetap berjalan.";
            return;
        }

        if (!observed.RemoteSessionStateKnown)
        {
            // Unknown is not proof of idle. Keep a previously active state locked and
            // never copy credentials until an explicit idle state is observed.
            autoSyncLabel.Text = remoteSessionActive
                ? "SESI REMOTE • StarDesk diminimalkan/tertutup dari pembacaan UI; Agent tetap standby."
                : "Status sesi StarDesk belum terbaca • tidak melakukan Copy & Share atau sync.";
            return;
        }

        var sessionJustEnded = previousSessionActive == true;
        var appJustOpened = !starDeskWindowWasOpen;
        if (sessionJustEnded || appJustOpened)
            pendingSyncAfterIdle = true;

        if (sessionJustEnded || appJustOpened)
        {
            // Close any stale host lock only after an explicit idle observation.
            await SendSessionEventOnceAsync("ended", cancellationToken);
            previousSessionActive = false;
        }

        starDeskWindowWasOpen = true;
        var pairFingerprint = PairFingerprint(observed);
        var pairChanged = !string.IsNullOrWhiteSpace(observed.DeviceId) &&
            !string.IsNullOrWhiteSpace(observed.VerificationCode) &&
            !string.Equals(pairFingerprint, lastObservedPairFingerprint, StringComparison.Ordinal);
        if (pairChanged)
            pendingSyncAfterIdle = true;

        if (!pendingSyncAfterIdle)
        {
            autoSyncLabel.Text = "Event sync aktif • tidak ada perubahan sesi atau data.";
            return;
        }

        // If the renter minimized StarDesk, keep it minimized. Remember the pending
        // sync and perform one capture only after a visible idle window event.
        if (observed.WindowHiddenOrMinimized)
        {
            autoSyncLabel.Text = "SESI IDLE • sync ditunda sampai StarDesk ditampilkan; jendela tidak akan dibuka otomatis.";
            return;
        }

        // Exactly one Copy & Share attempt for this idle transition / app-open event.
        var capture = await Task.Run(
            () => StarDeskUiCapture.ReadPartial(forceCopy: true), cancellationToken);
        if (capture.WindowHiddenOrMinimized)
        {
            autoSyncLabel.Text = "StarDesk kembali diminimalkan • sync menunggu sampai jendela ditampilkan.";
            return;
        }
        if (!capture.RemoteSessionStateKnown || capture.RemoteSessionActive)
        {
            if (capture.RemoteSessionStateKnown)
            {
                remoteSessionStateKnown = true;
                remoteSessionActive = capture.RemoteSessionActive;
                RefreshStatus();
            }
            autoSyncLabel.Text = "Status sesi berubah/tidak diketahui • Agent standby, tidak mengirim kredensial.";
            return;
        }
        if (string.IsNullOrWhiteSpace(capture.DeviceId) ||
            string.IsNullOrWhiteSpace(capture.VerificationCode) ||
            string.IsNullOrWhiteSpace(capture.InviteUrl))
        {
            pendingSyncAfterIdle = false;
            autoSyncLabel.Text = "Capture belum lengkap • tidak ada sync berkala. Gunakan Sinkronkan StarDesk saat PC idle.";
            return;
        }

        var capturedPairFingerprint = PairFingerprint(capture);
        lastObservedPairFingerprint = capturedPairFingerprint;
        var fingerprint = Fingerprint(capture);
        if (string.Equals(fingerprint, lastSyncedFingerprint, StringComparison.Ordinal))
        {
            pendingSyncAfterIdle = false;
            autoSyncLabel.Text = "Sesi selesai • data undangan tidak berubah, tidak perlu sync ulang.";
            return;
        }

        try
        {
            await AgentCapturePipeClient.SyncAsync(capture, cancellationToken);
            lastSyncedFingerprint = fingerprint;
            pendingSyncAfterIdle = false;
        }
        catch
        {
            // A failed transition gets one attempt, not a repeating sync loop.
            pendingSyncAfterIdle = false;
            throw;
        }
        autoSyncLabel.Text = sessionJustEnded
            ? "SESI SELESAI • tiga data StarDesk terbaru tersinkron."
            : "Tiga data StarDesk berhasil disinkronkan pada event perubahan.";
        RefreshStatus();
    }

    private async Task SendSessionEventOnceAsync(string eventType, CancellationToken cancellationToken)
    {
        await sessionEventGate.WaitAsync(cancellationToken);
        try
        {
            await AgentCapturePipeClient.SendSessionEventAsync(eventType, cancellationToken);
        }
        finally
        {
            sessionEventGate.Release();
        }
    }

    private static string SafeReason(string message)
    {
        if (message.Contains("STAR_DESK_WINDOW_NOT_FOUND", StringComparison.OrdinalIgnoreCase))
            return "StarDesk belum terbuka";
        if (message.Contains("timeout", StringComparison.OrdinalIgnoreCase))
            return "koneksi timeout";
        if (message.Contains("AGENT_PAIRING_REQUIRED", StringComparison.OrdinalIgnoreCase))
            return "Agent belum paired";
        return "koneksi Agent/server";
    }

    private async Task SyncStarDeskAsync()
    {
        RefreshStatus();
        if (currentStatus?.IsPaired != true)
        {
            MessageBox.Show("Pairing Windows Agent harus selesai terlebih dahulu.",
                "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        if (manualSyncBusy) return;
        manualSyncBusy = true;
        syncButton.Enabled = false;
        syncButton.Text = "Memeriksa sesi...";
        try
        {
            // Inspect without restoring, navigating, reading clipboard, or clicking Copy & Share.
            // Manual sync is allowed only after StarDesk explicitly reports an idle session.
            var sessionProbe = await Task.Run(
                () => StarDeskUiCapture.ReadPartial(allowCopy: false));
            if (!sessionProbe.RemoteSessionStateKnown)
            {
                MessageBox.Show(
                    "Status StarDesk belum bisa dipastikan.\n\nBuka/tampilkan StarDesk dan tunggu sampai status Remote Assistance terbaca. Agent tidak akan membuka jendela yang diminimalkan. Sinkronisasi ditahan demi keamanan sesi rental.",
                    "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            remoteSessionStateKnown = true;
            remoteSessionActive = sessionProbe.RemoteSessionActive;
            RefreshStatus();
            if (remoteSessionActive)
            {
                MessageBox.Show(
                    "Ada pengguna yang sedang menjalankan sesi remote StarDesk.\n\nAgent sekarang standby. Tidak ada Copy & Share atau sinkronisasi kredensial sampai sesi selesai.",
                    "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            syncButton.Text = "Membaca StarDesk...";
            var capture = await Task.Run(() => StarDeskUiCapture.ReadPartial(forceCopy: true));
            if (!capture.RemoteSessionStateKnown || capture.RemoteSessionActive)
            {
                remoteSessionStateKnown = capture.RemoteSessionStateKnown;
                if (capture.RemoteSessionStateKnown)
                    remoteSessionActive = capture.RemoteSessionActive;
                RefreshStatus();
                MessageBox.Show(
                    "Status sesi berubah atau tidak dapat dipastikan saat proses capture. Tidak ada kredensial yang dikirim. Coba lagi setelah StarDesk benar-benar idle.",
                    "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            if (string.IsNullOrWhiteSpace(capture.DeviceId) ||
                string.IsNullOrWhiteSpace(capture.VerificationCode) ||
                string.IsNullOrWhiteSpace(capture.InviteUrl))
            {
                MessageBox.Show(
                    "Agent belum menerima tiga data lengkap dari StarDesk.\n\nPastikan halaman Remote Assistance tampil, lalu coba lagi setelah sesi remote berakhir.",
                    "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            await AgentCapturePipeClient.SyncAsync(capture);
            lastSyncedFingerprint = Fingerprint(capture);
            lastObservedPairFingerprint = PairFingerprint(capture);
            remoteSessionStateKnown = true;
            remoteSessionActive = false;
            autoSyncLabel.Text = "Manual sync berhasil • Agent kembali memantau event, bukan polling kredensial.";
            MessageBox.Show(
                "Tiga data StarDesk berhasil disinkronkan ke Android DB.\n\nDevice ID: " + capture.DeviceId +
                "\nVerification Code dan Invite URL tidak ditampilkan dan disimpan terenkripsi.",
                "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
            RefreshStatus();
        }
        catch (Exception ex)
        {
            // The pipe client exposes only an allowlisted backend error code/category.
            // Clipboard credentials and invitation tokens are never included here.
            MessageBox.Show(
                "Sinkronisasi StarDesk belum berhasil.\n\nKode penyebab: " + ex.Message +
                "\n\nPeriksa kode tersebut; Agent tidak akan mengulang Copy & Share secara berkala.",
                "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            syncButton.Text = "Sinkronkan StarDesk";
            manualSyncBusy = false;
            RefreshStatus();
        }
    }

    private void OnFormClosing(object? sender, FormClosingEventArgs e)
    {
        if (e.CloseReason != CloseReason.UserClosing)
        {
            allowClose = true;
            return;
        }
        if (allowClose) return;
        e.Cancel = true;
        HideWindow();
    }

    private void ShowWindow()
    {
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
        RefreshStatus();
    }

    private void HideWindow()
    {
        Hide();
        trayIcon.ShowBalloonTip(1800, "Ani Games Ready Agent",
            "Jendela disembunyikan. Windows Service tetap berjalan di latar belakang.",
            ToolTipIcon.Info);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        refreshTimer.Stop();
        monitorHeartbeatTimer.Stop();
        starDeskEventDebounce?.Cancel();
        starDeskEventDebounce?.Dispose();
        if (starDeskWatcher is not null)
        {
            starDeskWatcher.StarDeskChanged -= OnStarDeskWindowChanged;
            starDeskWatcher.Dispose();
        }
        trayIcon.Visible = false;
        trayIcon.Dispose();
        sessionEventGate.Dispose();
        base.OnFormClosed(e);
    }
}
