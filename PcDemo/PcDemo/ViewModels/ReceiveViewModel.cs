// ReceiveViewModel：本机设备信息 + 附近设备列表 + 会话事件接收。
// 在 UI 线程同步 ObservableCollection（通过 DispatcherQueue）。
using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using CommunityToolkit.Mvvm.Messaging;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.Networking;
using PcDemo.Services;

namespace PcDemo.ViewModels;

public partial class ReceiveViewModel : ViewModelBase,
    IRecipient<DeviceDiscoveredMessage>,
    IRecipient<DeviceTimedOutMessage>,
    IRecipient<PrepareUploadRequestedMessage>,
    IRecipient<SessionFinishedMessage>
{
    private readonly ISettingsService _settings;
    private readonly IReceiveSessionManager _sessions;
    private readonly IMessenger _messenger;
    private readonly MulticastDiscoveryService _discovery;
    private readonly TransferHistoryService _history;
    private readonly IDeviceRegistry _registry;
    private readonly IDeviceListService _deviceLists;
    private DispatcherQueue? _dispatcher;

    /// <summary>UI 注入：收到 prepare-upload 时弹对话框的回调。返回 null 表示无法弹窗（默认拒绝）。</summary>
    public Func<ReceiveSession, Task<PrepareUploadDecision?>>? RequestUserDecision { get; set; }

    /// <summary>UI 处理器（每次页面加载覆盖为最新，避免在单例 VM 上 += 累积导致连弹多个对话框）。
    /// 用户接受后弹出接收进度对话框（UI 线程触发）。</summary>
    public Action<ReceiveSession>? TransferAccepted { get; set; }

    /// <summary>UI 处理器：会话结束（成功/失败/取消）时关闭进度对话框（UI 线程触发）。</summary>
    public Action? ProgressFinished { get; set; }

    /// <summary>UI 处理器：等待用户决策期间会话被服务端清理（60s 决策超时/发送方取消）→ 关闭请求对话框。</summary>
    public Action? DecisionExpired { get; set; }

    /// <summary>当前正在等待 UI 决策的会话（单槽约束下至多一个）。</summary>
    private string? _awaitingDecisionSessionId;

    /// <summary>主窗口隐藏到托盘期间挂起的待决策会话。
    /// 隐藏时无法弹 ContentDialog，改走系统 toast 的动作按钮（打开/全部接收/拒绝）；
    /// 窗口恢复可见或有 toast 回调时再处理。</summary>
    private ReceiveSession? _deferredSession;
    private bool _deferredPending;

    public ObservableCollection<Device> Devices { get; } = new();

    /// <summary>空状态切换（x:Bind 自动 bool→Visibility）。</summary>
    public bool HasDevices => Devices.Count > 0;
    public bool HasNoDevices => Devices.Count == 0;

    [ObservableProperty] private string _alias = string.Empty;
    [ObservableProperty] private int _port;
    [ObservableProperty] private string _statusText = "服务运行中";
    [ObservableProperty] private string _fingerprint = string.Empty;
    [ObservableProperty] private bool _isRefreshing;

    /// <summary>缩略指纹：只显示前 8 位 + 省略号（64位 → 9 字符，不挤右侧空间）。</summary>
    public string FingerprintShort
    {
        get
        {
            if (string.IsNullOrEmpty(Fingerprint)) return Fingerprint;
            if (Fingerprint.Length <= 8) return Fingerprint;
            return string.Concat(Fingerprint.AsSpan(0, 8), "…");
        }
    }

    /// <summary>把完整指纹复制到剪贴板，成功/失败通过居中 Toast（消息总线 ShowToastMessage）显示。
    /// WinUI3 Clipboard 必须在关联 CoreWindow 的 UI 线程调用。</summary>
    [RelayCommand]
    public void CopyFingerprint()
    {
        if (string.IsNullOrEmpty(Fingerprint)) return;

        void DoCopy()
        {
            try
            {
                var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
                package.SetText(Fingerprint);
                Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
                Windows.ApplicationModel.DataTransfer.Clipboard.Flush();

                App.LogDiag($"[CopyFingerprint] 已写入剪贴板 fp(前8)={Fingerprint[..Math.Min(8, Fingerprint.Length)]}");
                _messenger.Send(new ShowToastMessage
                {
                    Message = $"指纹已复制\n前 8 位：{Fingerprint[..Math.Min(8, Fingerprint.Length)]}…",
                    Kind = ToastKind.Success,
                    DurationMs = 1700,
                });
            }
            catch (Exception ex)
            {
                App.LogDiag($"[CopyFingerprint] 异常：{ex.GetType().Name}: {ex.Message}");
                _messenger.Send(new ShowToastMessage
                {
                    Message = $"复制失败：{ex.Message}",
                    Kind = ToastKind.Error,
                    DurationMs = 2200,
                });
            }
        }

        if (_dispatcher is not null)
            _dispatcher.TryEnqueue(DoCopy);
        else
            DoCopy();
    }

    public ReceiveViewModel(ISettingsService settings, IReceiveSessionManager sessions, IMessenger messenger,
        MulticastDiscoveryService discovery, TransferHistoryService history, IDeviceRegistry registry,
        IDeviceListService deviceLists)
    {
        _settings = settings;
        _sessions = sessions;
        _messenger = messenger;
        _discovery = discovery;
        _history = history;
        _registry = registry;
        _deviceLists = deviceLists;
        _messenger.RegisterAll(this);

        // 与 SendViewModel 一致：注入启动时 registry 已有的设备
        // （设备可能在 VM 构造前就已 Upsert 到 registry，去抖会阻止后续重复广播，
        //   不从 registry 加载的话 Devices 集合会永远为空）
        foreach (var d in _registry.GetSnapshot()) Devices.Add(d);
        SyncDeviceListFlags();
        _deviceLists.Changed += (_, _) => SyncDeviceListFlags();

        // 列表增删时同步空状态属性
        Devices.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(HasDevices));
            OnPropertyChanged(nameof(HasNoDevices));
            SyncDeviceListFlags();
        };

        RefreshFromSettings();

        // 设置变化（含 HTTPS 开关/端口）→ 刷新接收页显示的端口与协议徽标
        _settings.Changed += (_, _) => { RefreshFromSettings(); SyncDeviceListFlags(); };
    }

    /// <summary>刷新所有设备的白/黑名单状态（名单变更/设备列表变更时调用）。</summary>
    private void SyncDeviceListFlags()
    {
        var whitelistOnly = _settings.Current.WhitelistOnly;
        foreach (var d in Devices)
        {
            d.IsBlacklisted = _deviceLists.IsBlacklisted(d.Fingerprint);
            d.IsWhitelisted = _deviceLists.FindWhitelist(d.Fingerprint) is not null;
            if (whitelistOnly && !d.IsWhitelisted)
                d.IsBlacklisted = true;
        }
    }

    public void SetDispatcher(DispatcherQueue dq)
    {
        if (_dispatcher is not null) return;
        _dispatcher = dq;

        // 订阅公共刷新状态 → 镜像到本 VM 的 IsRefreshing（绑定 XAML 按钮转圈/禁用）
        _discovery.IsRefreshingChanged += (_, value) =>
            dq.TryEnqueue(() =>
            {
                IsRefreshing = value;
                StatusText = value ? "正在刷新..." : "服务运行中";
            });

        // 4s 心跳定时器：刷 IsOnline 视觉（与 SendViewModel 一致，否则接收页在线点永不变化）
        var heartbeat = dq.CreateTimer();
        heartbeat.Interval = TimeSpan.FromSeconds(4);
        heartbeat.IsRepeating = true;
        heartbeat.Tick += (_, _) =>
        {
            foreach (var d in Devices) d.RefreshOnlineState();
        };
        heartbeat.Start();
    }

    /// <summary>公共刷新：委托给 MulticastDiscoveryService.RefreshAsync（EnsureKestrelRunning + AnnounceOnce）。</summary>
    [RelayCommand]
    private Task RefreshDevicesAsync() => _discovery.RefreshAsync();

    /// <summary>本机用户取消当前接收会话（进度对话框"确认取消"按钮调用）。</summary>
    public void CancelTransfer(string sessionId) => _sessions.CancelLocal(sessionId);

    // ---------- 设备名单快捷操作（右键菜单调用） ----------
    [RelayCommand]
    private void AddToWhitelist(Device? d)
    {
        if (d is null) return;
        _deviceLists.AddWhitelist(d.Fingerprint, d.Alias, d.DeviceModel, d.DeviceType);
    }

    [RelayCommand]
    private void AddToBlacklist(Device? d)
    {
        if (d is null) return;
        _deviceLists.AddBlacklist(d.Fingerprint, d.Alias, d.DeviceModel, d.DeviceType);
    }

    /// <summary>在资源管理器中打开保存目录（InfoBar「打开文件夹」按钮调用）。</summary>
    public void OpenDestinationFolder()
    {
        try
        {
            var dest = _settings.Current.Destination;
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = dest,
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            App.LogDiag($"[Receive] 打开文件夹失败：{ex.Message}");
        }
    }

    public void RefreshFromSettings()
    {
        var s = _settings.Current;
        Alias = s.Alias;
        // 显示实际服务端口：HTTPS-only 时为 端口+1（如 53318）
        Port = EndpointConfig.ServicePort(_settings);
        Fingerprint = s.Fingerprint;
        OnPropertyChanged(nameof(FingerprintShort));
        OnPropertyChanged(nameof(ProtocolText));
    }

    /// <summary>当前协议徽标（启用 HTTPS → 该端口提供加密 https）。</summary>
    public string ProtocolText => EndpointConfig.HttpsEnabled(_settings) ? "HTTPS · v2.2" : "HTTP · v2.2";

    public void Receive(DeviceDiscoveredMessage msg)
    {
        _dispatcher?.TryEnqueue(() =>
        {
            // 与 SendViewModel 共用同步逻辑：registry 实例复用 + 原位 UpdateFrom
            // （保留 ListView 选中引用 + 触发 UI 字段刷新）
            DeviceCollectionSync.Sync(Devices, _registry, msg.Ip, msg.Message);
        });
    }

    public void Receive(DeviceTimedOutMessage msg)
    {
        _dispatcher?.TryEnqueue(() =>
        {
            var d = Devices.FirstOrDefault(x => x.Fingerprint == msg.Fingerprint);
            if (d is not null) Devices.Remove(d);
        });
    }

    public void Receive(PrepareUploadRequestedMessage msg)
    {
        var session = msg.Session;

        // 诊断 + 降级：dispatcher 未就绪时直接拒绝，避免 tcs 永不 SetResult 导致 prepare-upload 端点死等
        if (_dispatcher is null)
        {
            App.LogDiag($"[ReceiveVM] PrepareUpload 到达但 _dispatcher 仍为 null，sessionId={session.SessionId[..8]}，降级 Decline");
            _sessions.Decline(session.SessionId);
            return;
        }

        // 自动接收优先级：白名单条目 AutoAccept > 全局 settings.Download；
        // 黑名单在 PrepareUpload 端点已拦截（不会到这里），这里只处理「跳过弹窗」分支
        var senderFp = session.Sender?.Fingerprint;
        var whitelistEntry = !string.IsNullOrEmpty(senderFp) ? _deviceLists.FindWhitelist(senderFp!) : null;
        var autoAccept = whitelistEntry?.AutoAccept == true || _settings.Current.Download;
        if (autoAccept)
        {
            App.LogDiag($"[ReceiveVM] 自动接收（{(whitelistEntry?.AutoAccept == true ? "白名单" : "全局")}），直接接受 sessionId={session.SessionId[..8]} 文件数={session.Files.Count}");
            _dispatcher.TryEnqueue(() =>
            {
                _sessions.Accept(session.SessionId, session.Files.Keys.ToList());
                TransferAccepted?.Invoke(session);
            });
            return;
        }

        // 主窗口对用户不可见（隐藏到托盘/最小化）→ ContentDialog 弹给看不见的用户只会白等
        // 60s 超时被自动拒绝；改为把会话挂起，弹带动作按钮的系统 toast（打开处理/全部接收/拒绝），
        // 由 App 激活回调驱动（ReceiveViewModel.OnWindowBecameVisible / Accept·DeclineFromNotification）。
        // 记录窗口可见性判定，便于排查"走了弹窗还是 toast 决策"
        if (!App.IsMainWindowVisible)
        {
            App.LogDiag($"[ReceiveVM] 窗口不可见，接收请求改走托盘 toast 决策，sessionId={session.SessionId[..8]}，文件数={session.Files.Count}");
            _deferredSession = session;
            _deferredPending = true;
            _awaitingDecisionSessionId = session.SessionId;
            App.ShowTransferRequestToast(
                "收到文件传输请求",
                $"{session.Sender?.Alias} 想发送 {session.Files.Count} 个文件",
                session.SessionId);
            return;
        }
        App.LogDiag($"[ReceiveVM] 窗口可见，走弹窗决策，sessionId={session.SessionId[..8]}");

        if (RequestUserDecision is null)
        {
            App.LogDiag($"[ReceiveVM] PrepareUpload 到达但 RequestUserDecision 未注入，sessionId={session.SessionId[..8]}，降级 Decline");
            _sessions.Decline(session.SessionId);
            return;
        }

        PromptForDecision(session);
    }

    /// <summary>窗口可见时弹请求对话框等待用户决策（UI 线程入队执行）。</summary>
    private void PromptForDecision(ReceiveSession session)
    {
        // 快照委托（字段在 await 期间可能变化，编译器流分析也要求非空判断）
        var request = RequestUserDecision;
        if (request is null)
        {
            // 页面未注入（罕见）：把会话挂起并弹动作 toast，等页面注入/窗口处理，避免请求丢失
            App.LogDiag($"[ReceiveVM] PromptForDecision: RequestUserDecision 未注入，改走 toast 挂起，sessionId={session.SessionId[..8]}");
            _deferredSession = session;
            _deferredPending = true;
            _awaitingDecisionSessionId = session.SessionId;
            App.ShowTransferRequestToast(
                "收到文件传输请求",
                $"{session.Sender?.Alias} 想发送 {session.Files.Count} 个文件",
                session.SessionId);
            return;
        }

        App.LogDiag($"[ReceiveVM] 入队 UI 决策，sessionId={session.SessionId[..8]}，文件数={session.Files.Count}");
        _dispatcher?.TryEnqueue(async () =>
        {
            // 走正常弹窗时清掉隐藏期间可能的挂起标记，避免状态残留
            if (_deferredPending && _deferredSession?.SessionId == session.SessionId)
            {
                _deferredPending = false;
                _deferredSession = null;
            }
            _awaitingDecisionSessionId = session.SessionId;
            PrepareUploadDecision? decision = null;
            try
            {
                decision = await request(session);
            }
            catch (Exception ex)
            {
                // ContentDialog.ShowAsync 可能因 XamlRoot 失效等抛异常；async void lambda 会吞异常
                // 这里捕获后降级 Decline，确保 tcs 被 SetResult，prepare-upload 端点能返回 403
                App.LogDiag($"[ReceiveVM] RequestUserDecision 抛异常：{ex.GetType().Name}: {ex.Message}");
            }
            if (_awaitingDecisionSessionId == session.SessionId)
                _awaitingDecisionSessionId = null;

            // 决策落地段也要整体保护：Accept / TransferAccepted（弹进度对话框）抛异常
            // 同样会以 async void 逃逸直接崩进程（2026-09-03 修复）
            try
            {
                // 全不选（AcceptedFileIds 为空）等价"拒绝"，不应作为"接受 0 文件"进入成功态
                if (decision is null || !decision.Accepted || decision.AcceptedFileIds.Count == 0)
                {
                    _sessions.Decline(session.SessionId);
                }
                else
                {
                    _sessions.Accept(session.SessionId, decision.AcceptedFileIds);
                    // 用户已接受 → 弹接收进度对话框
                    TransferAccepted?.Invoke(session);
                }
            }
            catch (Exception ex)
            {
                App.LogDiag($"[ReceiveVM] 决策落地失败：{ex.GetType().Name}: {ex.Message}");
                try { _sessions.Decline(session.SessionId); } catch { }
            }
        });
    }

    /// <summary>主窗口恢复可见（托盘打开 / toast「打开处理」）→ 补弹隐藏期间挂起的请求对话框。</summary>
    public void OnWindowBecameVisible()
    {
        _dispatcher?.TryEnqueue(() =>
        {
            if (!_deferredPending) return;
            var session = _deferredSession;
            _deferredPending = false;
            _deferredSession = null;
            if (session is null) return;

            var cur = _sessions.CurrentSession;
            if (cur is null || cur.SessionId != session.SessionId
                || cur.Status != ReceiveSessionStatus.PendingDecision)
            {
                App.LogDiag($"[ReceiveVM] 补弹跳过：会话已不在等待决策（{cur?.Status}），可能已超时/被处理");
                return;
            }
            PromptForDecision(cur);
        });
    }

    /// <summary>toast「全部接收」：直接接受会话全部文件。
    /// 窗口可见时补弹进度对话框；隐藏则后台写盘、完成走系统 toast（不打断用户）。</summary>
    public void AcceptFromNotification(string sessionId)
    {
        Action act = () =>
        {
            var cur = _sessions.CurrentSession;
            if (cur is null || cur.SessionId != sessionId
                || cur.Status != ReceiveSessionStatus.PendingDecision)
            {
                App.LogDiag($"[ReceiveVM] toast 全部接收失败：会话不在等待决策（{cur?.Status}）");
                return;
            }
            if (_deferredPending && _deferredSession?.SessionId == sessionId)
            {
                _deferredPending = false;
                _deferredSession = null;
            }
            if (_awaitingDecisionSessionId == sessionId) _awaitingDecisionSessionId = null;

            var ids = cur.Files.Keys.ToList();
            _sessions.Accept(sessionId, ids);
            App.LogDiag($"[ReceiveVM] toast 全部接收：sessionId={sessionId[..8]}，文件数={ids.Count}");
            if (App.IsMainWindowVisible) TransferAccepted?.Invoke(cur);
        };
        if (_dispatcher is null) act();
        else _dispatcher.TryEnqueue(() => act());
    }

    /// <summary>toast「拒绝」：直接拒绝该接收请求（prepare-upload 返回 403）。</summary>
    public void DeclineFromNotification(string sessionId)
    {
        Action act = () =>
        {
            if (_deferredPending && _deferredSession?.SessionId == sessionId)
            {
                _deferredPending = false;
                _deferredSession = null;
            }
            if (_awaitingDecisionSessionId == sessionId) _awaitingDecisionSessionId = null;
            _sessions.Decline(sessionId);
            App.LogDiag($"[ReceiveVM] toast 拒绝：sessionId={sessionId[..8]}");
        };
        if (_dispatcher is null) act();
        else _dispatcher.TryEnqueue(() => act());
    }

    /// <summary>从接收会话构建逐文件明细快照（文件状态 + 保存路径）。</summary>
    private static List<TransferFileDetail> BuildDetails(ReceiveSession session)
    {
        return session.Files.Values.Select(f => new TransferFileDetail
        {
            FileName = f.Metadata.FileName,
            Size = (long)f.Metadata.Size,
            Result = f.Status switch
            {
                ReceiveFileStatus.Completed => FileDetailResult.Success,
                ReceiveFileStatus.Failed => FileDetailResult.Failed,
                ReceiveFileStatus.Canceled => FileDetailResult.Canceled,
                // Pending/InProgress（会话结束时仍未完成）：按会话整体状态归类
                _ => session.Status switch
                {
                    ReceiveSessionStatus.Canceled => FileDetailResult.Canceled,
                    ReceiveSessionStatus.Rejected => FileDetailResult.Skipped,
                    _ => FileDetailResult.Failed,
                },
            },
            Error = f.Error,
            SavedPath = f.Status == ReceiveFileStatus.Completed ? f.SavedPath : null,
        }).ToList();
    }

    public void Receive(SessionFinishedMessage msg)
    {
        _dispatcher?.TryEnqueue(() =>
        {
            var session = msg.Session;
            var fileCount = session.Files.Count;
            // 优先用会话固化快照（传输中改设置不影响本会话记录）；空则回退当前设置目录
            var dest = !string.IsNullOrEmpty(session.DestinationDir)
                ? session.DestinationDir
                : _settings.Current.Destination;

            // 等待决策期间会话被清理（60s 决策超时/发送方取消）→ 关闭仍开着的请求对话框，
            // 避免用户对已死会话点"接收"后 Accept 静默无效、再弹出卡死的进度对话框
            if (_awaitingDecisionSessionId == session.SessionId)
            {
                _awaitingDecisionSessionId = null;
                if (_deferredPending && _deferredSession?.SessionId == session.SessionId)
                {
                    _deferredPending = false;
                    _deferredSession = null;
                }
                DecisionExpired?.Invoke();
            }

            // 会话结束 → 关闭进度对话框（若开着）；
            // 接收成功例外：进度对话框自行切换"打开文件夹/关闭"完成态，保持打开等用户操作
            if (session.Status != ReceiveSessionStatus.Completed)
                ProgressFinished?.Invoke();

            // 记录传输历史
            var result = session.Status switch
            {
                ReceiveSessionStatus.Completed => TransferResult.Success,
                ReceiveSessionStatus.Failed => TransferResult.Failed,
                _ => TransferResult.Canceled,
            };
            _history.Add(new TransferHistoryItem
            {
                Direction = TransferDirection.Receive,
                PeerName = session.Sender.Alias,
                FileCount = fileCount,
                TotalBytes = session.Files.Values.Sum(f => (long)f.Metadata.Size),
                Result = result,
                FinishedAt = DateTime.Now,
                DestinationPath = dest,
                FirstFileName = fileCount == 1 ? session.Files.Values.FirstOrDefault()?.Metadata.FileName : null,
                Files = BuildDetails(session),
            });

            // 决策超时特判：Failed 且所有文件仍 Pending → 60s 内未做出决策
            var decisionTimeout = session.Status == ReceiveSessionStatus.Failed
                && session.Files.Values.All(f => f.Status == ReceiveFileStatus.Pending);

            // 根据 Status 区分成功/失败/取消
            (string title, string body, ToastKind kind) = session.Status switch
            {
                ReceiveSessionStatus.Completed =>
                    ("接收成功",
                     fileCount > 0
                         ? $"{fileCount} 个文件\n已保存到：{dest}"
                         : $"已保存到：{dest}",
                     ToastKind.Success),
                ReceiveSessionStatus.Failed when decisionTimeout =>
                    ("接收请求已超时", "60 秒内未做出决策，请求已失效", ToastKind.Warning),
                ReceiveSessionStatus.Failed =>
                    ("接收失败", $"会话异常终止\n{fileCount} 个文件未完成", ToastKind.Error),
                ReceiveSessionStatus.Canceled =>
                    ("传输已取消", "发送方已取消本次传输", ToastKind.Warning),
                ReceiveSessionStatus.Rejected =>
                    ("已拒绝", "你已拒绝本次文件请求", ToastKind.Warning),
                _ =>
                    ("会话结束", $"状态：{session.Status}", ToastKind.Info),
            };
            StatusText = session.Status switch
            {
                ReceiveSessionStatus.Completed => "接收成功",
                ReceiveSessionStatus.Failed when decisionTimeout => "请求超时",
                ReceiveSessionStatus.Failed => "接收失败",
                ReceiveSessionStatus.Canceled => "已取消",
                ReceiveSessionStatus.Rejected => "已拒绝",
                _ => "服务运行中",
            };
            _messenger.Send(new ShowToastMessage
            {
                Kind = kind,
                Message = $"{title}\n{body}",
            });
        });
    }
}
