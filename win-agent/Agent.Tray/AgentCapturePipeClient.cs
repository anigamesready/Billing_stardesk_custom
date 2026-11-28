using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace AniGamesReady.Agent.Tray;

public static class AgentCapturePipeClient
{
    private const string PipeName = "AniGamesReady.StarDeskAgent.Capture.v1";

    public static Task SyncAsync(
        StarDeskCaptureSnapshot capture,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(capture.DeviceId) ||
            string.IsNullOrWhiteSpace(capture.VerificationCode) ||
            string.IsNullOrWhiteSpace(capture.InviteUrl))
            throw new InvalidOperationException("STARDESK_THREE_FIELD_CAPTURE_REQUIRED");

        return SendAsync(new
        {
            action = "pairing_refresh",
            event_id = Guid.NewGuid(),
            stardesk_device_id = capture.DeviceId,
            verification_code = capture.VerificationCode,
            invite_url = capture.InviteUrl
        }, cancellationToken);
    }

    public static Task SendSessionEventAsync(
        string eventType,
        CancellationToken cancellationToken = default)
    {
        var normalized = (eventType ?? "").Trim().ToLowerInvariant();
        if (normalized is not ("connected" or "ended"))
            throw new ArgumentOutOfRangeException(nameof(eventType), "STARDESK_SESSION_EVENT_INVALID");

        return SendAsync(new
        {
            action = "session_event",
            event_type = normalized,
            event_id = Guid.NewGuid()
        }, cancellationToken);
    }

    private static async Task SendAsync(object request, CancellationToken cancellationToken)
    {
        using var pipe = new NamedPipeClientStream(
            ".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        await pipe.ConnectAsync(timeout.Token);

        using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true)
        {
            AutoFlush = true
        };
        using var reader = new StreamReader(pipe, Encoding.UTF8, false, 1024, true);

        await writer.WriteLineAsync(JsonSerializer.Serialize(request));
        var responseLine = await reader.ReadLineAsync(timeout.Token);
        if (string.IsNullOrWhiteSpace(responseLine) || responseLine.Length > 4096)
            throw new InvalidOperationException("AGENT_CAPTURE_PIPE_INVALID_RESPONSE");

        using var document = JsonDocument.Parse(responseLine);
        var root = document.RootElement;
        if (!root.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True)
        {
            var error = root.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.String
                ? e.GetString()
                : "STAR_DESK_SYNC_REJECTED";
            throw new InvalidOperationException(error ?? "STAR_DESK_SYNC_REJECTED");
        }
    }
}
