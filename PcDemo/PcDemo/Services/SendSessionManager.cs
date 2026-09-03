// ISendSessionManager / SendSessionManager：一次发送会话的编排（prepare → 逐个 upload → 状态机/进度/取消）。
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
    /// <summary>当前活动会话（null = 没有）。</summary>
    SendSession? Current { get; }

    /// <summary>创建新会话（目标设备 + 文件）。覆盖旧会话。</summary>
    SendSession CreateSession(Device target, IEnumerable<SendFileItem> files);

    /// <summary>启动新创建的会话：prepare-upload → 顺序 upload。</summary>
    Task RunAsync(SendSession session, string? pin = null, CancellationToken ct = default);

    /// <summary>取消当前活动会话（best-effort 通知对方）。</summary>
    void CancelCurrent();
}

public partial class SendSessionManager : ObservableObject, ISendSessionManager
{
    private readonly SendClient _client;
    private readonly IMessenger _messenger;
    private readonly DispatcherQueue _dispatcher;

    [ObservableProperty] private SendSession? _current;

    /// <summary>当前活动会话的取消 token 源（UI Cancel 按钮调用 CancelCurrent 时触发）。</summary>
    private CancellationTokenSource? _cts;

    public SendSessionManager(SendClient client, IMessenger messenger,
        DispatcherQueue dispatcher)
    {
        _client = client;
        _messenger = messenger;
        _dispatcher = dispatcher;
    }

    public SendSession CreateSession(Device target, IEnumerable<SendFileItem> files)
    {
        CancelCurrent();
        // 重置速度采样（上一个会话的采样残留不能带入新会话）
        _speedLastTicks = 0;
        _speedLastBytes = 0;
        _speedEma = 0;
        _progressLastBytes = 0;
        _progressLastTimestamp = 0;
        _progressLastFile = null;
        var session = new SendSession { Target = target };
        foreach (var f in files) session.Files.Add(f);
        // 监控每个文件 BytesSent → 推高会话 TotalBytesSent
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
        try { _cts?.Cancel(); } catch { }
    }

    public async Task RunAsync(SendSession session, string? pin = null, CancellationToken external = default)
    {
        var cts = CancellationTokenSource.CreateLinkedTokenSource(external);
        _cts = cts;
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
                            bytes => SetFileProgress(f, bytes),
                            ct);
                        SetFileProgress(f, f.Size, force: true); // 补推最终字节，保证进度收尾准确
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
                            SetFileProgress(f, 0, force: true);
                            SetFileStatus(f, SendFileStatus.Uploading);
                            continue;
                        }
                        SetFileStatus(f, SendFileStatus.Failed);
                        f.ErrorMessage = ex.Message;
                        SetState(session, SendSessionState.Failed);
                        session.ErrorMessage = $"{f.FileName}: {ex.Message}";
                        // best-effort 通知对方 cancel，避免对方一直等
                        try { await _client.CancelAsync(proto, target.Ip, session.RemoteSessionId!, CancellationToken.None); }
                        catch { }
                        NotifySendFinished(session);
                        return;
                    }
                }
            }
            // 完成
            SetState(session, SendSessionState.Completed);
            App.LogDiag($"[Send] ✓ completed {sentCount}/{session.Files.Count} files");
            // 窗口隐藏在托盘时提醒用户（前台可见时静默）
            App.ShowTransferToast("发送完成",
                $"已向 {session.Target.Alias} 发送 {sentCount}/{session.Files.Count} 个文件");
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
            if (_cts == cts)
            {
                cts.Dispose();
                _cts = null;
            }
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
    private const long ProgressMinBytesDelta = 512 * 1024;
    private const int ProgressMinIntervalMs = 250;
    private readonly object _progressGate = new();
    private SendFileItem? _progressLastFile;
    private long _progressLastBytes;
    private long _progressLastTimestamp;

    private void SetFileProgress(SendFileItem f, long bytes, bool force = false)
    {
        var now = Stopwatch.GetTimestamp();
        if (!force)
        {
            lock (_progressGate)
            {
                if (!ReferenceEquals(f, _progressLastFile))
                {
                    // 文件切换：重置基线并立即推送首包进度
                    _progressLastFile = f;
                    _progressLastBytes = bytes;
                    _progressLastTimestamp = now;
                }
                else
                {
                    var delta = bytes - _progressLastBytes;
                    var elapsedMs = (now - _progressLastTimestamp) * 1000 / Stopwatch.Frequency;
                    if (delta < ProgressMinBytesDelta && elapsedMs < ProgressMinIntervalMs)
                        return; // 吞掉本次，保留最新值到下一次达标回调
                    _progressLastBytes = bytes;
                    _progressLastTimestamp = now;
                }
            }
        }
        else
        {
            _progressLastBytes = bytes;
            _progressLastTimestamp = now;
        }
        _dispatcher.TryEnqueue(() => f.BytesSent = bytes);
    }

    // ---------- 速度采样（EMA：瞬时 = Δbytes/Δt，平滑后算 ETA） ----------
    private long _speedLastTicks;
    private long _speedLastBytes;
    private double _speedEma;

    private void RecalcTotalSent(SendSession session)
    {
        var sum = session.Files.Sum(f => f.BytesSent);
        var now = Stopwatch.GetTimestamp();

        var elapsed = _speedLastTicks == 0
            ? 0
            : (now - _speedLastTicks) / (double)Stopwatch.Frequency;

        // 每 ≥0.5s 采一个样：瞬时速度 → EMA(0.3 新 + 0.7 旧)，重传回退时瞬时值 clamp 到 0
        if (elapsed >= 0.5)
        {
            var inst = Math.Max(0, (sum - _speedLastBytes) / elapsed);
            _speedEma = _speedEma == 0 ? inst : _speedEma * 0.7 + inst * 0.3;
            _speedLastBytes = sum;
            _speedLastTicks = now;
        }
        else if (_speedLastTicks == 0)
        {
            _speedLastBytes = sum;
            _speedLastTicks = now;
        }

        var remaining = Math.Max(0, session.TotalBytes - sum);
        var eta = _speedEma > 1024 ? remaining / _speedEma : 0; // 速度太低(<1KB/s)时不显示 ETA
        var speed = (long)_speedEma;

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
