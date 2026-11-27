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
    string DeviceId,
    string VerificationCode,
    string WindowTitle,
    bool RemoteSessionStateKnown = false,
    bool RemoteSessionActive = false,
    string Diagnostics = "");

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
    private static readonly Regex LocalizedLabelledCodeRegex = new(
        @"(?i)\bkode\s*verifikasi\b[\s:=：-]*([A-Z0-9]{8})",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex ExactCodeLineRegex = new(
        @"^\s*([A-Z0-9]{8})\s*$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private sealed record AccessibleText(string Text, Rectangle Bounds);
    private sealed record WindowInfo(
        IntPtr Handle, int ProcessId, string Title,
        bool WasVisible, bool WasMinimized, long Area);
    private sealed record CopyCaptureResult(
        string Text, bool ButtonFound, bool ActionInvoked,
        bool ClipboardChanged, bool PairParsed, string Action);
    private delegate bool EnumWindowsCallback(IntPtr hwnd, IntPtr lParam);

    private static readonly object CopyAttemptLock = new();
    private static DateTime lastCopyAttemptUtc = DateTime.MinValue;
    private static readonly TimeSpan AutoCopyCooldown = TimeSpan.FromSeconds(25);

    private static readonly HashSet<string> NonCodes = new(StringComparer.OrdinalIgnoreCase)
    {
        "STARDESK", "KARAKTER", "COPY", "COPIED", "REFRESH", "DEVICE", "DEVICEID",
        "STARDESKDEVICEID", "VERIFICATION", "VERIFICATIONCODE", "VERIFYCODE",
        "CODE", "SECURITYCODE", "REMOTE", "ASSIST", "SUPPORT", "START", "STOP",
        "CLOSE", "OPEN", "SHARE", "CUSTOM", "CUSTOMCODE", "CUSTOMCODEONLY",
        "ONLY", "SET", "USEBOTH", "USEBOTHCODES", "TEMPORARY"
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);
    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    public static StarDeskCaptureSnapshot Read() => ReadPartial(forceCopy: true);

    public static StarDeskCaptureSnapshot ReadPartial(bool forceCopy = false)
    {
        var windows = FindStarDeskWindows();
        if (windows.Count == 0)
            return new StarDeskCaptureSnapshot(
                "", "", "StarDesk",
                Diagnostics: "Jendela StarDesk tidak ditemukan; proses mungkin sudah ditutup, bukan hanya disembunyikan.");

        StarDeskCaptureSnapshot? best = null;
        var bestScore = long.MinValue;
        var windowFailures = 0;

        // Inspect each top-level StarDesk window. Never stop at the first partial
        // text node: the first handle may be a helper/dialog window, not the main app.
        foreach (var window in windows)
        {
            try
            {
                MakeWindowTemporarilyAvailable(window.Handle);
                Thread.Sleep(220);

                var root = AutomationElement.FromHandle(window.Handle);
                var nodes = CollectAccessibleText(root);
                var deviceId = FindDeviceId(nodes);
                var verificationCode = FindVerificationCode(nodes);
                var session = DetectRemoteSession(nodes);

                CopyCaptureResult copy = new("", false, false, false, false, "not-needed");
                if (string.IsNullOrWhiteSpace(deviceId) ||
                    string.IsNullOrWhiteSpace(verificationCode))
                {
                    if (ShouldAttemptCopy(forceCopy))
                    {
                        copy = TryInvokeCopyAndReadClipboard(root);
                        if (copy.PairParsed &&
                            TryParseCopiedCredentials(copy.Text, out var copiedId, out var copiedCode))
                        {
                            // The StarDesk Copy & Share result is an authoritative pair.
                            deviceId = copiedId;
                            verificationCode = copiedCode;
                        }
                    }
                    else
                    {
                        copy = new CopyCaptureResult("", false, false, false, false, "cooldown");
                    }
                }

                var diagnostics = BuildDiagnostics(
                    windows.Count, window, nodes.Count, deviceId, verificationCode, copy);
                var candidate = new StarDeskCaptureSnapshot(
                    deviceId, verificationCode, window.Title,
                    session.Known, session.Active, diagnostics);

                if (!string.IsNullOrWhiteSpace(deviceId) &&
                    !string.IsNullOrWhiteSpace(verificationCode))
                    return candidate;

                var score = (string.IsNullOrWhiteSpace(deviceId) ? 0 : 100_000_000L) +
                            (string.IsNullOrWhiteSpace(verificationCode) ? 0 : 10_000_000L) +
                            window.Area;
                if (score > bestScore)
                {
                    best = candidate;
                    bestScore = score;
                }
            }
            catch (Exception ex)
            {
                windowFailures++;
                var diagnostics = $"Jendela ditemukan={windows.Count}; UI Automation gagal={ex.GetType().Name}.";
                var failed = new StarDeskCaptureSnapshot(
                    "", "", window.Title, Diagnostics: diagnostics);
                if (best is null)
                    best = failed;
            }
            finally
            {
                RestoreOriginalWindowState(window);
            }
        }

        if (best is not null)
        {
            var suffix = windowFailures > 0
                ? $" Sebagian jendela gagal dibaca={windowFailures}."
                : "";
            return best with { Diagnostics = best.Diagnostics + suffix };
        }

        return new StarDeskCaptureSnapshot(
            "", "", "StarDesk",
            Diagnostics: "Jendela StarDesk ada, tetapi pohon aksesibilitas tidak mengembalikan elemen yang bisa dibaca.");
    }

    private static List<WindowInfo> FindStarDeskWindows()
    {
        var processIds = new HashSet<int>();
        foreach (var process in Process.GetProcesses())
        {
            try
            {
                if (process.ProcessName.Contains("stardesk", StringComparison.OrdinalIgnoreCase))
                    processIds.Add(process.Id);
            }
            catch { }
            finally { process.Dispose(); }
        }

        var result = new List<WindowInfo>();
        EnumWindows((hwnd, _) =>
        {
            try
            {
                GetWindowThreadProcessId(hwnd, out var rawPid);
                var pid = unchecked((int)rawPid);
                var title = GetWindowTitle(hwnd);
                if (!processIds.Contains(pid) &&
                    !title.Contains("StarDesk", StringComparison.OrdinalIgnoreCase))
                    return true;

                if (!GetWindowRect(hwnd, out var rect))
                    return true;

                var width = Math.Max(0, rect.Right - rect.Left);
                var height = Math.Max(0, rect.Bottom - rect.Top);
                var area = (long)width * height;
                if (width < 260 || height < 180)
                    return true;

                result.Add(new WindowInfo(
                    hwnd, pid, title,
                    IsWindowVisible(hwnd), IsIconic(hwnd), area));
            }
            catch { }
            return true;
        }, IntPtr.Zero);

        // Main window normally has the largest client frame. This prevents
        // helper/pop-up windows owned by the same process from winning capture.
        return result
            .OrderByDescending(x => x.Title.Contains("StarDesk", StringComparison.OrdinalIgnoreCase))
            .ThenByDescending(x => x.Area)
            .ToList();
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
            SetWindowPos(hwnd, new IntPtr(1), 0, 0, 0, 0,
                SwpNoSize | SwpNoMove | SwpNoActivate | SwpShowWindow);
        }
    }

    private static void RestoreOriginalWindowState(WindowInfo window)
    {
        if (!window.WasVisible)
        {
            ShowWindowAsync(window.Handle, SwHide);
            return;
        }
        if (window.WasMinimized)
            ShowWindowAsync(window.Handle, SwMinimize);
    }

    private static List<AccessibleText> CollectAccessibleText(AutomationElement root)
    {
        var values = new List<AccessibleText>(128);
        AddElementText(root, values);

        AutomationElementCollection descendants;
        try { descendants = root.FindAll(TreeScope.Descendants, Condition.TrueCondition); }
        catch { return values; }

        for (var i = 0; i < Math.Min(descendants.Count, 6000); i++)
            AddElementText(descendants[i], values);

        return values
            .Where(x => !string.IsNullOrWhiteSpace(x.Text))
            .Select(x => new AccessibleText(x.Text.Trim(), x.Bounds))
            .GroupBy(x => (x.Text, x.Bounds))
            .Select(x => x.First())
            .ToList();
    }

    private static void AddElementText(AutomationElement element, List<AccessibleText> values)
    {
        Rectangle bounds;
        try
        {
            var rect = element.Current.BoundingRectangle;
            bounds = double.IsNaN(rect.Left) || double.IsNaN(rect.Top) ||
                     double.IsInfinity(rect.Left) || double.IsInfinity(rect.Top)
                ? Rectangle.Empty
                : Rectangle.FromLTRB(
                    (int)Math.Clamp(Math.Round(rect.Left), int.MinValue, int.MaxValue),
                    (int)Math.Clamp(Math.Round(rect.Top), int.MinValue, int.MaxValue),
                    (int)Math.Clamp(Math.Round(rect.Right), int.MinValue, int.MaxValue),
                    (int)Math.Clamp(Math.Round(rect.Bottom), int.MinValue, int.MaxValue));
        }
        catch { bounds = Rectangle.Empty; }

        try
        {
            var name = element.Current.Name;
            if (!string.IsNullOrWhiteSpace(name))
                values.Add(new AccessibleText(name, bounds));
        }
        catch { }

        try
        {
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern) &&
                pattern is ValuePattern value)
            {
                var text = value.Current.Value;
                if (!string.IsNullOrWhiteSpace(text))
                    values.Add(new AccessibleText(text, bounds));
            }
        }
        catch { }

        try
        {
            if (element.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) &&
                pattern is TextPattern content)
            {
                var text = content.DocumentRange.GetText(2048);
                if (!string.IsNullOrWhiteSpace(text))
                    values.Add(new AccessibleText(text, bounds));
            }
        }
        catch { }
    }

    private static string FindDeviceId(IReadOnlyList<AccessibleText> nodes)
    {
        foreach (var node in nodes)
        {
            var labelled = Regex.Match(node.Text,
                @"(?i)\bdevice\s*id\b\s*[:：]?\s*(\d{3}(?:[\s-]+\d{3}){2,3}|\d{9})");
            if (labelled.Success)
                return NormalizeDeviceId(labelled.Groups[1].Value);
        }

        var labelIndex = -1;
        for (var i = 0; i < nodes.Count; i++)
        {
            if (Normalize(nodes[i].Text).Contains("deviceid", StringComparison.Ordinal))
            {
                labelIndex = i;
                break;
            }
        }
        if (labelIndex < 0)
            return "";

        var label = nodes[labelIndex];
        var candidate = nodes
            .Select((node, index) => new { node, index })
            .Where(x => x.index != labelIndex && TryDeviceToken(x.node.Text, out _))
            .Select(x => new
            {
                x.node,
                score = ScoreNearLabel(label.Bounds, x.node.Bounds,
                    x.index - labelIndex, minY: 8, maxY: 105, maxX: 360)
            })
            .Where(x => x.score < double.MaxValue)
            .OrderBy(x => x.score)
            .FirstOrDefault();

        return candidate is not null && TryDeviceToken(candidate.node.Text, out var id)
            ? NormalizeDeviceId(id)
            : "";
    }

    private static string FindVerificationCode(IReadOnlyList<AccessibleText> nodes)
    {
        // Accept an explicit, labelled code only.
        foreach (var node in nodes)
        {
            var labelled = LabelledCodeRegex.Match(node.Text);
            if (labelled.Success && IsCode(labelled.Groups[1].Value))
                return labelled.Groups[1].Value.ToUpperInvariant();

            var localized = LocalizedLabelledCodeRegex.Match(node.Text);
            if (localized.Success && IsCode(localized.Groups[1].Value))
                return localized.Groups[1].Value.ToUpperInvariant();
        }

        // StarDesk 1.6.x places the temporary code on the row below
        // "Verification Method". No descendant-order fallback is allowed:
        // unrelated text such as "KARAKTER" must never be treated as a code.
        var methodLabel = nodes.FirstOrDefault(x =>
            Normalize(x.Text).Contains("verificationmethod", StringComparison.Ordinal));
        if (methodLabel is null)
            return "";

        var candidate = nodes
            .Where(x => TryCodeToken(x.Text, out _))
            .Select(x => new
            {
                Node = x,
                Score = ScoreNearLabel(methodLabel.Bounds, x.Bounds, 1,
                    minY: 8, maxY: 82, maxX: 340)
            })
            .Where(x => x.Score < double.MaxValue)
            .OrderBy(x => x.Score)
            .FirstOrDefault();

        return candidate is not null && TryCodeToken(candidate.Node.Text, out var code)
            ? code
            : "";
    }

    private static CopyCaptureResult TryInvokeCopyAndReadClipboard(AutomationElement root)
    {
        return RunOnSta(() =>
        {
            IDataObject? previous = null;
            try { previous = Clipboard.GetDataObject(); }
            catch { }

            var buttonFound = false;
            var actionInvoked = false;
            var clipboardChanged = false;
            var pairParsed = false;
            var actionName = "none";
            var sequenceAfterCopy = 0u;

            try
            {
                AutomationElementCollection descendants;
                try { descendants = root.FindAll(TreeScope.Descendants, Condition.TrueCondition); }
                catch
                {
                    return new CopyCaptureResult("", false, false, false, false, "uia-query-failed");
                }

                for (var i = 0; i < Math.Min(descendants.Count, 6000); i++)
                {
                    try
                    {
                        var element = descendants[i];
                        if (element.Current.ControlType != ControlType.Button)
                            continue;

                        var name = Normalize(element.Current.Name ?? "");
                        var automationId = Normalize(element.Current.AutomationId ?? "");
                        if (name is not ("copy" or "copyshare" or "copyandshare" or "copydeviceid") &&
                            !automationId.Contains("copy", StringComparison.Ordinal))
                            continue;

                        buttonFound = true;
                        var sequenceBefore = GetClipboardSequenceNumber();

                        if (element.TryGetCurrentPattern(InvokePattern.Pattern, out var pattern) &&
                            pattern is InvokePattern invoke)
                        {
                            invoke.Invoke();
                            actionInvoked = true;
                            actionName = "InvokePattern";
                        }
                        else
                        {
                            // This Windows UI Automation target does not expose
                            // LegacyIAccessiblePattern; report the unsupported action
                            // rather than attempting an unverified mouse click.
                            actionName = "button-found-no-InvokePattern";
                            continue;
                        }

                        for (var attempt = 0; attempt < 20; attempt++)
                        {
                            Thread.Sleep(75);
                            var currentSequence = GetClipboardSequenceNumber();
                            if (currentSequence == sequenceBefore)
                                continue;

                            clipboardChanged = true;
                            sequenceAfterCopy = currentSequence;
                            var copied = Clipboard.ContainsText(TextDataFormat.UnicodeText)
                                ? Clipboard.GetText(TextDataFormat.UnicodeText)
                                : Clipboard.ContainsText()
                                    ? Clipboard.GetText()
                                    : "";

                            if (TryParseCopiedCredentials(copied, out _, out _))
                            {
                                pairParsed = true;
                                return new CopyCaptureResult(
                                    copied, true, true, true, true, actionName);
                            }

                            // Clipboard was changed by StarDesk, but the format was
                            // not a recognized ID+code pair. Do not search arbitrary
                            // 8-character substrings and do not accept stale clipboard.
                            return new CopyCaptureResult(
                                "", true, true, true, false, actionName + "-unrecognized-format");
                        }
                    }
                    catch
                    {
                        // Continue to another exact Copy control; never log element text.
                    }
                }

                return new CopyCaptureResult(
                    "", buttonFound, actionInvoked, clipboardChanged,
                    pairParsed, actionName);
            }
            finally
            {
                // Restore the clipboard only if it still contains our StarDesk copy.
                // If the user copied something else meanwhile, do not overwrite it.
                try
                {
                    if (clipboardChanged &&
                        GetClipboardSequenceNumber() == sequenceAfterCopy)
                    {
                        if (previous is not null)
                            Clipboard.SetDataObject(previous, true);
                        else
                            Clipboard.Clear();
                    }
                }
                catch { }
            }
        });
    }

    private static bool ShouldAttemptCopy(bool force)
    {
        lock (CopyAttemptLock)
        {
            var now = DateTime.UtcNow;
            if (!force && now - lastCopyAttemptUtc < AutoCopyCooldown)
                return false;
            lastCopyAttemptUtc = now;
            return true;
        }
    }

    private static T RunOnSta<T>(Func<T> action)
    {
        T result = default!;
        Exception? error = null;
        using var done = new ManualResetEventSlim(false);

        var thread = new Thread(() =>
        {
            try { result = action(); }
            catch (Exception ex) { error = ex; }
            finally { done.Set(); }
        })
        {
            IsBackground = true,
            Name = "AniGamesReady-StarDesk-Clipboard"
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        if (!done.Wait(TimeSpan.FromSeconds(6)))
            throw new TimeoutException("STAR_DESK_COPY_TIMEOUT");
        if (error is not null)
            throw new InvalidOperationException("STAR_DESK_COPY_FAILED", error);
        return result;
    }

    internal static bool TryParseCopiedCredentials(
        string text, out string deviceId, out string verificationCode)
    {
        deviceId = "";
        verificationCode = "";
        if (string.IsNullOrWhiteSpace(text) || text.Length > 4096)
            return false;

        var deviceMatch = DeviceValueRegex.Match(text);
        if (!deviceMatch.Success)
            return false;

        var parsedDeviceId = NormalizeDeviceId(deviceMatch.Groups[1].Value);

        var labelled = LabelledCodeRegex.Match(text);
        if (!labelled.Success)
            labelled = LocalizedLabelledCodeRegex.Match(text);

        if (labelled.Success && IsCode(labelled.Groups[1].Value))
        {
            deviceId = parsedDeviceId;
            verificationCode = labelled.Groups[1].Value.ToUpperInvariant();
            return true;
        }

        // Otherwise only accept a complete, isolated 8-character line.
        // Never search all clipboard prose for a random 8-character word.
        var candidates = text.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Split('\n')
            .Select(line => ExactCodeLineRegex.Match(line))
            .Where(match => match.Success)
            .Select(match => match.Groups[1].Value.ToUpperInvariant())
            .Where(IsCode)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (candidates.Length != 1)
            return false;

        deviceId = parsedDeviceId;
        verificationCode = candidates[0];
        return true;
    }

    private static (bool Known, bool Active) DetectRemoteSession(IReadOnlyList<AccessibleText> nodes)
    {
        var text = string.Join("\n", nodes.Select(x => x.Text)).ToLowerInvariant();
        if (text.Contains("device is being controlled") ||
            text.Contains("this device is being controlled") ||
            text.Contains("being controlled by"))
            return (true, true);

        var match = Regex.Match(text, @"(\d+)\s+devices?\s+controlling\s+this\s+pc");
        if (match.Success && int.TryParse(match.Groups[1].Value, out var count))
            return (true, count > 0);

        if (text.Contains("no devices controlling this pc") ||
            text.Contains("not being controlled") ||
            text.Contains("0 devices controlling this pc"))
            return (true, false);

        return (false, false);
    }

    private static string BuildDiagnostics(
        int windowCount,
        WindowInfo window,
        int nodeCount,
        string deviceId,
        string verificationCode,
        CopyCaptureResult copy)
    {
        var idState = string.IsNullOrWhiteSpace(deviceId) ? "tidak" : "terbaca";
        var codeState = string.IsNullOrWhiteSpace(verificationCode) ? "tidak" : "terbaca";
        var buttonState = copy.Action == "cooldown"
            ? "belum diuji (cooldown)"
            : copy.ButtonFound ? "ditemukan" : "tidak ditemukan";
        var actionState = copy.Action;
        var clipboardState = copy.ClipboardChanged ? "berubah" : "tidak berubah";
        var parsedState = copy.PairParsed ? "valid" :
            copy.ClipboardChanged ? "format tidak cocok" : "belum";
        return $"Window={windowCount}; utama={window.Title}; area={window.Area}; " +
               $"UIA={nodeCount} elemen; ID={idState}; kode={codeState}; " +
               $"Copy={buttonState}; aksi={actionState}; clipboard={clipboardState}; pasangan={parsedState}.";
    }

    private static double ScoreNearLabel(
        Rectangle label, Rectangle candidate, int indexDelta,
        int minY, int maxY, int maxX)
    {
        if (label.IsEmpty || candidate.IsEmpty)
            return double.MaxValue;

        var dx = Math.Abs(candidate.Left - label.Left);
        var dy = candidate.Top - label.Top;
        if (dy < minY || dy > maxY || dx > maxX)
            return double.MaxValue;

        return dy * 2d + dx + Math.Max(0, indexDelta) * 0.01d;
    }

    private static bool TryDeviceToken(string text, out string value)
    {
        var match = DeviceValueRegex.Match(text ?? "");
        value = match.Success ? match.Groups[1].Value : "";
        return match.Success;
    }

    private static bool TryCodeToken(string text, out string value)
    {
        var match = CodeValueRegex.Match(text ?? "");
        value = match.Success ? match.Value.ToUpperInvariant() : "";
        return match.Success && IsCode(value);
    }

    private static bool IsCode(string value) =>
        value.Length == 8 &&
        !NonCodes.Contains(value) &&
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
