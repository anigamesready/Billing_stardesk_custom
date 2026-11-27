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
    private readonly NotifyIcon trayIcon;
    private readonly System.Windows.Forms.Timer refreshTimer = new();
    private AgentStatus? currentStatus;
    private bool allowClose;

    public AgentTrayForm()
    {
        Text = "Ani Games Ready — StarDesk Agent";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = true;
        ClientSize = new Size(520, 350);
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
        copyButton.SetBounds(22, 266, 160, 38);
        copyButton.Click += (_, _) => CopyPairingCode();
        Controls.Add(copyButton);

        starDeskLabel.SetBounds(22, 248, 475, 18);
        starDeskLabel.ForeColor = Color.FromArgb(151, 225, 255);
        starDeskLabel.Text = "StarDesk: belum disinkronkan";
        starDeskLabel.AutoEllipsis = true;
        Controls.Add(starDeskLabel);

        refreshButton.Text = "Refresh status";
        refreshButton.SetBounds(190, 274, 135, 38);
        refreshButton.Click += (_, _) => RefreshStatus();
        Controls.Add(refreshButton);

        syncButton.Text = "Sinkronkan StarDesk";
        syncButton.SetBounds(335, 274, 162, 38);
        syncButton.Click += async (_, _) => await SyncStarDeskAsync();
        syncButton.Enabled = false;
        Controls.Add(syncButton);

        var foot = new Label
        {
            Text = "Tutup jendela atau tekan X untuk menyembunyikan ke system tray. Service Agent tetap berjalan.",
            ForeColor = Color.FromArgb(125, 151, 178),
            AutoSize = false,
            Location = new Point(22, 322),
            Size = new Size(475, 22),
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

        Shown += (_, _) => RefreshStatus();
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
        syncButton.Enabled = currentStatus.IsPaired;
        starDeskLabel.Text = string.IsNullOrWhiteSpace(currentStatus.StarDeskDeviceId)
            ? "StarDesk: belum disinkronkan"
            : "StarDesk ID: " + currentStatus.StarDeskDeviceId + " • " + (currentStatus.LastStarDeskSyncUtc?.ToLocalTime().ToString("dd MMM HH:mm:ss") ?? "tersimpan");
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

    private async Task SyncStarDeskAsync()
    {
        RefreshStatus();
        if (currentStatus?.IsPaired != true)
        {
            MessageBox.Show("Pairing Windows Agent harus selesai terlebih dahulu.",
                "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        syncButton.Enabled = false;
        syncButton.Text = "Membaca StarDesk...";
        try
        {
            var capture = await Task.Run(StarDeskUiCapture.Read);
            await AgentCapturePipeClient.SyncAsync(capture);
            MessageBox.Show(
                "StarDesk berhasil disinkronkan ke Android DB.\n\nDevice ID: " + capture.DeviceId +
                "\nKode verifikasi tidak ditampilkan dan disimpan dalam bentuk terenkripsi.",
                "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
            RefreshStatus();
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Sinkronisasi StarDesk belum berhasil.\n\n" + ex.Message +
                "\n\nBuka StarDesk Windows pada menu Remote Assist yang menampilkan Device ID dan Verification Code, lalu coba lagi.",
                "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            syncButton.Text = "Sinkronkan StarDesk";
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
        trayIcon.Visible = false;
        trayIcon.Dispose();
        base.OnFormClosed(e);
    }
}
