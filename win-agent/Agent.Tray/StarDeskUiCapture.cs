using System.Diagnostics;
using System.Drawing;
using System.Text.RegularExpressions;
using System.Windows.Automation;

namespace AniGamesReady.Agent.Tray;

public sealed record StarDeskCaptureSnapshot(
    string DeviceId,
    string VerificationCode,
    string WindowTitle,
    bool RemoteSessionStateKnown = false,
    bool RemoteSessionActive = false);

public static class StarDeskUiCapture
{
    private static readonly Regex DeviceValueRegex = new(
        @"(?<!\d)(\d{3}(?:[\s-]+\d{3}){2,3}|\d{9})(?!\d)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex CodeValueRegex = new(
        @"(?<![A-Z0-9])[A-Z0-9]{8}(?![A-Z0-9])",
        RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private sealed record AccessibleText(string Text, Rectangle Bounds);

    private static readonly HashSet<string> NonCodes = new(StringComparer.OrdinalIgnoreCase)
    {
        "COPY", "COPIED", "REFRESH", "DEVICE", "DEVICEID", "STARDESKDEVICEID",
        "VERIFICATION", "VERIFICATIONCODE", "VERIFYCODE", "CODE", "SECURITYCODE",
        "REMOTE", "ASSIST", "SUPPORT", "START", "STOP", "CLOSE", "OPEN", "SHARE",
        "CUSTOM", "CUSTOMCODE", "CUSTOMCODEONLY", "ONLY", "SET",
        "USEBOTH", "USEBOTHCODES", "TEMPORARY"
    };

    public static StarDeskCaptureSnapshot Read()
    {
        var snapshot = ReadPartial();
        if (string.IsNullOrWhiteSpace(snapshot.DeviceId) ||
            string.IsNullOrWhiteSpace(snapshot.VerificationCode))
        {
            throw new InvalidOperationException(
                "STAR_DESK_FIELDS_NOT_ACCESSIBLE: Device ID atau kode sementara belum terbaca. Buka Remote Support dan pastikan Verification Method memakai Use Both Codes.");
        }
        return snapshot;
    }

    public static StarDeskCaptureSnapshot ReadPartial()
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

        var roots = AutomationElement.RootElement.FindAll(TreeScope.Children, Condition.TrueCondition);
        var candidates = new List<(AutomationElement Root, string Title)>();
        for (var i = 0; i < roots.Count; i++)
        {
            var root = roots[i];
            try
            {
                var pid = (int)root.GetCurrentPropertyValue(AutomationElement.ProcessIdProperty);
                var title = root.Current.Name ?? "";
                if (processIds.Contains(pid) ||
                    title.Contains("StarDesk", StringComparison.OrdinalIgnoreCase))
                    candidates.Add((root, title));
            }
            catch { }
        }

        if (candidates.Count == 0)
            throw new InvalidOperationException("STAR_DESK_WINDOW_NOT_FOUND");

        foreach (var candidate in candidates)
        {
            var nodes = CollectAccessibleText(candidate.Root);
            if (nodes.Count == 0) continue;

            var deviceId = FindDeviceId(nodes);
            var verificationCode = FindVerificationCode(nodes);
            var sessionState = DetectRemoteSession(nodes);
            if (!string.IsNullOrWhiteSpace(deviceId) ||
                !string.IsNullOrWhiteSpace(verificationCode) ||
                sessionState.Known)
            {
                return new StarDeskCaptureSnapshot(
                    deviceId, verificationCode, candidate.Title,
                    sessionState.Known, sessionState.Active);
            }
        }

        return new StarDeskCaptureSnapshot("", "", candidates[0].Title);
    }

    private static List<AccessibleText> CollectAccessibleText(AutomationElement root)
    {
        var values = new List<AccessibleText>(96);
        AddElementText(root, values);

        AutomationElementCollection descendants;
        try { descendants = root.FindAll(TreeScope.Descendants, Condition.TrueCondition); }
        catch { return values; }

        var count = Math.Min(descendants.Count, 5000);
        for (var i = 0; i < count; i++)
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
                var text = content.DocumentRange.GetText(1024);
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
            var labelMatch = Regex.Match(node.Text,
                @"(?i)\bdevice\s*id\b\s*[:：]?\s*(\d{3}(?:[\s-]+\d{3}){2,3}|\d{9})");
            if (labelMatch.Success)
                return NormalizeDeviceId(labelMatch.Groups[1].Value);
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
        if (labelIndex < 0) return "";

        var label = nodes[labelIndex];
        var nearby = nodes
            .Select((node, index) => new { node, index })
            .Where(x => x.index != labelIndex && TryDeviceToken(x.node.Text, out _))
            .Select(x => new
            {
                x.node,
                score = ScoreNearLabel(label.Bounds, x.node.Bounds, x.index - labelIndex, 100, 180)
            })
            .Where(x => x.score < double.MaxValue)
            .OrderBy(x => x.score)
            .FirstOrDefault();
        if (nearby is not null && TryDeviceToken(nearby.node.Text, out var id))
            return NormalizeDeviceId(id);

        for (var i = labelIndex + 1; i < Math.Min(nodes.Count, labelIndex + 12); i++)
        {
            if (TryDeviceToken(nodes[i].Text, out var sequentialId))
                return NormalizeDeviceId(sequentialId);
        }
        return "";
    }

    private static string FindVerificationCode(IReadOnlyList<AccessibleText> nodes)
    {
        for (var i = 0; i < nodes.Count; i++)
        {
            var normalized = Normalize(nodes[i].Text);
            if (normalized is "verificationcode" or "verifycode" or "securitycode")
            {
                for (var j = i + 1; j < Math.Min(nodes.Count, i + 10); j++)
                    if (TryCodeToken(nodes[j].Text, out var explicitCode))
                        return explicitCode;
            }

            var explicitMatch = Regex.Match(nodes[i].Text,
                @"(?i)\b(?:verification|verify|security)\s*code\b\s*[:：]?\s*([A-Z0-9]{8})");
            if (explicitMatch.Success && IsCode(explicitMatch.Groups[1].Value))
                return explicitMatch.Groups[1].Value.ToUpperInvariant();
        }

        // StarDesk 1.6.x shows "Verification Method" above the temporary code.
        // The code is a sibling element on the next visual row, not a named field.
        var methodIndex = -1;
        for (var i = 0; i < nodes.Count; i++)
        {
            if (Normalize(nodes[i].Text).Contains("verificationmethod", StringComparison.Ordinal))
            {
                methodIndex = i;
                break;
            }
        }

        if (methodIndex >= 0)
        {
            var label = nodes[methodIndex];
            var positioned = nodes
                .Select((node, index) => new { node, index })
                .Where(x => x.index != methodIndex && TryCodeToken(x.node.Text, out _))
                .Select(x => new
                {
                    x.node,
                    score = ScoreNearLabel(label.Bounds, x.node.Bounds, x.index - methodIndex, 96, 260)
                })
                .Where(x => x.score < double.MaxValue)
                .OrderBy(x => x.score)
                .FirstOrDefault();

            if (positioned is not null && TryCodeToken(positioned.node.Text, out var code))
                return code;

            for (var i = methodIndex + 1; i < Math.Min(nodes.Count, methodIndex + 24); i++)
            {
                if (TryCodeToken(nodes[i].Text, out var sequentialCode))
                    return sequentialCode;
            }
        }

        foreach (var node in nodes)
            if (TryCodeToken(node.Text, out var candidate))
                return candidate;

        return "";
    }

    private static (bool Known, bool Active) DetectRemoteSession(IReadOnlyList<AccessibleText> nodes)
    {
        var text = string.Join("\n", nodes.Select(x => x.Text)).ToLowerInvariant();
        if (text.Contains("device is being controlled") ||
            text.Contains("this device is being controlled") ||
            text.Contains("being controlled by"))
            return (true, true);

        var countMatch = Regex.Match(text, @"(\d+)\s+devices?\s+controlling\s+this\s+pc");
        if (countMatch.Success &&
            int.TryParse(countMatch.Groups[1].Value, out var count))
            return (true, count > 0);

        if (text.Contains("no devices controlling this pc") ||
            text.Contains("not being controlled") ||
            text.Contains("0 devices controlling this pc"))
            return (true, false);

        return (false, false);
    }

    private static double ScoreNearLabel(
        Rectangle label, Rectangle candidate, int indexDelta,
        int maxVerticalDistance, int maxHorizontalDistance)
    {
        if (label.IsEmpty)
            return indexDelta >= 1 ? 100000d + indexDelta : double.MaxValue;
        if (candidate.IsEmpty)
            return indexDelta >= 1 ? 100000d + indexDelta : double.MaxValue;

        var dx = Math.Abs(candidate.Left - label.Left);
        var dy = candidate.Top - label.Top;
        if (dy < -8 || dy > maxVerticalDistance || dx > maxHorizontalDistance)
            return double.MaxValue;

        return dy * 2d + dx + Math.Max(0, indexDelta) * 0.02d;
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
        if (Regex.IsMatch(cleaned, @"^\d{3}(?:[\s-]+\d{3}){2,3}$"))
            return Regex.Replace(cleaned, @"[\s-]+", "");
        return cleaned;
    }

    private static string Normalize(string value) =>
        Regex.Replace(value ?? "", "[^A-Za-z0-9]", "").ToLowerInvariant();
}
