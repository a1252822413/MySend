// 接收会话状态机：实现单槽约束、异步等待 UI 决策、upload 校验、cancel 取消。
// 对应 packages/core/src/http/server/v2.rs 的 prepare-upload/upload/cancel 行为。
using CommunityToolkit.Mvvm.Messaging;
using Microsoft.UI.Dispatching;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.Models.Dto;

namespace PcDemo.Services;

public sealed class ReceiveSessionManager : IReceiveSessionManager, IDisposable
{
    private const int PendingDecisionTimeoutSeconds = 60;

    private readonly ISettingsService _settings;
    private readonly IMessenger _messenger;
    private readonly IFileSaver _fileSaver;
    private readonly DispatcherQueue _dispatcher;
    private readonly object _lock = new();
    private ReceiveSession? _current;
    private readonly Dictionary<string, TaskCompletionSource<PrepareUploadDecision>> _pendingDecisions = new();
    private readonly Timer _cleanupTimer;

    public ReceiveSession? CurrentSession
    {
        get { lock (_lock) return _current; }
    }

    public ReceiveSessionManager(ISettingsService settings, IMessenger messenger, IFileSaver fileSaver,
        DispatcherQueue dispatcher)
    {
        _settings = settings;
        _messenger = messenger;
        _fileSaver = fileSaver;
        _dispatcher = dispatcher;
        _cleanupTimer = new Timer(_ => CleanupStale(), null,
            TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(15));
    }

    public async Task<PrepareUploadResult> HandlePrepareUploadAsync(string senderIp, PrepareUploadRequestDtoV2 request)
    {
        TaskCompletionSource<PrepareUploadDecision> tcs;
        ReceiveSession session;

        // IP 归一化：IPv4-mapped IPv6 与纯 IPv4 文本在双栈下不一致会误拒后续 upload
        senderIp = NormalizeIp(senderIp);

        lock (_lock)
        {
            // 单槽：当前会话仍占用（待决策/已接受/接收中）→ 409
            if (_current is not null && IsOccupied(_current))
            {
                // 切回 UI 线程提示本机用户（避免“第二台设备被静默拒绝”）
                var busyAlias = _current.Sender?.Alias ?? "其他设备";
                var requesterAlias = request.Info?.Alias ?? "未知设备";
                _dispatcher.TryEnqueue(() => _messenger.Send(new ShowToastMessage
                {
                    Kind = ToastKind.Warning,
                    Message = $"「{requesterAlias}」尝试发送文件，但您正与「{busyAlias}」传输中，已拒绝（请让对方稍后重试）",
                    DurationMs = 2600,
                }));
                App.LogDiag($"[SessionMgr] 单槽忙，409：busy={busyAlias} requester={requesterAlias}");
                return new PrepareUploadResult { StatusCode = 409, ErrorMessage = "Blocked by another session" };
            }
            var sessionId = Guid.NewGuid().ToString("N");
            tcs = new TaskCompletionSource<PrepareUploadDecision>(TaskCreationOptions.RunContinuationsAsynchronously);
            _pendingDecisions[sessionId] = tcs;

            session = new ReceiveSession
            {
                SessionId = sessionId,
                SenderIp = senderIp,
                Sender = request.Info,
                // 固化保存目录快照：传输中改"保存目录"设置不应影响本会话（避免文件落散到不同目录）
                DestinationDir = _settings.Current.Destination,
                Status = ReceiveSessionStatus.PendingDecision,
                Files = request.Files.ToDictionary(
                    kv => kv.Key,
                    kv => new ReceiveFile
                    {
                        FileId = kv.Key,
                        Token = Guid.NewGuid().ToString("N"),
                        Metadata = kv.Value,
                    }),
            };
            _current = session;
        }

        _messenger.Send(new PrepareUploadRequestedMessage { Session = session });
        App.LogDiag($"[SessionMgr] prepare-upload 入站 senderIp={senderIp} sessionId={session.SessionId[..8]} 文件数={session.Files.Count}，等待 UI 决策...");

        PrepareUploadDecision decision;
        try
        {
            decision = await tcs.Task;
        }
        catch (OperationCanceledException)
        {
            // 发送方在等待期取消 → 协议要求 403 "Cancelled by sender"
            lock (_lock)
            {
                _pendingDecisions.Remove(session.SessionId);
                if (_current == session) _current = null;
            }
            return new PrepareUploadResult { StatusCode = 403, ErrorMessage = "Cancelled by sender" };
        }

        lock (_lock)
        {
            _pendingDecisions.Remove(session.SessionId);

            if (!decision.Accepted)
            {
                session.Status = ReceiveSessionStatus.Rejected;
                if (_current == session) _current = null;
                _messenger.Send(new SessionFinishedMessage { Session = session });
                return new PrepareUploadResult { StatusCode = 403, ErrorMessage = "Rejected" };
            }

            // 全不选 = 拒绝（等价 Decline）：UI 端已把空集合转为 Decline，这里兜底，
            // 避免此前把空集合记成 Completed → 历史写入 0 字节"成功"会话
            if (decision.AcceptedFileIds.Count == 0)
            {
                session.Status = ReceiveSessionStatus.Rejected;
                if (_current == session) _current = null;
                _messenger.Send(new SessionFinishedMessage { Session = session });
                return new PrepareUploadResult { StatusCode = 403, ErrorMessage = "Rejected" };
            }

            session.Status = ReceiveSessionStatus.Accepted;
            session.LastActivityUtc = DateTime.UtcNow;
            var acceptedSet = decision.AcceptedFileIds.ToHashSet();
            var toRemove = session.Files.Keys.Where(k => !acceptedSet.Contains(k)).ToList();
            foreach (var k in toRemove) session.Files.Remove(k);

            var resp = new PrepareUploadResponseDtoV2
            {
                SessionId = session.SessionId,
                Files = session.Files.ToDictionary(kv => kv.Key, kv => kv.Value.Token),
            };
            return new PrepareUploadResult { StatusCode = 200, Response = resp };
        }
    }

    public void Accept(string sessionId, IEnumerable<string> acceptedFileIds)
    {
        TaskCompletionSource<PrepareUploadDecision>? tcs;
        lock (_lock) _pendingDecisions.TryGetValue(sessionId, out tcs);
        if (tcs is null) return;
        tcs.TrySetResult(new PrepareUploadDecision
        {
            Accepted = true,
            AcceptedFileIds = acceptedFileIds.ToList(),
        });
    }

    public void Decline(string sessionId)
    {
        TaskCompletionSource<PrepareUploadDecision>? tcs;
        lock (_lock) _pendingDecisions.TryGetValue(sessionId, out tcs);
        if (tcs is null) return;
        tcs.TrySetResult(new PrepareUploadDecision { Accepted = false });
    }

    public async Task<UploadResult> HandleUploadAsync(string sessionId, string fileId, string token, string senderIp, Stream body,
        Microsoft.AspNetCore.Http.HttpContext? httpCtx = null)
    {
        ReceiveSession? session;
        lock (_lock) session = _current;

        // IP 归一化后再比较：双栈下同一连接的 RemoteIpAddress 可能是 IPv4-mapped IPv6
        senderIp = NormalizeIp(senderIp);

        // 校验：会话存在 + sessionId 匹配 + IP 匹配 + fileId 在会话 + token 匹配 + 文件处于 Pending
        if (session is null
            || session.SessionId != sessionId
            || !string.Equals(session.SenderIp, senderIp, StringComparison.Ordinal)
            || !session.Files.TryGetValue(fileId, out var file)
            || !string.Equals(file.Token, token, StringComparison.Ordinal)
            || file.Status != ReceiveFileStatus.Pending)
        {
            App.LogDiag($"[SessionMgr] upload 校验失败：session={(session is null ? "null" : session.SessionId[..8])} fileId={fileId}");
            return new UploadResult { StatusCode = 403, ErrorMessage = "Invalid token or IP address" };
        }

        lock (_lock)
        {
            session.Status = ReceiveSessionStatus.InProgress;
            file.Status = ReceiveFileStatus.InProgress;
            session.HttpContext = httpCtx;
            session.LastActivityUtc = DateTime.UtcNow;
        }

        // 进度初始化（首次或每个文件开始时刷新）
        var p = session.Progress;
        var totalBytes = session.Files.Values.Sum(f => (long)f.Metadata.Size);
        var completedBefore = session.Files.Values
            .Where(f => f.Status == ReceiveFileStatus.Completed)
            .Sum(f => (long)f.Metadata.Size);
        _dispatcher.TryEnqueue(() =>
        {
            p.TotalFiles = session.Files.Count;
            p.TotalBytes = totalBytes;
            p.IsIndeterminate = false;
            p.PhaseText = $"正在接收 {file.Metadata.FileName}";
        });

        var calc = new SpeedCalculator();
        var progress = new Progress<long>(bytes =>
        {
            var (speed, eta) = calc.Sample(completedBefore + bytes, totalBytes);
            _dispatcher.TryEnqueue(() =>
            {
                p.ReceivedBytes = completedBefore + bytes;
                p.SpeedBytesPerSecond = speed;
                p.EtaSeconds = eta;
            });
        });

        App.LogDiag($"[SessionMgr] 开始写盘：{file.Metadata.FileName}（{file.Metadata.Size} bytes）到 {session.DestinationDir}");
        try
        {
            var path = await _fileSaver.SaveAsync(session.DestinationDir, file.Metadata.FileName, body,
                progress, session.Cts.Token, file.Metadata.Sha256);
            lock (_lock)
            {
                file.Status = ReceiveFileStatus.Completed;
                file.SavedPath = path;
            }
            App.LogDiag($"[SessionMgr] 写盘成功：{path}");

            _dispatcher.TryEnqueue(() =>
            {
                p.CompletedFiles = session.Files.Values.Count(f => f.Status == ReceiveFileStatus.Completed);
                p.PhaseText = "等待下一个文件…";
                p.IsIndeterminate = true;
            });

            MaybeFinalize(session, p);
            return new UploadResult { StatusCode = 200 };
        }
        catch (OperationCanceledException)
        {
            // 本机用户取消（CancelLocal 已把状态/事件处理完，这里只回 499；连接已被 Abort）
            App.LogDiag("[SessionMgr] 接收被本机用户取消");
            return new UploadResult { StatusCode = 499, ErrorMessage = "Cancelled by receiver" };
        }
        catch (Exception ex) when (session.Cts.IsCancellationRequested)
        {
            // 对方连接被 Abort 导致的 IOException 也视为本机取消
            App.LogDiag($"[SessionMgr] 接收被本机用户取消（{ex.GetType().Name}）");
            return new UploadResult { StatusCode = 499, ErrorMessage = "Cancelled by receiver" };
        }
        catch (ChecksumMismatchException ex)
        {
            // SHA-256 校验失败（协议 422）：仅标记该文件失败，继续接收其余文件
            App.LogDiag($"[SessionMgr] {ex.Message}");
            lock (_lock)
            {
                file.Status = ReceiveFileStatus.Failed;
                file.Error = "SHA-256 校验失败";
            }
            MaybeFinalize(session, p);
            return new UploadResult { StatusCode = 422, ErrorMessage = "Checksum mismatch" };
        }
        catch (UnsafeFileNameException ex)
        {
            // 文件名不安全：拒绝该文件，继续接收其余文件
            App.LogDiag($"[SessionMgr] 拒绝不安全文件名：{ex.FileName}");
            lock (_lock)
            {
                file.Status = ReceiveFileStatus.Failed;
                file.Error = $"文件名不安全（已拒绝）：{ex.FileName}";
            }
            MaybeFinalize(session, p);
            return new UploadResult { StatusCode = 403, ErrorMessage = "Unsafe file name" };
        }
        catch (Exception ex)
        {
            // 写盘失败：仅标记该文件失败，其余文件继续接收（坏文件不再中断整批）
            App.LogDiag($"[SessionMgr] 写盘失败（跳过该文件）：{ex.GetType().Name}: {ex.Message}{(ex.InnerException is null ? "" : $" | inner: {ex.InnerException.Message}")}");
            lock (_lock)
            {
                file.Status = ReceiveFileStatus.Failed;
                file.Error = ex.Message;
            }
            MaybeFinalize(session, p);
            return new UploadResult { StatusCode = 500, ErrorMessage = "Failed to save file" };
        }
    }

    /// <summary>
    /// 所有文件都终结（成功/失败/取消）时收尾会话：决定最终状态（有成功=Completed，否则 Failed），
    /// 释放槽位、发完成摘要 toast 与 SessionFinished。非终结（还有文件未传）时直接返回不动作。
    /// </summary>
    private void MaybeFinalize(ReceiveSession session, ReceiveProgress p)
    {
        bool terminal;
        int ok, failed;
        lock (_lock)
        {
            ok = session.Files.Values.Count(f => f.Status == ReceiveFileStatus.Completed);
            failed = session.Files.Values.Count(f => f.Status == ReceiveFileStatus.Failed);
            terminal = session.Files.Values.All(f => f.Status is ReceiveFileStatus.Completed
                or ReceiveFileStatus.Failed or ReceiveFileStatus.Canceled);
            if (!terminal) return;
            session.Status = ok > 0 ? ReceiveSessionStatus.Completed : ReceiveSessionStatus.Failed;
            if (_current == session) _current = null;
        }

        App.LogDiag($"[SessionMgr] 会话收尾：成功 {ok}，失败 {failed}，总计 {session.Files.Count}");
        _dispatcher.TryEnqueue(() =>
        {
            p.CompletedFiles = ok;
            p.IsIndeterminate = false;
            if (ok > 0)
            {
                p.IsCompleted = true;
                p.PhaseText = failed > 0 ? "接收完成（部分失败）" : "接收完成";
            }
            else
            {
                p.IsCompleted = false;
                p.PhaseText = "接收失败";
            }
        });

        // 窗口隐藏在托盘时提醒用户（前台可见时静默）
        if (ok > 0)
        {
            App.ShowTransferToast(failed > 0 ? "接收完成（部分失败）" : "接收完成",
                $"{ok}/{session.Files.Count} 个文件已保存到 {session.DestinationDir}{(failed > 0 ? $"，{failed} 个失败" : "")}");
        }
        else
        {
            App.ShowTransferToast("接收失败", $"{failed} 个文件均接收失败");
        }
        _messenger.Send(new SessionFinishedMessage { Session = session });
    }

    public void Cancel(string sessionId, string senderIp)
    {
        TaskCompletionSource<PrepareUploadDecision>? tcs;
        ReceiveSession? session;
        lock (_lock)
        {
            _pendingDecisions.TryGetValue(sessionId, out tcs);
            session = _current;
        }

        // 仅当 IP+sessionId 都匹配本机会话时才真正中断；否则忽略（避免被恶意 cancel 打断他人）
        if (session is null
            || session.SessionId != sessionId
            || !string.Equals(session.SenderIp, NormalizeIp(senderIp), StringComparison.Ordinal))
            return;

        // 等待决策中的取消 → prepare-upload 端点返回 403 "Cancelled by sender"
        if (tcs is not null) tcs.TrySetCanceled();

        lock (_lock)
        {
            foreach (var f in session.Files.Values)
            {
                if (f.Status == ReceiveFileStatus.Pending || f.Status == ReceiveFileStatus.InProgress)
                    f.Status = ReceiveFileStatus.Canceled;
            }
            session.Status = ReceiveSessionStatus.Canceled;
            if (_current == session) _current = null;
        }
        _messenger.Send(new SessionFinishedMessage { Session = session });
    }

    /// <summary>本机用户主动取消：中断写盘流 + Abort 对方连接 + 状态收尾。</summary>
    public void CancelLocal(string sessionId)
    {
        ReceiveSession? session;
        lock (_lock)
        {
            if (_current is null || _current.SessionId != sessionId) return;
            session = _current;
            foreach (var f in session.Files.Values)
            {
                if (f.Status is ReceiveFileStatus.Pending or ReceiveFileStatus.InProgress)
                    f.Status = ReceiveFileStatus.Canceled;
            }
            session.Status = ReceiveSessionStatus.Canceled;
            _current = null;
        }
        App.LogDiag($"[SessionMgr] 本机用户取消会话 {sessionId[..8]}：Abort 连接 + 中断写盘");
        // 先断对方连接（触发对方端错误），再取消本机写盘
        try { session.HttpContext?.Abort(); } catch { }
        session.Cts.Cancel();
        _messenger.Send(new SessionFinishedMessage { Session = session });
    }

    private static bool IsOccupied(ReceiveSession s)
        => s.Status is ReceiveSessionStatus.PendingDecision
            or ReceiveSessionStatus.Accepted
            or ReceiveSessionStatus.InProgress;

    /// <summary>归一化 IP 文本：IPv4-mapped IPv6（::ffff:a.b.c.d）映射为纯 IPv4，
    /// 避免双栈（监听 IPAddress.Any）下同一连接的 RemoteIpAddress 文本不一致导致误拒。</summary>
    private static string NormalizeIp(string ip)
    {
        if (System.Net.IPAddress.TryParse(ip, out var addr))
        {
            if (addr.IsIPv4MappedToIPv6) addr = addr.MapToIPv4();
            return addr.ToString();
        }
        return ip;
    }

    /// <summary>已接受但迟迟无首个 upload 的容忍时长（发送方可能掉线）。</summary>
    private static readonly TimeSpan AcceptedTimeout = TimeSpan.FromMinutes(3);

    /// <summary>传输中两次 upload 请求之间的容忍时长（超过视为卡死，释放单槽）。</summary>
    private static readonly TimeSpan InProgressIdleTimeout = TimeSpan.FromMinutes(10);

    private void CleanupStale()
    {
        ReceiveSession? stale = null;
        var now = DateTime.UtcNow;
        lock (_lock)
        {
            if (_current is null) return;
            var c = _current;
            // 1) 待决策超时（UI 60s 未响应）
            if (c.Status == ReceiveSessionStatus.PendingDecision
                && now - c.CreatedAtUtc > TimeSpan.FromSeconds(PendingDecisionTimeoutSeconds))
            {
                stale = c;
            }
            // 2) 已接受但迟迟无 upload 开始（发送方掉线）
            else if (c.Status == ReceiveSessionStatus.Accepted
                && now - c.LastActivityUtc > AcceptedTimeout)
            {
                stale = c;
            }
            // 3) 传输中长时间无新请求（断链/卡死，避免永久占槽让其他设备一直 409）
            else if (c.Status == ReceiveSessionStatus.InProgress
                && now - c.LastActivityUtc > InProgressIdleTimeout)
            {
                stale = c;
            }
        }
        if (stale is null) return;

        var wasPendingDecision = stale.Status == ReceiveSessionStatus.PendingDecision;
        if (wasPendingDecision)
        {
            // 待决策超时：取消等待 UI 的 tcs（prepare 端点返回 403），保留文件 Pending
            // 以便 UI 判定为"请求超时"
            if (_pendingDecisions.Remove(stale.SessionId, out var tcs))
                tcs.TrySetCanceled();
        }
        else
        {
            // 传输中/已接受卡死：将未完成文件置取消
            lock (_lock)
            {
                foreach (var f in stale.Files.Values)
                {
                    if (f.Status is ReceiveFileStatus.Pending or ReceiveFileStatus.InProgress)
                        f.Status = ReceiveFileStatus.Canceled;
                }
            }
        }

        lock (_lock)
        {
            stale.Status = ReceiveSessionStatus.Failed;
            if (_current == stale) _current = null;
        }
        App.LogDiag($"[SessionMgr] 清理卡槽会话 {stale.SessionId[..8]}（原状态={stale.Status}）");
        _messenger.Send(new SessionFinishedMessage { Session = stale });
    }

    public void Dispose() => _cleanupTimer.Dispose();
}
