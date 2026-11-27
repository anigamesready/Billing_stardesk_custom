using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Windows.Automation;

namespace AniGamesReady.Agent.Tray;

public sealed record StarDeskCaptureSnapshot(
    string DeviceId,
    string VerificationCode,
    string WindowTitle);

public static class StarDeskUiCapture
{
    private static readonly string[] DeviceLabels =
        ["deviceid", "stardeskdeviceid", "deviceidentifier"];
    private static readonly string[] CodeLabels =
        ["verificationcode", "verifycode", "securitycode"];

    private static readonly HashSet<string> NonValues = new(StringComparer.OrdinalIgnoreCase)
    {
        "copy", "copied", "refresh", "device", "deviceid", "stardeskdeviceid",
        "verification", "verificationcode", "verifycode", "code", "securitycode",
        "remote", "assist", "support", "start", "stop", "close", "open", "share"
    };

    public static StarDeskCaptureSnapshot Read()
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
                {
                    candidates.Add((root, title));
                }
            }
            catch { }
        }

        if (candidates.Count == 0)
            throw new InvalidOperationException(
                "STAR_DESK_WINDOW_NOT_FOUND: buka jendela StarDesk Windows terlebih dahulu.");

        foreach (var candidate in candidates)
        {
            var values = CollectAccessibleText(candidate.Root);
            var deviceId = FindField(values, DeviceLabels);
            var verificationCode = FindField(values, CodeLabels);
            if (!string.IsNullOrWhiteSpace(deviceId) &&
                !string.IsNullOrWhiteSpace(verificationCode))
            {
                return new StarDeskCaptureSnapshot(
                    deviceId, verificationCode, candidate.Title);
            }
        }

        throw new InvalidOperationException(
            "STAR_DESK_FIELDS_NOT_ACCESSIBLE: buka menu Remote Assist yang menampilkan Device ID dan Verification Code, lalu tekan Sinkronkan StarDesk lagi.");
    }

    private static List<string> CollectAccessibleText(AutomationElement root)
    {
        var values = new List<string>(64);
        AddElementText(root, values);

        var descendants = root.FindAll(TreeScope.Descendants, Condition.TrueCondition);
        var count = Math.Min(descendants.Count, 4000);
        for (var i = 0; i < count; i++)
            AddElementText(descendants[i], values);

        return values.Where(x => !string.IsNullOrWhiteSpace(x))
            .Select(x => x.Trim())
            .Distinct(StringComparer.Ordinal)
            .ToList();
    }

    private static void AddElementText(AutomationElement element, List<string> values)
    {
        try
        {
            var name = element.Current.Name;
            if (!string.IsNullOrWhiteSpace(name)) values.Add(name);
        }
        catch { }

        try
        {
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var valuePattern) &&
                valuePattern is ValuePattern value)
            {
                var text = value.Current.Value;
                if (!string.IsNullOrWhiteSpace(text)) values.Add(text);
            }
        }
        catch { }

        try
        {
            if (element.TryGetCurrentPattern(TextPattern.Pattern, out var textPattern) &&
                textPattern is TextPattern content)
            {
                var text = content.DocumentRange.GetText(512);
                if (!string.IsNullOrWhiteSpace(text)) values.Add(text);
            }
        }
        catch { }
    }

    private static string FindField(IReadOnlyList<string> values, string[] labels)
    {
        for (var i = 0; i < values.Count; i++)
        {
            var normalized = Normalize(values[i]);
            if (labels.Contains(normalized, StringComparer.OrdinalIgnoreCase))
            {
                for (var next = i + 1; next < Math.Min(values.Count, i + 6); next++)
                {
                    var candidate = CleanToken(values[next]);
                    if (IsCandidate(candidate)) return candidate;
                }
            }

            foreach (var label in labels)
            {
                var labelPattern = label switch
                {
                    "deviceid" or "stardeskdeviceid" => @"device\s*id",
                    "deviceidentifier" => @"device\s*identifier",
                    "verificationcode" => @"verification\s*code",
                    "verifycode" => @"verify\s*code",
                    "securitycode" => @"security\s*code",
                    _ => Regex.Escape(label)
                };
                var match = Regex.Match(values[i],
                    @"(?i)\b" + labelPattern + @"\b\s*[:：]?\s*([A-Za-z0-9][A-Za-z0-9._:-]{3,179})");
                if (match.Success && IsCandidate(match.Groups[1].Value))
                    return match.Groups[1].Value;
            }
        }
        return "";
    }
    private static string Normalize(string value) =>
        Regex.Replace(value ?? "", "[^A-Za-z0-9]", "").ToLowerInvariant();

    private static string CleanToken(string value) =>
        (value ?? "").Trim().Trim(':', '：', '=', '|', '\'', '"', '(', ')', '[', ']', ',', ';');

    private static bool IsCandidate(string value) =>
        value.Length is >= 4 and <= 180 &&
        !NonValues.Contains(value) &&
        Regex.IsMatch(value, "^[A-Za-z0-9][A-Za-z0-9._:-]{3,179}$");
}
