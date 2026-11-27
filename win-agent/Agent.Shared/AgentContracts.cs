using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AniGamesReady.Agent.Shared;

public sealed class AgentConfig
{
    public string AgentDeviceId { get; set; } = "";
    public string AgentToken { get; set; } = "";
    public string AgentTokenHash { get; set; } = "";
    public string PairCode { get; set; } = "";
    public string PairCodeHash { get; set; } = "";
    public bool IsPaired { get; set; }
}

internal sealed class StoredAgentConfig
{
    public string AgentDeviceId { get; set; } = "";
    public string ProtectedToken { get; set; } = "";
    public string AgentTokenHash { get; set; } = "";
    public string PairCode { get; set; } = "";
    public string PairCodeHash { get; set; } = "";
    public bool IsPaired { get; set; }
}

public sealed class AgentStatus
{
    public string AgentDeviceId { get; set; } = "";
    public string State { get; set; } = "STARTING";
    public string PairingCode { get; set; } = "";
    public bool IsPaired { get; set; }
    public string Message { get; set; } = "";
    public DateTimeOffset? LastHeartbeatUtc { get; set; }
    public string AgentVersion { get; set; } = "0.2.0";
    public string StarDeskDeviceId { get; set; } = "";
    public DateTimeOffset? LastStarDeskSyncUtc { get; set; }
}

public static class AgentStorage
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("AniGamesReady-StarDesk-Agent-v1");
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    public static string RootDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "AniGamesReady", "StarDeskAgent");
    private static string PrivateDirectory => Path.Combine(RootDirectory, "private");
    private static string ConfigPath => Path.Combine(PrivateDirectory, "agent.json");
    public static string StatusPath => Path.Combine(RootDirectory, "status.json");

    public static AgentConfig LoadOrCreate()
    {
        Directory.CreateDirectory(PrivateDirectory);
        if (File.Exists(ConfigPath))
        {
            try
            {
                var stored = JsonSerializer.Deserialize<StoredAgentConfig>(File.ReadAllText(ConfigPath))
                    ?? throw new InvalidDataException("AGENT_CONFIG_EMPTY");
                var encrypted = Convert.FromBase64String(stored.ProtectedToken);
                var token = Encoding.UTF8.GetString(ProtectedData.Unprotect(
                    encrypted, Entropy, DataProtectionScope.CurrentUser));
                if (string.IsNullOrWhiteSpace(stored.AgentDeviceId) ||
                    string.IsNullOrWhiteSpace(token) ||
                    Hash(token) != stored.AgentTokenHash)
                    throw new InvalidDataException("AGENT_CONFIG_INVALID");
                return new AgentConfig
                {
                    AgentDeviceId = stored.AgentDeviceId,
                    AgentToken = token,
                    AgentTokenHash = stored.AgentTokenHash,
                    PairCode = stored.PairCode,
                    PairCodeHash = stored.PairCodeHash,
                    IsPaired = stored.IsPaired
                };
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException(
                    "Credential Agent tidak dapat dibuka oleh akun service Windows. Jangan hapus file private/agent.json; periksa akun service atau lakukan pemulihan Agent.",
                    ex);
            }
        }

        var rawToken = Base64Url(RandomNumberGenerator.GetBytes(32));
        var pairCode = RandomNumberGenerator.GetInt32(0, 100_000_000).ToString("D8");
        var config = new AgentConfig
        {
            AgentDeviceId = Guid.NewGuid().ToString("D"),
            AgentToken = rawToken,
            AgentTokenHash = Hash(rawToken),
            PairCode = pairCode,
            PairCodeHash = Hash(pairCode),
            IsPaired = false
        };
        Save(config);
        return config;
    }

    public static void Save(AgentConfig config)
    {
        Directory.CreateDirectory(PrivateDirectory);
        var protectedToken = ProtectedData.Protect(
            Encoding.UTF8.GetBytes(config.AgentToken), Entropy, DataProtectionScope.CurrentUser);
        var stored = new StoredAgentConfig
        {
            AgentDeviceId = config.AgentDeviceId,
            ProtectedToken = Convert.ToBase64String(protectedToken),
            AgentTokenHash = config.AgentTokenHash,
            PairCode = config.IsPaired ? "" : config.PairCode,
            PairCodeHash = config.IsPaired ? "" : config.PairCodeHash,
            IsPaired = config.IsPaired
        };
        var temp = ConfigPath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(stored, JsonOptions));
        File.Move(temp, ConfigPath, true);
    }

    public static void WriteStatus(AgentStatus status)
    {
        Directory.CreateDirectory(RootDirectory);
        var temp = StatusPath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(status, JsonOptions));
        File.Move(temp, StatusPath, true);
    }

    public static AgentStatus? ReadStatus()
    {
        try
        {
            if (!File.Exists(StatusPath)) return null;
            return JsonSerializer.Deserialize<AgentStatus>(File.ReadAllText(StatusPath));
        }
        catch
        {
            return null;
        }
    }

    public static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    private static string Base64Url(byte[] value) =>
        Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}

public sealed class AgentApiClient
{
    private const string RpcBase =
        "https://ani-games-db-android-stage-gateway.anigamesready.workers.dev/stardesk/rest/v1/rpc/";
    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        AutomaticDecompression = System.Net.DecompressionMethods.GZip | System.Net.DecompressionMethods.Deflate,
        ConnectTimeout = TimeSpan.FromSeconds(10),
        PooledConnectionLifetime = TimeSpan.FromMinutes(5)
    })
    {
        Timeout = TimeSpan.FromSeconds(20)
    };

    public async Task<JsonElement> RpcAsync(
        string name, object payload, string? bearerToken, CancellationToken cancellationToken)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(name, "^[a-z0-9_]{1,80}$"))
            throw new ArgumentException("RPC_NAME_INVALID", nameof(name));

        using var request = new HttpRequestMessage(HttpMethod.Post, RpcBase + name);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (!string.IsNullOrWhiteSpace(bearerToken))
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
        request.Content = new StringContent(
            JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");

        using var response = await Client.SendAsync(
            request, HttpCompletionOption.ResponseContentRead, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        JsonDocument document;
        try { document = JsonDocument.Parse(string.IsNullOrWhiteSpace(body) ? "{}" : body); }
        catch (JsonException ex) { throw new InvalidOperationException("GATEWAY_INVALID_JSON", ex); }

        using (document)
        {
            var root = document.RootElement.Clone();
            var message = ReadString(root, "message") ?? ReadString(root, "error");
            if (!response.IsSuccessStatusCode ||
                (root.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.False))
                throw new AgentApiException(message ?? $"HTTP_{(int)response.StatusCode}");
            return root;
        }
    }

    public static string? ReadString(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    public static bool ReadBoolean(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(name, out var value) &&
        (value.ValueKind == JsonValueKind.True ||
         (value.ValueKind == JsonValueKind.String && bool.TryParse(value.GetString(), out var parsed) && parsed));
}

public sealed class AgentApiException : Exception
{
    public AgentApiException(string message) : base(message) { }
}
