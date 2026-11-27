using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace AniGamesReady.Agent.Tray;

public static class AgentCapturePipeClient
{
    private const string PipeName = "AniGamesReady.StarDeskAgent.Capture.v1";

    public static async Task SyncAsync(StarDeskCaptureSnapshot capture, CancellationToken cancellationToken = default)
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

        var request = JsonSerializer.Serialize(new
        {
            stardesk_device_id = capture.DeviceId,
            verification_code = capture.VerificationCode
        });
        await writer.WriteLineAsync(request);
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
