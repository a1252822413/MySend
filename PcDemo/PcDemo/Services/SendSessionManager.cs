// ISendSessionManager / SendSessionManager：发送会话的编排（prepare → upload → 状态机/进度/取消）。
// 支持多会话并发（多设备群发时每台一个会话同时跑，采样/取消按会话隔离）。
using System.Collections.Concurrent;
using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Messaging;
using Microsoft.UI.Dispatching;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.Networking;

namespace PcDemo.Services;

public interface ISendSessionManager
{
    /// <summary>最近创建的会话（null = 没有）。并发下仅用于跟踪“最新”，具体会话由调用方持有。</summary>
    SendSession? Current { get; }

    /// <summary>创建新会话（目标设备 + 文件）。不取消其它已存在的会话（支持多会话并行）。</summary>
    SendSession CreateSession(Device target, IEnumerable<SendFileItem> files);

    /// <summary>启动指定会话：prepare-upload → 顺序 upload。多个会话可并发调用。</summary>
    Task RunAsync(SendSession session, string? pin = null, CancellationToken ct = default);

    /// <summary>取消最近创建的会话（best-effort 通知对方）。</summary>
    void CancelCurrent();

    /// <summary>取消全部活动会话（多设备群发一键取消）。</summary>
    void CancelAll();

    /// <summary>群发时抑制单台完成 toast（由调用方在整批结束后统一汇总提示）。</summary>
    bool SuppressCompletionToast { get; set; }
}

public partial class SendSessionManager : ObservableObject, ISendSessionManager
{
    private readonly SendClient _client;
    private readonly IMessenger _messenger;
    private readonly DispatcherQueue _dispatcher;

    [ObservableProperty] private SendSession? _current;

    /// <summary>群发时抑制单台完成 toast（整批结束后由 UI 统一汇总）。</summary>
    public bool SuppressCompletionToast { get; set; }

    /// <summary>按会话隔离的运行状态：每会话独立的取消源 + 进度节流/速度采样基线。
    /// 上传回调在后台线程、状态更新在 UI 线程，用字典避免并发会话互相污染。</summary>
    private sealed class SessionRuntime
    {
        public CancellationTokenSource? Cts;
        public readonly object ProgressGate = new();
        public SendFileItem? ProgressLastFile;
        public long ProgressLastBytes;
        public long ProgressLastTimestamp;
        public long SpeedLastTicks;
        public long SpeedLastBytes;
        public double SpeedEma;
    }

    private readonly ConcurrentDictionary<SendSession, SessionRuntime> _runtimes = new();

    public SendSessionManager(SendClient client, IMessenger messenger,
        DispatcherQueue dispatcher)
    {
        _client = client;
        _messenger = messenger;
        _dispatcher = dispatcher;
    }

    public SendSession CreateSession(Device target, IEnumerable<SendFileItem> files)
    {
        // 只为本会话登记全新运行时（采样/取消按会话隔离）；不取消其它会话（多设备群发要并行）。
        var session = new SendSession { Target = target };
        foreach (var f in files) session.Files.Add(f);
        _runtimes[session] = new SessionRuntime();

        // 监控每个文件 BytesSent → 推高会话 TotalBytesSent（仅读写本会话的运行时）
        foreach (var f in session.Files)
        {
            f.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName == nameof(SendFileItem.BytesSent))
                    RecalcTotalSent(session);
            };
        }
        Current = session;
        return session;
    }

    public void CancelCurrent()
    {
        if (Current is { } s && _runtimes.TryGetValue(s, out var rt))
        {
            try { rt.Cts?.Cancel(); } catch { }
        }
    }

    public void CancelAll()
    {
        foreach (var rt in _runtimes.Values)
        {
            try { rt.Cts?.Cancel(); } catch { }
        }
    }

    public async Task RunAsync(SendSession session, string? pin = null, CancellationToken external = default)
    {
        var rt = _runtimes.GetOrAdd(session, _ => new SessionRuntime());
        var cts = CancellationTokenSource.CreateLinkedTokenSource(external);
        rt.Cts = cts;
        var ct = cts.Token;
        var target = session.Target;

        try
        {
            SetState(session, SendSessionState.WaitingForReceiver);

            // 先做协议探测（对方可能 HTTPS-only 或端口不一致，手机端官方 App 默认 https:53318）。
            var proto = await _client.DetectProtocolAsync(target, ct);
            App.LogDiag($"[Send] 使用协议 {proto.Scheme}://{target.Ip}:{proto.Port}" +
                        (proto.Alias is not null ? $" (alias={proto.Alias})" : ""));

            App.LogDiag($"[Send] → prepare-upload to {target.Alias} ({target.Ip}:{proto.Port}) " +
                        $"{session.Files.Count} files, {session.TotalBytes} bytes");

            // 1) prepare-upload（阻塞等对方决策，取消时 SendClient 内部 best-effort cancel）
            var prepared = await _client.PrepareUploadAsync(proto, target.Ip, session.Files, pin, ct);

            if (prepared.Response is null)
            {
                SetState(session, SendSessionState.Rejected);
                session.ErrorMessage = "对方拒绝了所有文件";
                NotifySendFinished(session);
                return;
            }
            session.RemoteSessionId = prepared.Response.SessionId;
            session.AcceptedTokens = prepared.Response.Files;
            App.LogDiag($"[Send] ↑ accepted {session.AcceptedFiles}/{session.Files.Count} files, " +
                        $"sessionId={session.RemoteSessionId}");

            if (session.AcceptedFiles == 0)
            {
                SetState(session, SendSessionState.Rejected);
                session.ErrorMessage = "对方没有接受任何文件";
                NotifySendFinished(session);
                return;
            }

            // 2) 顺序上传（与 send_task.rs 一样按文件名稳定排序）
            SetState(session, SendSessionState.InProgress);
            var acceptedOrder = session.Files
                .Where(f => session.AcceptedTokens!.ContainsKey(f.Id))
                .OrderBy(f => f.FileName, StringComparer.OrdinalIgnoreCase)
                .ToList();
            var sentCount = 0;
            foreach (var f in acceptedOrder)
            {
                ct.ThrowIfCancellationRequested();
                if (!session.AcceptedTokens.TryGetValue(f.Id, out var token))
                {
                    f.Status = SendFileStatus.Skipped;
                    continue;
                }
                SetFileStatus(f, SendFileStatus.Uploading);

                // 每个文件最多尝试 2 次（网络闪断自动重试一次；取消/被打断/二次失败不重试）
                for (var attempt = 1; ; attempt++)
                {
                    try
                    {
                        await _client.UploadAsync(proto, target.Ip,
                            session.RemoteSessionId!, f.Id, token,
                            f.Path, f.Size,
                            bytes => SetFileProgress(session, f, bytes),
                            ct);
                        SetFileProgress(session, f, f.Size, force: true); // 补推最终字节，保证进度收尾准确
                        SetFileStatus(f, SendFileStatus.Done);
                        sentCount++;
                        break;
                    }
                    catch (SendCancelledException)
                    {
                        SetFileStatus(f, SendFileStatus.Failed);
                        f.ErrorMessage = "已取消";
                        SetState(session, SendSessionState.Cancelled);
                        session.ErrorMessage = "发送已取消";
                        App.LogDiag($"[Send] cancelled after {sentCount} files sent");
                        // best-effort 通知对方取消，避免对方一直等
                        _ = _client.CancelAsync(proto, target.Ip, session.RemoteSessionId!, CancellationToken.None);
                        NotifySendFinished(session);
                        return;
                    }
                    catch (SendBlockedException ex)
                    {
                        SetFileStatus(f, SendFileStatus.Failed);
                        f.ErrorMessage = ex.Message;
                        SetState(session, SendSessionState.CancelledByPeer);
                        session.ErrorMessage = $"会话被打断：{ex.Message}";
                        NotifySendFinished(session);
                        return;
                    }
                    catch (SendClientException ex)
                    {
                        if (attempt == 1)
                        {
                            App.LogDiag($"[Send] ↻ upload retry: {f.FileName}: {ex.Message}");
                            SetFileProgress(session, f, 0, force: true);
                            SetFileStatus(f, SendFileStatus.Uploading);
                            continue;
                        }
                        // 二次失败：跳过该文件、继续发送其余文件（不再整批中断）
                        SetFileStatus(f, SendFileStatus.Failed);
                        f.ErrorMessage = ex.Message;
                        App.LogDiag($"[Send] ✗ 跳过失败文件继续其余：{f.FileName}: {ex.Message}");
                        break; // 结束该文件的重试，进入下一个文件
                    }
                }
            }
            // 完成（可能含被跳过的失败文件）
            var failedFiles = session.Files.Count(f => f.Status == SendFileStatus.Failed);
            if (sentCount == 0)
            {
                SetState(session, SendSessionState.Failed);
                session.ErrorMessage = failedFiles > 0 ? "所有文件发送失败（详见文件明细）" : "没有文件发送成功";
                if (!SuppressCompletionToast)
                    App.ShowTransferToast("发送失败", $"未能向 {session.Target.Alias} 发送任何文件");
            }
            else
            {
                SetState(session, SendSessionState.Completed);
                if (failedFiles > 0) session.ErrorMessage = $"{failedFiles} 个文件发送失败";
                if (!SuppressCompletionToast)
                    App.ShowTransferToast(failedFiles > 0 ? "发送完成（部分失败）" : "发送完成",
                        $"已向 {session.Target.Alias} 发送 {sentCount}/{session.Files.Count} 个文件{(failedFiles > 0 ? $"，{failedFiles} 个失败" : "")}");
            }
            App.LogDiag($"[Send] ✓ finished {sentCount}/{session.Files.Count} files (failed={failedFiles})");
            NotifySendFinished(session);
        }
        catch (SendCancelledException)
        {
            SetState(session, SendSessionState.Cancelled);
            session.ErrorMessage = "发送已取消";
            NotifySendFinished(session);
        }
        catch (SendRejectedException ex)
        {
            SetState(session, SendSessionState.Rejected);
            session.ErrorMessage = ex.Message;
            NotifySendFinished(session);
        }
        catch (SendBlockedException ex)
        {
            SetState(session, SendSessionState.CancelledByPeer);
            session.ErrorMessage = ex.Message;
            NotifySendFinished(session);
        }
        catch (OperationCanceledException)
        {
            SetState(session, SendSessionState.Cancelled);
            session.ErrorMessage = "发送已取消";
            NotifySendFinished(session);
        }
        catch (Exception ex)
        {
            SetState(session, SendSessionState.Failed);
            session.ErrorMessage = ex.Message;
            App.LogDiag($"[Send] ✗ unexpected failure: {ex}");
            NotifySendFinished(session);
        }
        finally
        {
            ClearSpeed(session);
            if (rt.Cts == cts)
            {
                cts.Dispose();
                rt.Cts = null;
            }
            // 会话已结束，移除运行时（避免长期持有 Session 引用防 GC）
            _runtimes.TryRemove(session, out _);
        }
    }

    // ---------- dispatcher-bound state mutators ----------
    private void SetState(SendSession s, SendSessionState state)
    {
        _dispatcher.TryEnqueue(() => s.State = state);
    }

    private void SetFileStatus(SendFileItem f, SendFileStatus status)
    {
        _dispatcher.TryEnqueue(() => f.Status = status);
    }

    // 进度节流：ProgressStreamContent 每 64KB 块回调一次，千兆网 ~1600 块/秒，
    // 若每块都 TryEnqueue + 全量 Sum 会造成 UI 队列洪水。对齐接收端 FileSaver 策略：
    // ≥512KB 或 ≥250ms 才推一次（回调线程直接判断，不入队）。
    // 节流基线按单个文件计算（文件切换时重置），否则上一文件的字节残留会跨文件污染增量判断。
    // 基线存于会话运行时：多会话并发时各自独立，互不干扰。
    private const long ProgressMinBytesDelta = 512 * 1024;
    private const int ProgressMinIntervalMs = 250;

    private void SetFileProgress(SendSession s, SendFileItem f, long bytes, bool force = false)
    {
        var rt = _runtimes[s];
        var now = Stopwatch.GetTimestamp();
        if (!force)
        {
            lock (rt.ProgressGate)
            {
                if (!ReferenceEquals(f, rt.ProgressLastFile))
                {
                    // 文件切换：重置基线并立即推送首包进度
                    rt.ProgressLastFile = f;
                    rt.ProgressLastBytes = bytes;
                    rt.ProgressLastTimestamp = now;
                }
                else
                {
                    var delta = bytes - rt.ProgressLastBytes;
                    var elapsedMs = (now - rt.ProgressLastTimestamp) * 1000 / Stopwatch.Frequency;
                    if (delta < ProgressMinBytesDelta && elapsedMs < ProgressMinIntervalMs)
                        return; // 吞掉本次，保留最新值到下一次达标回调
                    rt.ProgressLastBytes = bytes;
                    rt.ProgressLastTimestamp = now;
                }
            }
        }
        else
        {
            rt.ProgressLastBytes = bytes;
            rt.ProgressLastTimestamp = now;
        }
        _dispatcher.TryEnqueue(() => f.BytesSent = bytes);
    }

    // ---------- 速度采样（EMA：瞬时 = Δbytes/Δt，平滑后算 ETA） ----------
    // 采样基线存于会话运行时：多会话并发时各自独立。
    private void RecalcTotalSent(SendSession session)
    {
        if (!_runtimes.TryGetValue(session, out var rt)) return; // 会话已结束，忽略迟到的采样
        var sum = session.Files.Sum(f => f.BytesSent);
        var now = Stopwatch.GetTimestamp();

        var elapsed = rt.SpeedLastTicks == 0
            ? 0
            : (now - rt.SpeedLastTicks) / (double)Stopwatch.Frequency;

        // 每 ≥0.5s 采一个样：瞬时速度 → EMA(0.3 新 + 0.7 旧)，重传回退时瞬时值 clamp 到 0
        if (elapsed >= 0.5)
        {
            var inst = Math.Max(0, (sum - rt.SpeedLastBytes) / elapsed);
            rt.SpeedEma = rt.SpeedEma == 0 ? inst : rt.SpeedEma * 0.7 + inst * 0.3;
            rt.SpeedLastBytes = sum;
            rt.SpeedLastTicks = now;
        }
        else if (rt.SpeedLastTicks == 0)
        {
            rt.SpeedLastBytes = sum;
            rt.SpeedLastTicks = now;
        }

        var remaining = Math.Max(0, session.TotalBytes - sum);
        var eta = rt.SpeedEma > 1024 ? remaining / rt.SpeedEma : 0; // 速度太低(<1KB/s)时不显示 ETA
        var speed = (long)rt.SpeedEma;

        _dispatcher.TryEnqueue(() =>
        {
            session.TotalBytesSent = sum;
            session.SpeedBytesPerSecond = speed;
            session.EtaSeconds = eta;
        });
    }

    /// <summary>会话结束（完成/取消/失败）后清零速度与 ETA。</summary>
    private void ClearSpeed(SendSession session)
    {
        _dispatcher.TryEnqueue(() =>
        {
            session.SpeedBytesPerSecond = 0;
            session.EtaSeconds = 0;
        });
    }

    private void NotifySendFinished(SendSession session)
    {
        // 结束状态 → 释放 Current 引用，避免 Session 对象（Files 列表等）长期被 GC 根链持有
        // 注意：用 ObservableObject 的 Current 赋值触发 PropertyChanged → VM 自动刷新 CanSend
        // 在 dispatcher 线程清，避免竞态（UI 绑定可能还在访问）
        _dispatcher.TryEnqueue(() =>
        {
            if (ReferenceEquals(Current, session)) Current = null;
        });
        _messenger.Send(new SendSessionFinishedMessage(session));
    }
}
