using System.Runtime.InteropServices;
using System.Text.Json;
using AniGamesReady.Agent.Shared;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace AniGamesReady.Agent.Service;

public sealed class AgentWorker(
    AgentApiClient api,
    ILogger<AgentWorker> logger) : BackgroundService
{
    private const string Version = "0.1.0";
    private AgentConfig? config;
    private AgentStatus status = new();

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            config = AgentStorage.LoadOrCreate();
            status.AgentDeviceId = config.AgentDeviceId;
            status.AgentVersion = Version;
            PublishStatus("STARTING", config.IsPaired ? "Menyambungkan Agent ke StarDesk Custom." : "Menunggu persetujuan Owner.");
        }
        catch (Exception ex)
        {
            logger.LogCritical(ex, "Agent credential store could not be opened.");
            PublishStatus("ERROR", ex.Message);
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                if (config is null) throw new InvalidOperationException("AGENT_CONFIG_MISSING");
                if (!config.IsPaired)
                    await RequestEnrollmentAsync(stoppingToken);
                else
                    await HeartbeatAndRunCommandsAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "StarDesk Agent heartbeat cycle failed.");
                var revoked = ex.Message.Contains("AGENT_REVOKED", StringComparison.OrdinalIgnoreCase) ||
                              ex.Message.Contains("IDENTITY_REJECTED", StringComparison.OrdinalIgnoreCase);
                PublishStatus(revoked ? "REVOKED" : (config?.IsPaired == true ? "OFFLINE" : "MENUNGGU OWNER"),
                    revoked ? "Akses Agent sudah dicabut. Hubungi Owner untuk pairing ulang." :
                    "Gateway belum dapat dijangkau: " + ex.Message);
            }

            try { await Task.Delay(TimeSpan.FromSeconds(15), stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
        }
    }

    private async Task RequestEnrollmentAsync(CancellationToken cancellationToken)
    {
        var c = config ?? throw new InvalidOperationException("AGENT_CONFIG_MISSING");
        var result = await api.RpcAsync("androiddb_v0_agent_enroll_request", new
        {
            p_agent_device_id = c.AgentDeviceId,
            p_agent_token_hash = c.AgentTokenHash,
            p_pair_code_hash = c.PairCodeHash,
            p_computer_name = Environment.MachineName,
            p_windows_version = RuntimeInformation.OSDescription,
            p_gpu_name = "GPU belum dideteksi — atur kelas GPU di Admin Owner",
            p_agent_version = Version
        }, null, cancellationToken);

        if (AgentApiClient.ReadBoolean(result, "paired"))
        {
            c.IsPaired = true;
            c.PairCode = "";
            c.PairCodeHash = "";
            AgentStorage.Save(c);
            PublishStatus("ONLINE", "Pairing Owner diterima. Menghubungkan heartbeat Agent.");
        }
        else
        {
            PublishStatus("MENUNGGU OWNER", "Masukkan kode 8 digit ini pada menu Agent PC di Admin Android.", c.PairCode);
        }
    }

    private async Task HeartbeatAndRunCommandsAsync(CancellationToken cancellationToken)
    {
        var c = config ?? throw new InvalidOperationException("AGENT_CONFIG_MISSING");
        var result = await api.RpcAsync("androiddb_v0_agent_heartbeat", new
        {
            p_agent_version = Version,
            p_computer_name = Environment.MachineName,
            p_windows_version = RuntimeInformation.OSDescription,
            p_gpu_name = "GPU ditetapkan oleh Owner Admin"
        }, c.AgentToken, cancellationToken);

        if (!AgentApiClient.ReadBoolean(result, "paired"))
            throw new InvalidOperationException("ANDROIDDB_V0_AGENT_REVOKED_OR_UNPAIRED");

        status.LastHeartbeatUtc = DateTimeOffset.UtcNow;
        PublishStatus("ONLINE", "Agent terhubung. Status ini hanya heartbeat Windows, bukan status StarDesk Streaming.");

        if (!result.TryGetProperty("commands", out var commands) || commands.ValueKind != JsonValueKind.Array)
            return;

        foreach (var command in commands.EnumerateArray())
        {
            cancellationToken.ThrowIfCancellationRequested();
            var id = AgentApiClient.ReadString(command, "id");
            var name = AgentApiClient.ReadString(command, "command");
            if (!Guid.TryParse(id, out var commandId) || string.IsNullOrWhiteSpace(name))
                continue;

            await ExecuteCommandAsync(commandId, name, command, cancellationToken);
        }
    }

    private async Task ExecuteCommandAsync(
        Guid commandId, string commandName, JsonElement command, CancellationToken cancellationToken)
    {
        var c = config ?? throw new InvalidOperationException("AGENT_CONFIG_MISSING");
        try
        {
            await api.RpcAsync("androiddb_v0_agent_ack", new
            {
                p_command_id = commandId,
                p_status = "started",
                p_result = "Agent menerima perintah yang diizinkan."
            }, c.AgentToken, cancellationToken);

            var result = await WindowsCommandExecutor.ExecuteAsync(commandName, command, cancellationToken);
            await api.RpcAsync("androiddb_v0_agent_ack", new
            {
                p_command_id = commandId,
                p_status = "completed",
                p_result = result
            }, c.AgentToken, cancellationToken);
            logger.LogInformation("Agent command {CommandId} finished: {Command}", commandId, commandName);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Agent command {CommandId} failed.", commandId);
            try
            {
                await api.RpcAsync("androiddb_v0_agent_ack", new
                {
                    p_command_id = commandId,
                    p_status = "failed",
                    p_result = ex.Message
                }, c.AgentToken, cancellationToken);
            }
            catch (Exception ackEx)
            {
                logger.LogError(ackEx, "Could not send failed acknowledgement for {CommandId}.", commandId);
            }
        }
    }

    private void PublishStatus(string state, string message, string? pairingCode = null)
    {
        status.State = state;
        status.Message = message;
        status.PairingCode = pairingCode ?? (config?.IsPaired == true ? "" : config?.PairCode ?? "");
        status.IsPaired = config?.IsPaired == true;
        status.AgentDeviceId = config?.AgentDeviceId ?? status.AgentDeviceId;
        status.AgentVersion = Version;
        try { AgentStorage.WriteStatus(status); }
        catch (Exception ex) { logger.LogError(ex, "Cannot write tray status."); }
    }
}

internal static class WindowsCommandExecutor
{
    public static async Task<string> ExecuteAsync(
        string command, JsonElement envelope, CancellationToken cancellationToken)
    {
        return command switch
        {
            "message" => await SendMessageAsync(envelope, cancellationToken),
            "logoff" => LogoffInteractiveSessions(),
            "restart" => await SchedulePowerActionAsync(restart: true, cancellationToken),
            "shutdown" => await SchedulePowerActionAsync(restart: false, cancellationToken),
            _ => throw new InvalidOperationException("AGENT_COMMAND_NOT_ALLOWED")
        };
    }

    private static async Task<string> SendMessageAsync(JsonElement envelope, CancellationToken cancellationToken)
    {
        if (!envelope.TryGetProperty("payload", out var payload) ||
            !payload.TryGetProperty("message", out var value))
            throw new InvalidOperationException("AGENT_MESSAGE_EMPTY");
        var message = (value.GetString() ?? "").Trim();
        message = new string(message.Where(ch => !char.IsControl(ch)).Take(240).ToArray());
        if (message.Length == 0) throw new InvalidOperationException("AGENT_MESSAGE_EMPTY");

        var exe = Path.Combine(Environment.SystemDirectory, "msg.exe");
        var start = new System.Diagnostics.ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true
        };
        start.ArgumentList.Add("/TIME:60");
        start.ArgumentList.Add("*");
        start.ArgumentList.Add(message);
        using var process = System.Diagnostics.Process.Start(start)
            ?? throw new InvalidOperationException("WINDOWS_MESSAGE_START_FAILED");
        await process.WaitForExitAsync(cancellationToken);
        if (process.ExitCode != 0)
            throw new InvalidOperationException("WINDOWS_MESSAGE_DELIVERY_FAILED");
        return "Pesan diterima oleh msg.exe untuk sesi Windows aktif. Tampilan di layar pengguna tidak dapat diverifikasi.";
    }

    private static string LogoffInteractiveSessions()
    {
        if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out var buffer, out var count))
            throw new InvalidOperationException("WINDOWS_SESSION_ENUMERATION_FAILED");

        try
        {
            var size = Marshal.SizeOf<WtsSessionInfo>();
            var loggedOff = 0;
            var errors = 0;
            for (var i = 0; i < count; i++)
            {
                var item = Marshal.PtrToStructure<WtsSessionInfo>(IntPtr.Add(buffer, i * size));
                if (item.SessionId <= 0 || item.State != WtsConnectState.Active) continue;
                if (WTSLogoffSession(IntPtr.Zero, item.SessionId, false))
                    loggedOff++;
                else
                    errors++;
            }
            if (loggedOff == 0 && errors == 0)
                throw new InvalidOperationException("NO_ACTIVE_WINDOWS_USER_SESSION");
            if (loggedOff == 0)
                throw new InvalidOperationException("WINDOWS_LOGOFF_REJECTED");
            return $"Logoff dikirim ke {loggedOff} sesi Windows aktif tanpa force-close.";
        }
        finally
        {
            WTSFreeMemory(buffer);
        }
    }

    private static async Task<string> SchedulePowerActionAsync(bool restart, CancellationToken cancellationToken)
    {
        var exe = Path.Combine(Environment.SystemDirectory, "shutdown.exe");
        var start = new System.Diagnostics.ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true
        };
        start.ArgumentList.Add(restart ? "/r" : "/s");
        start.ArgumentList.Add("/t");
        start.ArgumentList.Add("10");
        start.ArgumentList.Add("/c");
        start.ArgumentList.Add(restart
            ? "Restart diminta oleh Ani Games Ready Owner"
            : "Shutdown diminta oleh Ani Games Ready Owner");

        using var process = System.Diagnostics.Process.Start(start)
            ?? throw new InvalidOperationException("WINDOWS_POWER_ACTION_START_FAILED");
        await process.WaitForExitAsync(cancellationToken);
        if (process.ExitCode != 0)
            throw new InvalidOperationException("WINDOWS_POWER_ACTION_REJECTED");
        return (restart ? "Restart" : "Shutdown") +
               " diterima Windows dan dijadwalkan 10 detik. Tidak menggunakan opsi force-close aplikasi.";
    }

    private enum WtsConnectState
    {
        Active = 0, Connected, ConnectQuery, Shadow, Disconnected,
        Idle, Listen, Reset, Down, Init
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WtsSessionInfo
    {
        public int SessionId;
        public IntPtr StationName;
        public WtsConnectState State;
    }

    [DllImport("wtsapi32.dll", EntryPoint = "WTSEnumerateSessionsW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool WTSEnumerateSessions(
        IntPtr server, int reserved, int version, out IntPtr sessionInfo, out int count);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSLogoffSession(IntPtr server, int sessionId, bool wait);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr memory);
}
