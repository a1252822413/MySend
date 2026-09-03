// SendClient：LocalSend v2.2 发送端 HTTP 客户端。
// 对应 localsend-main/packages/core/src/http/client/v2.rs 的 register / prepare_upload / upload / cancel。
using System.Net;
using System.Net.Http;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using PcDemo.Helpers;
using PcDemo.Models;
using PcDemo.Models.Dto;
using PcDemo.Services;

namespace PcDemo.Networking;

/// <summary>prepare-upload 返回的结果（200 带 session 或 204 空内容）。</summary>
public record PrepareSendResult(
    ushort StatusCode,
    PrepareUploadResponseDtoV2? Response);

/// <summary>发送端调用异常（含状态码消息或网络错误）。</summary>
public class SendClientException : Exception
{
    public SendClientException(string message) : base(message) { }
    public SendClientException(string message, Exception inner) : base(message, inner) { }
    public ushort? StatusCode { get; init; }
}

/// <summary>prepare-upload 被对方拒绝（403）。</summary>
public class SendRejectedException : SendClientException
{
    public SendRejectedException(string message) : base(message) { StatusCode = 403; }
}

/// <summary>prepare-upload 被对方阻塞（409，对方正在处理别的会话）。</summary>
public class SendBlockedException : SendClientException
{
    public SendBlockedException(string message) : base(message) { StatusCode = 409; }
}

/// <summary>用户取消（CancellationToken 触发）。</summary>
public class SendCancelledException : SendClientException
{
    public SendCancelledException() : base("Cancelled by user") { }
}

/// <summary>协议探测结果：最终应使用的 scheme + port。</summary>
/// <param name="Scheme">"http" 或 "https"</param>
/// <param name="Port">最终端口</param>
/// <param name="Alias">对方别名（可选，从 /info 回显）</param>
public record ProtocolInfo(string Scheme, ushort Port, string? Alias = null);

public class SendClient
{
    private const string ProtocolVersion = "2.2";
    private readonly HttpClient _http;
    private readonly ISettingsService _settings;

    public SendClient(HttpClient http, ISettingsService settings)
    {
        _http = http;
        _settings = settings;
    }

    private static string BaseUrl(string scheme, string ip, int port, string path)
        => $"{scheme}://{ip}:{port}/api/localsend/v2{path}";

    // ----- 协议探测 -----
    private const int DetectTimeoutMs = 2500;

    // ----- 短请求超时（upload 不设短超时，走 HttpClient 全局 30 分钟）-----
    private const int CancelTimeoutMs = 10_000;
    // prepare-upload 对方要等其用户决策（我方接收端决策窗口 60s），超时须覆盖该窗口
    private const int PrepareUploadTimeoutMs = 75_000;

    /// <summary>
    /// 探测对方协议。对方可能 HTTPS-only、或端口 53318(HTTPS)/53317(HTTP) 不一致。
    /// 优先使用 Device.Protocol/Port 声明的方案，失败再 fallback 到常见组合：
    /// https:53318 → https:53317 → http:53318 → http:53317 → 对方声明相反协议。
    /// 3s 内 /info 成功的那个就是对的。
    /// </summary>
    public async Task<ProtocolInfo> DetectProtocolAsync(Device target, CancellationToken ct = default)
    {
        var candidates = BuildCandidateList(target);
        // 并发 2 路探测：声明方案优先，常见 fallback 并行。
        // 串行最坏: N × 2.5s；并发 2 路 + WhenAny 成功立刻返回 + cancel 其余:
        //   - 第一个声明就成功: ~50ms
        //   - 对方完全离线: ~⌈N/2⌉ × 2.5s ≈ 约一半串行
        var tries = new string[candidates.Count];
        Exception? lastEx = null;

        using var concurrencySemaphore = new SemaphoreSlim(2, 2);
        using var cts = ct.CanBeCanceled
            ? CancellationTokenSource.CreateLinkedTokenSource(ct)
            : new CancellationTokenSource();
        var probeCt = cts.Token;

        // 每个 candidate 的探测任务（带索引、元组返回）
        var probeTasks = new List<Task<(int idx, ProtocolInfo? ok, Exception? ex)>>(capacity: candidates.Count);
        for (int i = 0; i < candidates.Count; i++)
        {
            int idx = i;
            var (scheme, port) = candidates[idx];
            probeTasks.Add(Task.Run(async () =>
            {
                await concurrencySemaphore.WaitAsync(probeCt);
                try
                {
                    return await ProbeOne(idx, target, scheme, port, probeCt);
                }
                finally
                {
                    concurrencySemaphore.Release();
                }
            }, probeCt));
        }

        ProtocolInfo? winner = null;
        var pending = new HashSet<Task<(int idx, ProtocolInfo? ok, Exception? ex)>>(probeTasks);

        // WhenAny：有任务成功立刻返回；否则全部跑完后抛错
        while (pending.Count > 0)
        {
            var completed = await Task.WhenAny(pending);
            pending.Remove(completed);
            var (idx, ok, ex) = await completed;

            // 按声明顺序记录日志
            var (s, p) = candidates[idx];
            tries[idx] = LogLineForResult(s, target.Ip, p, ok, ex);
            if (ex is not null) lastEx = ex;

            if (ok is not null)
            {
                winner = ok;
                cts.Cancel(); // 立刻 cancel 其他还在等的探测
                break;
            }
        }

        // 等被 cancel 的任务收尾（避免 Semaphore/Task 泄漏），注意不能抛
        try
        {
            await Task.WhenAll(probeTasks);
        }
        catch { /* 被 cts.Cancel() 的探测任务会抛 OperationCanceledException，忽略 */ }

        if (winner is not null) return winner;

        // 全部失败，整理按 candidate 顺序的 tries 列表（跳过未探测到的条目——被 cancel 了）
        var triesDisplay = new List<string>();
        for (int i = 0; i < candidates.Count; i++)
        {
            if (tries[i] is not null) triesDisplay.Add(tries[i]);
        }
        var msg = $"无法连接到设备 {target.Alias ?? target.Ip}："
                  + Environment.NewLine + "尝试了："
                  + Environment.NewLine + "  • " + string.Join(Environment.NewLine + "  • ", triesDisplay)
                  + Environment.NewLine + "提示："
                  + Environment.NewLine + "  1. 请确认对方设备（手机）上 LocalSend App 已**前台打开**（HTTPS-only 模式下 App 前台才会启动监听）。"
                  + Environment.NewLine + "  2. 请确认两台设备处于同一 Wi-Fi 局域网。"
                  + Environment.NewLine + "  3. 若手机端关闭了 HTTPS-only（设置 → 网络 → 高级 → HTTPS-only 关闭），也能正常互通。";
        throw new SendClientException(msg, lastEx ?? new SendClientException("(无底层异常)"));

        async Task<(int idx, ProtocolInfo? ok, Exception? ex)> ProbeOne(
            int i, Device t, string scheme, int port, CancellationToken pc)
        {
            var desc = $"{scheme}://{t.Ip}:{port}";
            try
            {
                using var singleCts = pc.CanBeCanceled
                    ? CancellationTokenSource.CreateLinkedTokenSource(pc)
                    : new CancellationTokenSource();
                singleCts.CancelAfter(DetectTimeoutMs);
                var uri = BuildUri(BaseUrl(scheme, t.Ip, port, "/info"), null);
                using var req = new HttpRequestMessage(HttpMethod.Get, uri);
                using var res = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, singleCts.Token);
                if (!res.IsSuccessStatusCode)
                {
                    return (i, null, null);
                }
                var body = await res.Content.ReadAsByteArrayAsync(singleCts.Token);
                var info = JsonSerializer.Deserialize(body, typeof(InfoResponseDtoV2), JsonOptions.Default) as InfoResponseDtoV2;
                App.LogDiag($"[Send] 协议探测成功：{desc} (alias={info?.Alias}, httpsOnly={info?.HttpsOnly}, port={info?.Port})");
                var finalScheme = scheme;
                var finalPort = (ushort)port;
                if (info is not null)
                {
                    if (info.HttpsOnly && finalScheme == "http") finalScheme = "https";
                    if (info.Port != 0) finalPort = checked((ushort)info.Port);
                }
                return (i, new ProtocolInfo(finalScheme, finalPort, info?.Alias), null);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                return (i, null, null); // 超时或 WhenAny 胜出后的 cancel，不算异常
            }
            catch (Exception ex)
            {
                return (i, null, ex);
            }
        }

        string LogLineForResult(string s, string ip, int p, ProtocolInfo? ok, Exception? ex)
        {
            var desc = $"{s}://{ip}:{p}";
            if (ok is not null) return $"{desc} -> OK";
            if (ex is null) return $"{desc} -> 超时/HTTP错误";
            return $"{desc} -> {DescribeException(ex)}";
        }
    }

    private static List<(string scheme, int port)> BuildCandidateList(Device target)
    {
        var result = new List<(string, int)>(capacity: 8);
        var declaredPort = target.Port != 0 ? target.Port : 53317;
        void Add((string s, int p) v) { if (!result.Contains(v)) result.Add(v); }

        // 1. 对方公告声明的协议+端口（官方语义精确：HTTPS-only 时就在同一端口跑 HTTPS，不是 +1）
        switch (target.Protocol)
        {
            case ProtocolType.Https: Add(("https", declaredPort)); break;
            default: Add(("http", declaredPort)); break;
        }

        // 2. 常见组合兜底
        Add(("https", 53317));
        Add(("https", 53318));
        Add(("http", 53317));
        Add(("http", 53318));
        Add(("https", declaredPort + 1));
        Add(("https", declaredPort - 1));

        // 3. 对方声明相反协议时兜底
        if (target.Protocol == ProtocolType.Https) Add(("http", declaredPort));
        else Add(("https", declaredPort));

        return result;
    }

    private RegisterDtoV2 BuildSelfRegisterDto()
    {
        var s = _settings.Current;
        return new RegisterDtoV2
        {
            Alias = s.Alias,
            Version = ProtocolVersion,
            DeviceModel = s.DeviceModel,
            DeviceType = s.DeviceType,
            Fingerprint = s.Fingerprint,
            Port = s.Port,
            Protocol = ProtocolType.Http,
            Download = s.Download,
        };
    }

    /// <summary>POST /prepare-upload。返回 200 带 sessionId+tokens，或 204 空。</summary>
    public async Task<PrepareSendResult> PrepareUploadAsync(
        string scheme, string ip, int port,
        IReadOnlyList<SendFileItem> files,
        string? pin = null,
        CancellationToken ct = default)
    {
        var payload = new PrepareUploadRequestDtoV2
        {
            Info = BuildSelfRegisterDto(),
            Files = files.ToDictionary(f => f.Id, f => f.ToDto()),
        };
        var qs = pin is not null ? new Dictionary<string, string> { ["pin"] = pin } : null;
        using var req = new HttpRequestMessage(HttpMethod.Post, BuildUri(BaseUrl(scheme, ip, port, "/prepare-upload"), qs));
        req.Content = new StringContent(
            JsonSerializer.Serialize(payload, JsonOptions.Default),
            Encoding.UTF8, "application/json");

        HttpResponseMessage res;
        var usedScheme = scheme;
        try
        {
            res = await SendAsync(req, ct, PrepareUploadTimeoutMs);
        }
        catch (OperationCanceledException)
        {
            _ = Task.Run(async () =>
            {
                try { await CancelAsync(usedScheme, ip, port, "none", CancellationToken.None); } catch { }
            }, CancellationToken.None);
            throw new SendCancelledException();
        }

        if (res.StatusCode == HttpStatusCode.NoContent)
            return new PrepareSendResult(204, null);

        if (!res.IsSuccessStatusCode)
        {
            var code = (ushort)res.StatusCode;
            var msg = await ReadErrorBody(res, ct);
            throw code switch
            {
                401 => new SendClientException($"PIN required: {msg}") { StatusCode = code },
                403 => new SendRejectedException($"Declined by receiver: {msg}"),
                409 => new SendBlockedException($"Blocked by another session: {msg}"),
                429 => new SendClientException($"Too many requests: {msg}") { StatusCode = code },
                _ => new SendClientException($"prepare-upload HTTP {code}: {msg}") { StatusCode = code },
            };
        }
        var body = await res.Content.ReadAsByteArrayAsync(ct);
        var resp = JsonSerializer.Deserialize(body, typeof(PrepareUploadResponseDtoV2), JsonOptions.Default)
            as PrepareUploadResponseDtoV2
            ?? throw new SendClientException("Empty prepare-upload response");
        return new PrepareSendResult(200, resp);
    }

    /// <summary>POST /upload（流式 + 进度回调）。</summary>
    public async Task UploadAsync(string scheme, string ip, int port,
        string sessionId, string fileId, string token,
        string localPath, long expectedSize,
        Action<long> onProgressBytes,
        CancellationToken ct = default)
    {
        var uri = BuildUri(BaseUrl(scheme, ip, port, "/upload"), new Dictionary<string, string>
        {
            ["sessionId"] = sessionId,
            ["fileId"] = fileId,
            ["token"] = token,
        });

        await using var fs = new FileStream(localPath, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, true);
        using var content = new ProgressStreamContent(fs, expectedSize, onProgressBytes);
        using var req = new HttpRequestMessage(HttpMethod.Post, uri) { Content = content };

        HttpResponseMessage res;
        try
        {
            res = await SendAsync(req, ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw new SendCancelledException();
        }
        catch (OperationCanceledException)
        {
            // 30 分钟全局超时（对端无响应/连接挂死）→ 按失败处理而非"用户取消"
            throw new SendClientException("上传超时：对方设备长时间无响应");
        }
        if (!res.IsSuccessStatusCode)
        {
            var code = (ushort)res.StatusCode;
            var msg = await ReadErrorBody(res, ct);
            throw code switch
            {
                403 => new SendClientException($"Invalid token or IP address: {msg}") { StatusCode = code },
                409 => new SendBlockedException($"Blocked by another session: {msg}"),
                422 => new SendClientException($"Checksum mismatch: {msg}") { StatusCode = code },
                _ => new SendClientException($"upload HTTP {code}: {msg}") { StatusCode = code },
            };
        }
    }

    /// <summary>POST /cancel（不抛异常，best-effort）。</summary>
    public async Task CancelAsync(string scheme, string ip, int port, string sessionId, CancellationToken ct = default)
    {
        try
        {
            var uri = BuildUri(BaseUrl(scheme, ip, port, "/cancel"),
                new Dictionary<string, string> { ["sessionId"] = sessionId });
            using var req = new HttpRequestMessage(HttpMethod.Post, uri);
            using var res = await SendAsync(req, ct, CancelTimeoutMs);
        }
        catch (SendCancelledException) { throw; }
        catch
        {
            // best-effort
        }
    }

    // ---------- ProtocolInfo 便捷重载 ----------
    public Task<PrepareSendResult> PrepareUploadAsync(ProtocolInfo proto, string ip,
        IReadOnlyList<SendFileItem> files, string? pin = null, CancellationToken ct = default)
        => PrepareUploadAsync(proto.Scheme, ip, proto.Port, files, pin, ct);

    public Task UploadAsync(ProtocolInfo proto, string ip,
        string sessionId, string fileId, string token, string localPath, long expectedSize,
        Action<long> onProgressBytes, CancellationToken ct = default)
        => UploadAsync(proto.Scheme, ip, proto.Port, sessionId, fileId, token, localPath, expectedSize, onProgressBytes, ct);

    public Task CancelAsync(ProtocolInfo proto, string ip, string sessionId, CancellationToken ct = default)
        => CancelAsync(proto.Scheme, ip, proto.Port, sessionId, ct);

    // ---------- helpers ----------
    /// <summary>发送请求；timeoutMs 非空时施加单请求超时（超时转为 SendClientException，与用户取消区分）。</summary>
    private async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct, int? timeoutMs = null)
    {
        try
        {
            if (timeoutMs is not null)
            {
                using var cts = ct.CanBeCanceled
                    ? CancellationTokenSource.CreateLinkedTokenSource(ct)
                    : new CancellationTokenSource();
                cts.CancelAfter(timeoutMs.Value);
                try
                {
                    return await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, cts.Token);
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                {
                    throw new SendClientException($"请求超时（{timeoutMs.Value / 1000}s）：对方设备可能已离线或无响应");
                }
            }
            return await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct);
        }
        catch (HttpRequestException ex)
        {
            throw new SendClientException($"Network error: {DescribeException(ex)}", ex);
        }
    }

    /// <summary>展开异常的完整 InnerException 链（外层 HttpRequestException 常吞掉真实原因）。</summary>
    private static string DescribeException(Exception ex)
    {
        var parts = new List<string>();
        var cur = ex;
        for (var i = 0; cur is not null && i < 6; i++)
        {
            parts.Add($"{cur.GetType().Name}: {cur.Message}");
            cur = cur.InnerException!;
        }
        return string.Join(" <--- ", parts);
    }

    private static async Task<string> ReadErrorBody(HttpResponseMessage res, CancellationToken ct)
    {
        try { return (await res.Content.ReadAsStringAsync(ct)).Trim(); }
        catch { return string.Empty; }
    }

    private static Uri BuildUri(string baseUri, Dictionary<string, string>? query)
    {
        if (query is null || query.Count == 0) return new Uri(baseUri);
        var qb = new StringBuilder();
        var first = true;
        foreach (var (k, v) in query)
        {
            if (!first) qb.Append('&');
            first = false;
            qb.Append(Uri.EscapeDataString(k)).Append('=').Append(Uri.EscapeDataString(v));
        }
        return new Uri($"{baseUri}?{qb}");
    }
}

/// <summary>为 upload 提供带进度回调的 StreamContent。</summary>
internal sealed class ProgressStreamContent : HttpContent
{
    private readonly Stream _stream;
    private readonly long _expectedSize;
    private readonly Action<long> _onProgress;

    public ProgressStreamContent(Stream stream, long expectedSize, Action<long> onProgress)
    {
        _stream = stream;
        _expectedSize = expectedSize;
        _onProgress = onProgress;
        Headers.ContentLength = expectedSize;
    }

    protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context)
        => SerializeToStreamAsync(stream);

    private async Task SerializeToStreamAsync(Stream stream)
    {
        var buffer = System.Buffers.ArrayPool<byte>.Shared.Rent(64 * 1024);
        try
        {
            long sent = 0;
            while (true)
            {
                var read = await _stream.ReadAsync(buffer.AsMemory(0, buffer.Length));
                if (read <= 0) break;
                await stream.WriteAsync(buffer.AsMemory(0, read));
                sent += read;
                _onProgress(sent);
            }
        }
        finally
        {
            System.Buffers.ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    protected override bool TryComputeLength(out long length)
    {
        length = _expectedSize;
        return true;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _stream.Dispose();
        base.Dispose(disposing);
    }
}

/// <summary>静态共享 HttpClient（避免频繁创建 SocketsHttpHandler）。支持 HTTPS 自签名证书（官方 LocalSend 对自签名证书 trust-any-cert）。</summary>
internal static class StaticHttpClient
{
    public static readonly HttpClient Instance = Build();

    private static HttpClient Build()
    {
        var handler = new SocketsHttpHandler
        {
            PooledConnectionLifetime = TimeSpan.FromMinutes(10),
            AllowAutoRedirect = false,
            UseCookies = false,
        };
        // 1) 信任对方自签名服务器证书（官方 LocalSend 服务器证书 CA 不被系统信任）。
        // 2) 必须出示 mTLS 客户端证书：官方 HTTPS-only 下服务端强制要求客户端证书，
        //    否则 TLS 握手被直接断连（表现为 "An error occurred while sending the request"）。
        var clientCert = ClientIdentity.GetOrCreate();
        handler.SslOptions = new System.Net.Security.SslClientAuthenticationOptions
        {
            RemoteCertificateValidationCallback = (_, _, _, _) => true,
            ClientCertificates = clientCert is null ? null : new X509CertificateCollection { clientCert },
            LocalCertificateSelectionCallback = clientCert is null
                ? null
                : (_, _, _, _, _) => clientCert,
        };
        return new HttpClient(handler) { Timeout = TimeSpan.FromMinutes(30) };
    }
}
