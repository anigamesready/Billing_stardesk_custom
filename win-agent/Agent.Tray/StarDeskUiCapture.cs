using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Automation;
using System.Windows.Forms;

namespace AniGamesReady.Agent.Tray;

public sealed record StarDeskCaptureSnapshot(
    string DeviceId, string VerificationCode, string WindowTitle,
    bool RemoteSessionStateKnown = false, bool RemoteSessionActive = false);

public static class StarDeskUiCapture
{
    private const int SwHide = 0, SwShowNoActivate = 4, SwMinimize = 6;
    private static readonly IntPtr HwndBottom = new(1);
    private const uint SwpNoSize = 0x0001, SwpNoMove = 0x0002,
        SwpNoActivate = 0x0010, SwpShowWindow = 0x0040;

    private static readonly Regex DeviceValueRegex = new(
        @"(?<!\d)(\d{3}(?:[\s-]+\d{3}){2,3}|\d{9})(?!\d)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex CodeValueRegex = new(
        @"(?<![A-Z0-9])[A-Z0-9]{8}(?![A-Z0-9])",
        RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex LabelledCodeRegex = new(
        @"(?i)\b(?:verification|verify|security)\s*code\b[\s:=：-]*([A-Z0-9]{8})",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private sealed record AccessibleText(string Text, Rectangle Bounds);
    private sealed record WindowInfo(IntPtr Handle, string Title, bool WasVisible, bool WasMinimized);
    private delegate bool EnumWindowsCallback(IntPtr hwnd, IntPtr lParam);

    private static readonly HashSet<string> NonCodes = new(StringComparer.OrdinalIgnoreCase)
    {
        "STARDESK", "COPY", "COPIED", "REFRESH", "DEVICE", "DEVICEID", "STARDESKDEVICEID",
        "VERIFICATION", "VERIFICATIONCODE", "VERIFYCODE", "CODE", "SECURITYCODE",
        "REMOTE", "ASSIST", "SUPPORT", "START", "STOP", "CLOSE", "OPEN", "SHARE",
        "CUSTOM", "CUSTOMCODE", "CUSTOMCODEONLY", "ONLY", "SET",
        "USEBOTH", "USEBOTHCODES", "TEMPORARY"
    };

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);

    public static StarDeskCaptureSnapshot Read()
    {
        var result = ReadPartial();
        if (string.IsNullOrWhiteSpace(result.DeviceId) || string.IsNullOrWhiteSpace(result.VerificationCode))
            throw new InvalidOperationException("STAR_DESK_FIELDS_NOT_ACCESSIBLE: tombol Copy StarDesk belum bisa dibaca. Pastikan StarDesk berjalan dan Remote Support memakai Use Both Codes.");
        return result;
    }

    public static StarDeskCaptureSnapshot ReadPartial()
    {
        var windows = FindStarDeskWindows();
        if (windows.Count == 0) throw new InvalidOperationException("STAR_DESK_WINDOW_NOT_FOUND");

        foreach (var window in windows)
        {
            try
            {
                MakeWindowTemporarilyAvailable(window.Handle);
                Thread.Sleep(180);
                var root = AutomationElement.FromHandle(window.Handle);
                var nodes = CollectAccessibleText(root);
                var deviceId = FindDeviceId(nodes);
                var code = FindVerificationCode(nodes);
                var session = DetectRemoteSession(nodes);

                if (string.IsNullOrWhiteSpace(deviceId) || string.IsNullOrWhiteSpace(code))
                {
                    var copied = TryInvokeCopyAndReadClipboard(root);
                    if (TryParseCopiedCredentials(copied, out var copiedId, out var copiedCode))
                    {
                        deviceId = copiedId;
                        code = copiedCode;
                    }
                }

                if (!string.IsNullOrWhiteSpace(deviceId) || !string.IsNullOrWhiteSpace(code) || session.Known)
                    return new StarDeskCaptureSnapshot(deviceId, code, window.Title, session.Known, session.Active);
            }
            catch (Exception ex)
            {
                // Never log clipboard contents or captured credentials.
                Debug.WriteLine("StarDesk UI capture skipped: " + ex.GetType().Name);
            }
            finally { RestoreOriginalWindowState(window); }
        }
        return new StarDeskCaptureSnapshot("", "", "StarDesk");
    }

    private static List<WindowInfo> FindStarDeskWindows()
    {
        var pids = new HashSet<int>();
        foreach (var process in Process.GetProcesses())
        {
            try { if (process.ProcessName.Contains("stardesk", StringComparison.OrdinalIgnoreCase)) pids.Add(process.Id); }
            catch { }
            finally { process.Dispose(); }
        }

        var result = new List<WindowInfo>();
        EnumWindows((hwnd, _) =>
        {
            try
            {
                GetWindowThreadProcessId(hwnd, out var rawPid);
                var title = GetWindowTitle(hwnd);
                if (!pids.Contains(unchecked((int)rawPid)) &&
                    !title.Contains("StarDesk", StringComparison.OrdinalIgnoreCase)) return true;
                result.Add(new WindowInfo(hwnd, title, IsWindowVisible(hwnd), IsIconic(hwnd)));
            }
            catch { }
            return true;
        }, IntPtr.Zero);

        return result.OrderBy(x => x.Title.Contains("StarDesk", StringComparison.OrdinalIgnoreCase) ? 0 : 1)
            .ThenBy(x => x.WasVisible ? 0 : 1).ToList();
    }

    private static string GetWindowTitle(IntPtr hwnd)
    {
        var builder = new StringBuilder(512);
        var length = GetWindowText(hwnd, builder, builder.Capacity);
        return length > 0 ? builder.ToString(0, length) : "";
    }

    private static void MakeWindowTemporarilyAvailable(IntPtr hwnd)
    {
        if (!IsWindowVisible(hwnd) || IsIconic(hwnd))
        {
            ShowWindowAsync(hwnd, SwShowNoActivate);
            SetWindowPos(hwnd, HwndBottom, 0, 0, 0, 0, SwpNoSize | SwpNoMove | SwpNoActivate | SwpShowWindow);
        }
    }

    private static void RestoreOriginalWindowState(WindowInfo window)
    {
        if (!window.WasVisible) { ShowWindowAsync(window.Handle, SwHide); return; }
        if (window.WasMinimized) ShowWindowAsync(window.Handle, SwMinimize);
    }

    private static List<AccessibleText> CollectAccessibleText(AutomationElement root)
    {
        var values = new List<AccessibleText>(96);
        AddElementText(root, values);
        AutomationElementCollection descendants;
        try { descendants = root.FindAll(TreeScope.Descendants, Condition.TrueCondition); }
        catch { return values; }
        for (var i = 0; i < Math.Min(descendants.Count, 5000); i++) AddElementText(descendants[i], values);
        return values.Where(x => !string.IsNullOrWhiteSpace(x.Text))
            .Select(x => new AccessibleText(x.Text.Trim(), x.Bounds))
            .GroupBy(x => (x.Text, x.Bounds)).Select(x => x.First()).ToList();
    }

    private static void AddElementText(AutomationElement element, List<AccessibleText> values)
    {
        Rectangle bounds;
        try
        {
            var rect = element.Current.BoundingRectangle;
            bounds = double.IsNaN(rect.Left) || double.IsNaN(rect.Top) || double.IsInfinity(rect.Left) || double.IsInfinity(rect.Top)
                ? Rectangle.Empty
                : Rectangle.FromLTRB(
                    (int)Math.Clamp(Math.Round(rect.Left), int.MinValue, int.MaxValue),
                    (int)Math.Clamp(Math.Round(rect.Top), int.MinValue, int.MaxValue),
                    (int)Math.Clamp(Math.Round(rect.Right), int.MinValue, int.MaxValue),
                    (int)Math.Clamp(Math.Round(rect.Bottom), int.MinValue, int.MaxValue));
        }
        catch { bounds = Rectangle.Empty; }

        try { var name = element.Current.Name; if (!string.IsNullOrWhiteSpace(name)) values.Add(new AccessibleText(name, bounds)); } catch { }
        try
        {
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var p) && p is ValuePattern value)
            { var text = value.Current.Value; if (!string.IsNullOrWhiteSpace(text)) values.Add(new AccessibleText(text, bounds)); }
        }
        catch { }
        try
        {
            if (element.TryGetCurrentPattern(TextPattern.Pattern, out var p) && p is TextPattern textPattern)
            { var text = textPattern.DocumentRange.GetText(1024); if (!string.IsNullOrWhiteSpace(text)) values.Add(new AccessibleText(text, bounds)); }
        }
        catch { }
    }

    private static string FindDeviceId(IReadOnlyList<AccessibleText> nodes)
    {
        foreach (var node in nodes)
        {
            var match = Regex.Match(node.Text, @"(?i)\bdevice\s*id\b\s*[:：]?\s*(\d{3}(?:[\s-]+\d{3}){2,3}|\d{9})");
            if (match.Success) return NormalizeDeviceId(match.Groups[1].Value);
        }
        var labelIndex = -1;
        for (var i = 0; i < nodes.Count; i++)
            if (Normalize(nodes[i].Text).Contains("deviceid", StringComparison.Ordinal)) { labelIndex = i; break; }
        if (labelIndex < 0) return "";
        var label = nodes[labelIndex];

        var nearby = nodes.Select((node, index) => new { node, index })
            .Where(x => x.index != labelIndex && TryDeviceToken(x.node.Text, out _))
            .Select(x => new { x.node, score = ScoreNearLabel(label.Bounds, x.node.Bounds, x.index - labelIndex, 100, 180) })
            .Where(x => x.score < double.MaxValue).OrderBy(x => x.score).FirstOrDefault();
        if (nearby is not null && TryDeviceToken(nearby.node.Text, out var id)) return NormalizeDeviceId(id);

        for (var i = labelIndex + 1; i < Math.Min(nodes.Count, labelIndex + 12); i++)
            if (TryDeviceToken(nodes[i].Text, out var sequentialId)) return NormalizeDeviceId(sequentialId);
        return "";
    }

    private static string FindVerificationCode(IReadOnlyList<AccessibleText> nodes)
    {
        for (var i = 0; i < nodes.Count; i++)
        {
            var normalized = Normalize(nodes[i].Text);
            if (normalized is "verificationcode" or "verifycode" or "securitycode")
                for (var j = i + 1; j < Math.Min(nodes.Count, i + 10); j++)
                    if (TryCodeToken(nodes[j].Text, out var explicitCode)) return explicitCode;

            var match = LabelledCodeRegex.Match(nodes[i].Text);
            if (match.Success && IsCode(match.Groups[1].Value)) return match.Groups[1].Value.ToUpperInvariant();
        }

        var methodIndex = -1;
        for (var i = 0; i < nodes.Count; i++)
            if (Normalize(nodes[i].Text).Contains("verificationmethod", StringComparison.Ordinal)) { methodIndex = i; break; }

        if (methodIndex >= 0)
        {
            var label = nodes[methodIndex];
            var nearby = nodes.Select((node, index) => new { node, index })
                .Where(x => x.index != methodIndex && TryCodeToken(x.node.Text, out _))
                .Select(x => new { x.node, score = ScoreNearLabel(label.Bounds, x.node.Bounds, x.index - methodIndex, 96, 260) })
                .Where(x => x.score < double.MaxValue).OrderBy(x => x.score).FirstOrDefault();
            if (nearby is not null && TryCodeToken(nearby.node.Text, out var code)) return code;
            for (var i = methodIndex + 1; i < Math.Min(nodes.Count, methodIndex + 24); i++)
                if (TryCodeToken(nodes[i].Text, out var sequentialCode)) return sequentialCode;
        }
        return "";
    }

    private static string TryInvokeCopyAndReadClipboard(AutomationElement root)
    {
        return RunOnSta(() =>
        {
            IDataObject? previous = null;
            try { previous = Clipboard.GetDataObject(); } catch { }
            try
            {
                AutomationElementCollection descendants;
                try { descendants = root.FindAll(TreeScope.Descendants, Condition.TrueCondition); }
                catch { return ""; }

                for (var i = 0; i < Math.Min(descendants.Count, 5000); i++)
                {
                    try
                    {
                        var element = descendants[i];
                        if (element.Current.ControlType != ControlType.Button) continue;
                        var name = Normalize(element.Current.Name ?? "");
                        if (name is not ("copy" or "copyshare" or "copyandshare")) continue;
                        if (!element.TryGetCurrentPattern(InvokePattern.Pattern, out var pattern) || pattern is not InvokePattern invoke) continue;
                        invoke.Invoke();

                        for (var attempt = 0; attempt < 8; attempt++)
                        {
                            Thread.Sleep(65);
                            var copied = Clipboard.ContainsText(TextDataFormat.UnicodeText)
                                ? Clipboard.GetText(TextDataFormat.UnicodeText) : "";
                            if (!string.IsNullOrWhiteSpace(copied) && TryParseCopiedCredentials(copied, out _, out _))
                                return copied;
                        }
                    }
                    catch { }
                }
                return "";
            }
            finally
            {
                // Return the clipboard to the exact previous IDataObject if possible.
                try { if (previous is not null) Clipboard.SetDataObject(previous, true); else Clipboard.Clear(); }
                catch { }
            }
        });
    }

    private static T RunOnSta<T>(Func<T> action)
    {
        T result = default!;
        Exception? error = null;
        using var done = new ManualResetEventSlim(false);
        var thread = new Thread(() =>
        {
            try { result = action(); } catch (Exception ex) { error = ex; } finally { done.Set(); }
        }) { IsBackground = true, Name = "AniGamesReady-StarDesk-Clipboard" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!done.Wait(TimeSpan.FromSeconds(4))) throw new TimeoutException("STAR_DESK_COPY_TIMEOUT");
        if (error is not null) throw new InvalidOperationException("STAR_DESK_COPY_FAILED", error);
        return result;
    }

    internal static bool TryParseCopiedCredentials(string text, out string deviceId, out string verificationCode)
    {
        deviceId = "";
        verificationCode = "";
        if (string.IsNullOrWhiteSpace(text) || text.Length > 4096) return false;
        var id = DeviceValueRegex.Match(text);
        if (!id.Success) return false;
        deviceId = NormalizeDeviceId(id.Groups[1].Value);

        var labelled = LabelledCodeRegex.Match(text);
        if (labelled.Success && IsCode(labelled.Groups[1].Value))
        { verificationCode = labelled.Groups[1].Value.ToUpperInvariant(); return true; }

        var afterId = text[(id.Index + id.Length)..];
        var candidates = CodeValueRegex.Matches(afterId).Select(x => x.Value.ToUpperInvariant())
            .Where(IsCode).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (candidates.Length != 1)
            candidates = CodeValueRegex.Matches(text).Select(x => x.Value.ToUpperInvariant())
                .Where(IsCode).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (candidates.Length != 1) { deviceId = ""; return false; }
        verificationCode = candidates[0];
        return true;
    }

    private static (bool Known, bool Active) DetectRemoteSession(IReadOnlyList<AccessibleText> nodes)
    {
        var text = string.Join("\n", nodes.Select(x => x.Text)).ToLowerInvariant();
        if (text.Contains("device is being controlled") || text.Contains("this device is being controlled") || text.Contains("being controlled by"))
            return (true, true);
        var match = Regex.Match(text, @"(\d+)\s+devices?\s+controlling\s+this\s+pc");
        if (match.Success && int.TryParse(match.Groups[1].Value, out var count)) return (true, count > 0);
        if (text.Contains("no devices controlling this pc") || text.Contains("not being controlled") || text.Contains("0 devices controlling this pc"))
            return (true, false);
        return (false, false);
    }

    private static double ScoreNearLabel(Rectangle label, Rectangle candidate, int indexDelta, int maxY, int maxX)
    {
        if (label.IsEmpty || candidate.IsEmpty) return indexDelta >= 1 ? 100000d + indexDelta : double.MaxValue;
        var dx = Math.Abs(candidate.Left - label.Left);
        var dy = candidate.Top - label.Top;
        if (dy < -8 || dy > maxY || dx > maxX) return double.MaxValue;
        return dy * 2d + dx + Math.Max(0, indexDelta) * 0.02d;
    }

    private static bool TryDeviceToken(string text, out string value)
    { var match = DeviceValueRegex.Match(text ?? ""); value = match.Success ? match.Groups[1].Value : ""; return match.Success; }

    private static bool TryCodeToken(string text, out string value)
    { var match = CodeValueRegex.Match(text ?? ""); value = match.Success ? match.Value.ToUpperInvariant() : ""; return match.Success && IsCode(value); }

    private static bool IsCode(string value) =>
        value.Length == 8 && !NonCodes.Contains(value) &&
        Regex.IsMatch(value, "^[A-Z0-9]{8}$", RegexOptions.CultureInvariant);

    internal static string NormalizeDeviceId(string value)
    {
        var cleaned = (value ?? "").Trim();
        return Regex.IsMatch(cleaned, @"^\d{3}(?:[\s-]+\d{3}){2,3}$")
            ? Regex.Replace(cleaned, @"[\s-]+", "")
            : cleaned;
    }

    private static string Normalize(string value) =>
        Regex.Replace(value ?? "", "[^A-Za-z0-9]", "").ToLowerInvariant();
}
