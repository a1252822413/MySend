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

        lock (_lock)
        {
            // 单槽：当前会话仍占用（待决策/已接受/接收中）→ 409
            if (_current is not null && IsOccupied(_current))
            {
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

            // Accept 空集合 → 204 NoContent
            if (decision.AcceptedFileIds.Count == 0)
            {
                session.Status = ReceiveSessionStatus.Completed;
                if (_current == session) _current = null;
                _messenger.Send(new SessionFinishedMessage { Session = session });
                return new PrepareUploadResult { StatusCode = 204 };
            }

            session.Status = ReceiveSessionStatus.Accepted;
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

        App.LogDiag($"[SessionMgr] 开始写盘：{file.Metadata.FileName}（{file.Metadata.Size} bytes）到 {_settings.Current.Destination}");
        try
        {
            var path = await _fileSaver.SaveAsync(_settings.Current.Destination, file.Metadata.FileName, body,
                progress, session.Cts.Token, file.Metadata.Sha256);
            lock (_lock)
            {
                file.Status = ReceiveFileStatus.Completed;
                file.SavedPath = path;
            }
            App.LogDiag($"[SessionMgr] 写盘成功：{path}");

            bool allDone;
            lock (_lock) allDone = session.Files.Values.All(f => f.Status == ReceiveFileStatus.Completed);

            _dispatcher.TryEnqueue(() =>
            {
                p.CompletedFiles = session.Files.Values.Count(f => f.Status == ReceiveFileStatus.Completed);
                if (allDone)
                {
                    p.PhaseText = "接收完成";
                    p.IsIndeterminate = false;
                    p.IsCompleted = true;
                }
                else
                {
                    p.PhaseText = "等待下一个文件…";
                    p.IsIndeterminate = true;
                }
            });

            if (allDone)
            {
                lock (_lock)
                {
                    session.Status = ReceiveSessionStatus.Completed;
                    if (_current == session) _current = null;
                }
                // 窗口隐藏在托盘时提醒用户（前台可见时静默）
                var savedCount = session.Files.Values.Count(f => f.Status == ReceiveFileStatus.Completed);
                App.ShowTransferToast("接收完成",
                    $"来自 {session.Sender.Alias} 的 {savedCount} 个文件已保存到 {_settings.Current.Destination}");
                _messenger.Send(new SessionFinishedMessage { Session = session });
            }
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
            // SHA-256 校验失败（协议 422），半成品文件已由 FileSaver 删除
            App.LogDiag($"[SessionMgr] {ex.Message}");
            lock (_lock)
            {
                file.Status = ReceiveFileStatus.Failed;
                file.Error = "SHA-256 校验失败";
                session.Status = ReceiveSessionStatus.Failed;
                if (_current == session) _current = null;
            }
            _messenger.Send(new SessionFinishedMessage { Session = session });
            return new UploadResult { StatusCode = 422, ErrorMessage = "Checksum mismatch" };
        }
        catch (Exception ex)
        {
            App.LogDiag($"[SessionMgr] 写盘失败：{ex.GetType().Name}: {ex.Message}{(ex.InnerException is null ? "" : $" | inner: {ex.InnerException.Message}")}");
            lock (_lock)
            {
                file.Status = ReceiveFileStatus.Failed;
                file.Error = ex.Message;
                session.Status = ReceiveSessionStatus.Failed;
                if (_current == session) _current = null;
            }
            // 写盘失败也视为会话结束 → 释放 Session 对象 + 通知 UI 关进度对话框 + 记历史
            _messenger.Send(new SessionFinishedMessage { Session = session });
            return new UploadResult { StatusCode = 500, ErrorMessage = "Failed to save file" };
        }
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
            || !string.Equals(session.SenderIp, senderIp, StringComparison.Ordinal))
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

    private void CleanupStale()
    {
        ReceiveSession? stale = null;
        lock (_lock)
        {
            if (_current is not null
                && _current.Status == ReceiveSessionStatus.PendingDecision
                && DateTime.UtcNow - _current.CreatedAtUtc > TimeSpan.FromSeconds(PendingDecisionTimeoutSeconds))
            {
                stale = _current;
            }
        }
        if (stale is null) return;

        if (_pendingDecisions.Remove(stale.SessionId, out var tcs))
            tcs.TrySetCanceled();

        lock (_lock) { if (_current == stale) _current = null; }
        stale.Status = ReceiveSessionStatus.Failed;
        _messenger.Send(new SessionFinishedMessage { Session = stale });
    }

    public void Dispose() => _cleanupTimer.Dispose();
}
