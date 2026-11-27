using System.Drawing;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace AniGamesReady.Agent.Tray;

public sealed class StarDeskManualEntryDialog : Form
{
    private readonly TextBox deviceIdInput = new();
    private readonly TextBox verificationCodeInput = new();
    private readonly CheckBox showCode = new();

    public string DeviceId => StarDeskUiCapture.NormalizeDeviceId(deviceIdInput.Text);
    public string VerificationCode => verificationCodeInput.Text.Trim();

    public StarDeskManualEntryDialog(string deviceId, string verificationCode, string autoReadNote)
    {
        Text = "Sinkronkan StarDesk";
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        ClientSize = new Size(500, 380);
        BackColor = Color.FromArgb(7, 16, 31);
        ForeColor = Color.FromArgb(237, 246, 255);
        Font = new Font("Segoe UI", 9F);

        var heading = new Label
        {
            Text = "DATA REMOTE SUPPORT STAR DESK",
            ForeColor = Color.FromArgb(85, 216, 255),
            Font = new Font("Segoe UI", 12F, FontStyle.Bold),
            Location = new Point(20, 18),
            Size = new Size(450, 28)
        };
        Controls.Add(heading);

        var instruction = new Label
        {
            Text = "Auto-detect belum menemukan pasangan Device ID + Verification Code yang valid. Agent tidak akan mengisi nilai tebakan.",
            ForeColor = Color.FromArgb(173, 194, 215),
            Location = new Point(20, 52),
            Size = new Size(455, 42)
        };
        Controls.Add(instruction);

        var deviceLabel = new Label
        {
            Text = "DEVICE ID (REMOTE SUPPORT)",
            ForeColor = Color.FromArgb(181, 209, 232),
            Location = new Point(20, 110),
            Size = new Size(450, 20)
        };
        Controls.Add(deviceLabel);

        deviceIdInput.SetBounds(20, 132, 455, 34);
        deviceIdInput.Font = new Font("Segoe UI", 11F);
        deviceIdInput.Text = deviceId;
        deviceIdInput.MaxLength = 180;
        Controls.Add(deviceIdInput);

        var codeLabel = new Label
        {
            Text = "VERIFICATION CODE / CUSTOM CODE",
            ForeColor = Color.FromArgb(181, 209, 232),
            Location = new Point(20, 177),
            Size = new Size(450, 20)
        };
        Controls.Add(codeLabel);

        verificationCodeInput.SetBounds(20, 199, 455, 34);
        verificationCodeInput.Font = new Font("Segoe UI", 11F);
        verificationCodeInput.MaxLength = 128;
        verificationCodeInput.UseSystemPasswordChar = true;
        verificationCodeInput.Text = verificationCode;
        Controls.Add(verificationCodeInput);

        showCode.Text = "Tampilkan kode";
        showCode.ForeColor = Color.FromArgb(173, 194, 215);
        showCode.BackColor = Color.Transparent;
        showCode.SetBounds(20, 238, 180, 22);
        showCode.CheckedChanged += (_, _) =>
            verificationCodeInput.UseSystemPasswordChar = !showCode.Checked;
        Controls.Add(showCode);

        var status = new Label
        {
            Text = string.IsNullOrWhiteSpace(autoReadNote)
                ? "Status baca: belum ada diagnosis. Pastikan Remote Support StarDesk terbuka."
                : "DIAGNOSTIK (tanpa menampilkan kode): " + autoReadNote +
                  Environment.NewLine + "Nilai yang tidak tervalidasi sengaja dibiarkan kosong.",
            ForeColor = Color.FromArgb(125, 178, 205),
            Location = new Point(20, 258),
            Size = new Size(455, 66)
        };
        status.AutoEllipsis = true;
        Controls.Add(status);

        var save = new Button
        {
            Text = "SIMPAN & SINKRONKAN",
            DialogResult = DialogResult.None,
            BackColor = Color.FromArgb(31, 111, 169),
            ForeColor = Color.White,
            FlatStyle = FlatStyle.Flat,
            Location = new Point(270, 335),
            Size = new Size(205, 34)
        };
        save.Click += (_, _) => AcceptValues();
        Controls.Add(save);

        var cancel = new Button
        {
            Text = "Batal",
            DialogResult = DialogResult.Cancel,
            BackColor = Color.FromArgb(32, 47, 66),
            ForeColor = Color.White,
            FlatStyle = FlatStyle.Flat,
            Location = new Point(20, 335),
            Size = new Size(90, 34)
        };
        Controls.Add(cancel);

        AcceptButton = save;
        CancelButton = cancel;
    }

    private void AcceptValues()
    {
        var deviceId = DeviceId;
        var code = VerificationCode;
        if (string.IsNullOrWhiteSpace(deviceId) || deviceId.Length > 180)
        {
            MessageBox.Show("Device ID wajib diisi (maksimal 180 karakter).",
                "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            deviceIdInput.Focus();
            return;
        }
        if (string.IsNullOrWhiteSpace(code) || code.Length > 128 ||
            code.Contains('\r') || code.Contains('\n'))
        {
            MessageBox.Show("Verification Code wajib diisi (maksimal 128 karakter, satu baris).",
                "Ani Games Ready Agent", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            verificationCodeInput.Focus();
            return;
        }

        DialogResult = DialogResult.OK;
        Close();
    }
}
