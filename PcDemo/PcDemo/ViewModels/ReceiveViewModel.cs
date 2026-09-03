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

    // 通知（接收成功/失败提示）
    [ObservableProperty] private bool _isNotificationOpen;
    [ObservableProperty] private string _notificationTitle = string.Empty;
    [ObservableProperty] private string _notificationMessage = string.Empty;
    [ObservableProperty] private InfoBarSeverity _notificationSeverity = InfoBarSeverity.Informational;
    [ObservableProperty] private bool _canOpenFolder;

    public ReceiveViewModel(ISettingsService settings, IReceiveSessionManager sessions, IMessenger messenger,
        MulticastDiscoveryService discovery, TransferHistoryService history, IDeviceRegistry registry)
    {
        _settings = settings;
        _sessions = sessions;
        _messenger = messenger;
        _discovery = discovery;
        _history = history;
        _registry = registry;
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
    }

    /// <summary>公共刷新：委托给 MulticastDiscoveryService.RefreshAsync（EnsureKestrelRunning + AnnounceOnce）。</summary>
    [RelayCommand]
    private Task RefreshDevicesAsync() => _discovery.RefreshAsync();

    /// <summary>本机用户取消当前接收会话（进度对话框"确认取消"按钮调用）。</summary>
    public void CancelTransfer(string sessionId) => _sessions.CancelLocal(sessionId);

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
    }

    public void Receive(DeviceDiscoveredMessage msg)
    {
        _dispatcher?.TryEnqueue(() =>
        {
            var existing = Devices.FirstOrDefault(d => d.Fingerprint == msg.Message.Fingerprint);
            if (existing is null)
            {
                Devices.Add(new Device
                {
                    Fingerprint = msg.Message.Fingerprint,
                    Alias = msg.Message.Alias,
                    DeviceModel = msg.Message.DeviceModel,
                    DeviceType = msg.Message.DeviceType,
                    Port = msg.Message.Port,
                    Protocol = msg.Message.Protocol,
                    Version = msg.Message.Version,
                    Download = msg.Message.Download,
                    Ip = msg.Ip,
                    LastSeenUtcTicks = DateTime.UtcNow.Ticks,
                });
            }
            else
            {
                // 与 SendViewModel 一致：用 UpdateFrom 原位更新并触发 PropertyChanged，
                // 避免 ListView 选中态丢失 + UI 字段不刷新
                existing.UpdateFrom(new Device
                {
                    Fingerprint = msg.Message.Fingerprint,
                    Alias = msg.Message.Alias,
                    DeviceModel = msg.Message.DeviceModel,
                    DeviceType = msg.Message.DeviceType,
                    Port = msg.Message.Port,
                    Protocol = msg.Message.Protocol,
                    Version = msg.Message.Version,
                    Download = msg.Message.Download,
                    Ip = msg.Ip,
                    LastSeenUtcTicks = DateTime.UtcNow.Ticks,
                });
            }
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
            switch (session.Status)
            {
                case ReceiveSessionStatus.Completed:
                    NotificationTitle = "接收成功";
                    NotificationMessage = fileCount > 0
                        ? $"已接收 {fileCount} 个文件到：{dest}"
                        : $"接收完成：{dest}";
                    NotificationSeverity = InfoBarSeverity.Success;
                    StatusText = "接收成功";
                    CanOpenFolder = true; // InfoBar 显示「打开文件夹」按钮
                    break;
                case ReceiveSessionStatus.Failed:
                    NotificationTitle = decisionTimeout ? "接收请求已超时" : "接收失败";
                    NotificationMessage = decisionTimeout
                        ? "60 秒内未做出决策，请求已失效"
                        : $"会话异常终止（{fileCount} 个文件未完成）";
                    NotificationSeverity = InfoBarSeverity.Error;
                    StatusText = decisionTimeout ? "请求超时" : "接收失败";
                    CanOpenFolder = false;
                    break;
                case ReceiveSessionStatus.Canceled:
                    NotificationTitle = "传输已取消";
                    NotificationMessage = "发送方已取消本次传输";
                    NotificationSeverity = InfoBarSeverity.Warning;
                    StatusText = "已取消";
                    CanOpenFolder = false;
                    break;
                case ReceiveSessionStatus.Rejected:
                    NotificationTitle = "已拒绝";
                    NotificationMessage = "你已拒绝本次文件请求";
                    NotificationSeverity = InfoBarSeverity.Warning;
                    StatusText = "已拒绝";
                    CanOpenFolder = false;
                    break;
                default:
                    NotificationTitle = "会话结束";
                    NotificationMessage = $"状态：{session.Status}";
                    NotificationSeverity = InfoBarSeverity.Informational;
                    StatusText = "服务运行中";
                    CanOpenFolder = false;
                    break;
            }
            IsNotificationOpen = true;

            // 5 秒后自动关闭通知（成功/取消/拒绝），失败不自动关（让用户看清错误）
            if (session.Status != ReceiveSessionStatus.Failed)
            {
                _ = Task.Delay(TimeSpan.FromSeconds(5)).ContinueWith(_ =>
                {
                    _dispatcher?.TryEnqueue(() => IsNotificationOpen = false);
                });
            }
        });
    }
}
