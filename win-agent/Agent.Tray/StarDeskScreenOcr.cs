using System.Drawing;
using System.IO;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using TesseractOCR;
using TesseractOCR.Enums;
using TesseractImage = TesseractOCR.Pix.Image;

namespace AniGamesReady.Agent.Tray;

internal sealed record StarDeskOcrResult(
    string DeviceId, string VerificationCode,
    bool PageRecognized, bool RemoteSessionActive, string Detail);

internal static class StarDeskScreenOcr
{
    private const uint PwRenderFullContent = 2;
    private static readonly object EngineLock = new();
    private static Engine? engine;

    private static readonly Regex DeviceIdRegex = new(
        @"(?<!\d)(\d{3}(?:[\s-]+\d{3}){2}|\d{9})(?!\d)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex CodeRegex = new(
        @"(?<![A-Z0-9])[A-Z0-9]{8}(?![A-Z0-9])",
        RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly HashSet<string> NonCodes = new(StringComparer.OrdinalIgnoreCase)
    {
        "STARDESK", "KARAKTER", "COPY", "COPIED", "REFRESH", "DEVICE", "DEVICEID",
        "VERIFICATION", "VERIFICATIONCODE", "METHOD", "REMOTESUPPORT", "THISDEVICE",
        "USEBOTH", "USEBOTHCODES", "TEMPORARY", "CUSTOMCODE", "CUSTOMCODEONLY",
        "ALLOWREMOTE", "SUPPORT"
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);
    [DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint flags);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hwnd);

    internal static StarDeskOcrResult Read(IntPtr hwnd, bool wasVisible, bool wasMinimized)
    {
        try
        {
            var bytes = CaptureWindow(hwnd, wasVisible, wasMinimized);
            if (bytes.Length == 0)
                return Empty("gambar jendela utama tidak bisa ditangkap di background");

            lock (EngineLock)
            {
                engine ??= CreateEngine();
                using var image = TesseractImage.LoadFromMemory(bytes);
                using var page = engine.Process(image, PageSegMode.Auto);
                return ParseRemoteSupportPage(page.Text ?? "", page.MeanConfidence);
            }
        }
        catch (DllNotFoundException)
        {
            return Empty("OCR native runtime tidak ada; perlu Microsoft Visual C++ 2015-2022 x64");
        }
        catch (FileNotFoundException ex) when (
            ex.Message.Contains("eng.traineddata", StringComparison.OrdinalIgnoreCase) ||
            ex.FileName?.Contains("eng.traineddata", StringComparison.OrdinalIgnoreCase) == true)
        {
            return Empty("model tessdata/eng.traineddata tidak ditemukan");
        }
        catch (Exception ex)
        {
            // Never log OCR text or captured credentials.
            return Empty("OCR gagal: " + ex.GetType().Name);
        }
    }

    private static Engine CreateEngine()
    {
        var dataPath = Path.Combine(AppContext.BaseDirectory, "tessdata");
        var modelPath = Path.Combine(dataPath, "eng.traineddata");
        if (!File.Exists(modelPath))
            throw new FileNotFoundException("eng.traineddata missing", modelPath);

        return new Engine(dataPath, Language.English, EngineMode.Default);
    }

    private static byte[] CaptureWindow(IntPtr hwnd, bool wasVisible, bool wasMinimized)
    {
        if (!GetWindowRect(hwnd, out var rect))
            return [];

        var width = rect.Right - rect.Left;
        var height = rect.Bottom - rect.Top;
        if (width is < 320 or > 8192 || height is < 220 or > 8192)
            return [];

        using var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        bool rendered;
        using (var graphics = Graphics.FromImage(bitmap))
        {
            var hdc = graphics.GetHdc();
            try
            {
                rendered = PrintWindow(hwnd, hdc, PwRenderFullContent);
                if (!rendered)
                    rendered = PrintWindow(hwnd, hdc, 0);
            }
            finally { graphics.ReleaseHdc(hdc); }
        }

        // For a normal visible window, screen copy is a fallback for GPU surfaces
        // that do not implement PrintWindow. Hidden/minimized windows are never raised.
        if ((!rendered || IsMostlyBlank(bitmap)) &&
            wasVisible && !wasMinimized && IsWindowVisible(hwnd) && !IsIconic(hwnd))
        {
            try
            {
                using var graphics = Graphics.FromImage(bitmap);
                graphics.CopyFromScreen(rect.Left, rect.Top, 0, 0,
                    new Size(width, height), CopyPixelOperation.SourceCopy);
                rendered = true;
            }
            catch { rendered = false; }
        }

        if (!rendered || IsMostlyBlank(bitmap))
            return [];

        using var stream = new MemoryStream();
        bitmap.Save(stream, System.Drawing.Imaging.ImageFormat.Png);
        return stream.ToArray();
    }

    private static bool IsMostlyBlank(Bitmap bitmap)
    {
        var sampled = 0;
        var lit = 0;
        var stepX = Math.Max(4, bitmap.Width / 80);
        var stepY = Math.Max(4, bitmap.Height / 50);
        for (var y = stepY / 2; y < bitmap.Height; y += stepY)
        for (var x = stepX / 2; x < bitmap.Width; x += stepX)
        {
            var pixel = bitmap.GetPixel(x, y);
            sampled++;
            if (pixel.R + pixel.G + pixel.B > 95)
                lit++;
        }
        return sampled == 0 || lit < Math.Max(8, sampled / 500);
    }

    internal static StarDeskOcrResult ParseRemoteSupportPage(string text, float meanConfidence)
    {
        if (string.IsNullOrWhiteSpace(text) || meanConfidence < 35)
            return Empty("OCR kosong atau confidence terlalu rendah");

        var normalized = Normalize(text);
        var pageRecognized =
            normalized.Contains("remotesupport", StringComparison.Ordinal) &&
            normalized.Contains("thisdev", StringComparison.Ordinal) &&
            normalized.Contains("verificationmethod", StringComparison.Ordinal);
        if (!pageRecognized)
            return Empty("jendela utama terbaca, tetapi halaman Remote Support tidak terverifikasi");

        var pairs = new List<(string DeviceId, string Code)>();
        var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n').Split('\n');

        foreach (var line in lines)
        {
            var id = DeviceIdRegex.Match(line);
            if (!id.Success)
                continue;

            // Only accept a single code to the right of the Device ID on the
            // same OCR line. This blocks unrelated words from titles/sidebar.
            var afterId = line[(id.Index + id.Length)..];
            var candidates = CodeRegex.Matches(afterId)
                .Select(x => x.Value.ToUpperInvariant())
                .Where(x => !NonCodes.Contains(x))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();

            if (candidates.Length == 1)
            {
                pairs.Add((
                    Regex.Replace(id.Groups[1].Value, @"[\s-]+", ""),
                    candidates[0]));
            }
        }

        var unique = pairs.Distinct().ToArray();
        if (unique.Length != 1)
            return new StarDeskOcrResult(
                "", "", true, DetectRemoteSession(normalized),
                unique.Length == 0
                    ? "halaman Remote Support terbaca, tetapi pasangan ID+kode satu baris tidak ditemukan"
                    : "pasangan ID+kode lebih dari satu; hasil ditolak");

        return new StarDeskOcrResult(
            unique[0].DeviceId, unique[0].Code,
            true, DetectRemoteSession(normalized),
            "pasangan ID+kode terbaca melalui OCR lokal");
    }

    private static bool DetectRemoteSession(string normalized)
    {
        if (normalized.Contains("deviceisbeingcontrolled", StringComparison.Ordinal) ||
            normalized.Contains("thisdeviceisbeingcontrolled", StringComparison.Ordinal) ||
            normalized.Contains("beingcontrolledby", StringComparison.Ordinal))
            return true;

        var match = Regex.Match(normalized, @"(\d+)devices?controllingthispc");
        return match.Success && int.TryParse(match.Groups[1].Value, out var count) && count > 0;
    }

    private static string Normalize(string value) =>
        Regex.Replace(value ?? "", "[^A-Za-z0-9]", "").ToLowerInvariant();

    private static StarDeskOcrResult Empty(string detail) =>
        new("", "", false, false, detail);
}
