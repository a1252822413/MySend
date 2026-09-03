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

    /// <summary>UI 订阅：用户接受后弹出接收进度对话框（UI 线程触发）。</summary>
    public event Action<ReceiveSession>? TransferAccepted;

    /// <summary>UI 订阅：会话结束（成功/失败/取消）时关闭进度对话框（UI 线程触发）。</summary>
    public event Action? ProgressFinished;

    /// <summary>UI 订阅：等待用户决策期间会话被服务端清理（60s 决策超时/发送方取消）→ 关闭请求对话框。</summary>
    public event Action? DecisionExpired;

    /// <summary>当前正在等待 UI 决策的会话（单槽约束下至多一个）。</summary>
    private string? _awaitingDecisionSessionId;

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

    // 通知（接收成功/失败提示）
    [ObservableProperty] private bool _canOpenFolder;

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

        // 列表增删时同步空状态属性
        Devices.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(HasDevices));
            OnPropertyChanged(nameof(HasNoDevices));
        };

        RefreshFromSettings();
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
        Port = s.Port;
        Fingerprint = s.Fingerprint;
        OnPropertyChanged(nameof(FingerprintShort));
    }

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

        if (RequestUserDecision is null)
        {
            App.LogDiag($"[ReceiveVM] PrepareUpload 到达但 RequestUserDecision 未注入，sessionId={session.SessionId[..8]}，降级 Decline");
            _sessions.Decline(session.SessionId);
            return;
        }

        App.LogDiag($"[ReceiveVM] PrepareUpload 入队 UI 决策，sessionId={session.SessionId[..8]}，文件数={session.Files.Count}");
        _dispatcher.TryEnqueue(async () =>
        {
            _awaitingDecisionSessionId = session.SessionId;
            PrepareUploadDecision? decision = null;
            try
            {
                decision = await RequestUserDecision(session);
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
                if (decision is null || !decision.Accepted)
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

    public void Receive(SessionFinishedMessage msg)
    {
        _dispatcher?.TryEnqueue(() =>
        {
            var session = msg.Session;
            var fileCount = session.Files.Count;
            var dest = _settings.Current.Destination;

            // 等待决策期间会话被清理（60s 决策超时/发送方取消）→ 关闭仍开着的请求对话框，
            // 避免用户对已死会话点"接收"后 Accept 静默无效、再弹出卡死的进度对话框
            if (_awaitingDecisionSessionId == session.SessionId)
            {
                _awaitingDecisionSessionId = null;
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
            CanOpenFolder = session.Status == ReceiveSessionStatus.Completed;
            _messenger.Send(new ShowToastMessage
            {
                Kind = kind,
                Message = $"{title}\n{body}",
            });
        });
    }
}
