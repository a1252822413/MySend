// SendViewModel：发送 Tab 业务状态与命令。
using System.Collections.ObjectModel;
using System.IO;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using CommunityToolkit.Mvvm.Messaging;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using PcDemo.Helpers;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.Models.Dto;
using PcDemo.Networking;
using PcDemo.Services;

namespace PcDemo.ViewModels;

public partial class SendViewModel : ViewModelBase,
    IRecipient<DeviceDiscoveredMessage>,
    IRecipient<DeviceTimedOutMessage>,
    IRecipient<SendSessionFinishedMessage>
{
    private readonly ISendSessionManager _sendMgr;
    private readonly IDeviceRegistry _registry;
    private readonly MulticastDiscoveryService _discovery;
    private readonly IMessenger _messenger;
    private readonly TransferHistoryService _history;
    private DispatcherQueue? _dispatcher;

    public ObservableCollection<Device> Devices { get; } = new();
    public BatchObservableCollection<SendFileItem> PendingFiles { get; } = new();

    /// <summary>当前/最近一次会话（UI 绑定进度）。</summary>
    [ObservableProperty]
    private SendSession? _current;

    /// <summary>发送 PIN：目标设备开启了 PIN 校验时必填（prepare-upload ?pin=）。</summary>
    [ObservableProperty]
    private string _pin = string.Empty;

    /// <summary>UI 订阅：发送会话创建后弹出发送进度对话框（UI 线程触发）。</summary>
    public event Action<SendSession>? TransferStarted;

    /// <summary>UI 订阅：会话结束（完成/取消/失败）时关闭进度对话框（UI 线程触发）。</summary>
    public event Action? ProgressFinished;

    /// <summary>选中设备（Devices 网格选中的那个；不选则按钮灰）。</summary>
    [ObservableProperty] private Device? _selectedTarget;

    /// <summary>拆分的置灰条件（单一 computed 集中管理，UI 可据此显示原因）。</summary>
    [ObservableProperty] private bool _hasSelectedTarget;
    [ObservableProperty] private bool _hasPendingFiles;
    [ObservableProperty] private bool _isIdleOrFinished = true;

    /// <summary>是否可开始发送：已选目标 + 有文件 + 当前未在发送。</summary>
    public bool CanSend => HasSelectedTarget && HasPendingFiles && IsIdleOrFinished;

    /// <summary>按钮置灰时的文字提示，告诉用户还差哪步。</summary>
    public string SendDisabledHint
    {
        get
        {
            if (!HasSelectedTarget) return "⚠️ 请先在上方设备网格中点击选择一个目标设备";
            if (!HasPendingFiles)    return "⚠️ 请先添加要发送的文件";
            if (!IsIdleOrFinished)   return "⏳ 正在发送，请等待完成或点击“取消”后再发送";
            return "可以发送";
        }
    }

    public bool HasDevices => Devices.Count > 0;
    public bool HasNoDevices => Devices.Count == 0;
    public bool HasFiles => PendingFiles.Count > 0;
    public bool HasNoFiles => PendingFiles.Count == 0;

    // 成功/失败浮动提示（InfoBar）
    [ObservableProperty] private bool _isNotificationOpen;
    [ObservableProperty] private string _notificationTitle = string.Empty;
    [ObservableProperty] private string _notificationMessage = string.Empty;
    [ObservableProperty] private InfoBarSeverity _notificationSeverity = InfoBarSeverity.Informational;

    /// <summary>公共刷新状态：从 MulticastDiscoveryService 镜像（绑定 XAML 刷新按钮转圈/禁用）。</summary>
    [ObservableProperty] private bool _isRefreshing;

    private DispatcherQueueTimer? _closeTimer;

    public SendViewModel(ISendSessionManager sendMgr, IDeviceRegistry registry,
        MulticastDiscoveryService discovery, IMessenger messenger, TransferHistoryService history)
    {
        _sendMgr = sendMgr;
        _registry = registry;
        _discovery = discovery;
        _messenger = messenger;
        _history = history;
        _messenger.RegisterAll(this);

        // 注入启动时 registry 已有的设备
        foreach (var d in _registry.GetSnapshot()) Devices.Add(d);
        Devices.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(HasDevices));
            OnPropertyChanged(nameof(HasNoDevices));
        };
        PendingFiles.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(HasFiles));
            OnPropertyChanged(nameof(HasNoFiles));
            RecomputeCanSend();
        };
    }

    /// <summary>重算所有置灰子条件并刷新 RelayCommand CanExecute + UI 绑定。</summary>
    private void RecomputeCanSend()
    {
        HasSelectedTarget = SelectedTarget is not null;
        HasPendingFiles   = PendingFiles.Count > 0;
        IsIdleOrFinished  = Current is null
            || Current.State == SendSessionState.Completed
            || Current.State == SendSessionState.Cancelled
            || Current.State == SendSessionState.Rejected
            || Current.State == SendSessionState.Failed
            || Current.State == SendSessionState.CancelledByPeer;

        OnPropertyChanged(nameof(CanSend));
        OnPropertyChanged(nameof(SendDisabledHint));
        StartSendCommand.NotifyCanExecuteChanged();
    }

    public void SetDispatcher(DispatcherQueue dq)
    {
        if (_dispatcher is not null) return;
        _dispatcher = dq;

        // 订阅公共刷新状态 → 镜像到本 VM 的 IsRefreshing（绑定 XAML 按钮转圈/禁用）
        _discovery.IsRefreshingChanged += (_, value) =>
            dq.TryEnqueue(() => IsRefreshing = value);

        // 4s 心跳定时器：刷 IsOnline 视觉（让长时间没上线的设备变灰）
        var heartbeat = dq.CreateTimer();
        heartbeat.Interval = TimeSpan.FromSeconds(4);
        heartbeat.IsRepeating = true;
        heartbeat.Tick += (_, _) =>
        {
            foreach (var d in Devices) d.RefreshOnlineState();
        };
        heartbeat.Start();

        // InfoBar 自动关闭定时器
        _closeTimer = dq.CreateTimer();
        _closeTimer.Interval = TimeSpan.FromSeconds(5);
        _closeTimer.IsRepeating = false;
        _closeTimer.Tick += (_, _) => IsNotificationOpen = false;
    }

    partial void OnSelectedTargetChanged(Device? value)
    {
        // 同步设备卡选中高亮标记（引用相等比较，不破坏 ListView 选中引用）
        foreach (var d in Devices) d.IsPicked = ReferenceEquals(d, value);
        RecomputeCanSend();
    }

    partial void OnCurrentChanged(SendSession? value)
    {
        RecomputeCanSend();
        if (value is null) return;
        // 会话状态变化时刷新按钮可用性
        value.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(SendSession.State))
                RecomputeCanSend();
        };
    }

    // ---------- commands ----------

    [RelayCommand]
    private Task RefreshDevicesAsync() => _discovery.RefreshAsync();

    /// <summary>由 UI 调用（FileOpenPicker 选取），把本地路径加入 PendingFiles（批量去重后一次入列）。</summary>
    public void AddFiles(IEnumerable<string> paths)
    {
        var existing = new HashSet<string>(PendingFiles.Select(f => f.Path), StringComparer.OrdinalIgnoreCase);
        var batch = new List<SendFileItem>();
        foreach (var p in paths)
        {
            try
            {
                var fi = new FileInfo(p);
                if (!fi.Exists || !existing.Add(p)) continue;
                var ext = fi.Extension;
                batch.Add(new SendFileItem
                {
                    FileName = fi.Name,
                    Path = p,
                    Size = fi.Length,
                    FileKind = FileKindMapper.FromExtension(ext),
                    Extension = ext.TrimStart('.'),
                });
            }
            catch
            {
                // 忽略不可访问文件
            }
        }
        if (batch.Count > 0) PendingFiles.AddRange(batch);
    }

    /// <summary>
    /// 拖拽入口：递归展开 StorageItems（文件 + 文件夹），按路径去重后加入 PendingFiles。
    /// </summary>
    public async Task AddStorageItemsAsync(IReadOnlyList<Windows.Storage.IStorageItem> items)
    {
        var existingPaths = new HashSet<string>(PendingFiles.Select(f => f.Path), StringComparer.OrdinalIgnoreCase);
        var batch = new List<SendFileItem>();
        foreach (var item in items)
        {
            try
            {
                if (item is Windows.Storage.StorageFile file)
                {
                    var path = file.Path;
                    if (string.IsNullOrEmpty(path) || !existingPaths.Add(path)) continue;
                    var props = await file.GetBasicPropertiesAsync();
                    var size = (long)props.Size;
                    var ext = System.IO.Path.GetExtension(path);
                    batch.Add(new SendFileItem
                    {
                        FileName = file.Name,
                        Path = path,
                        Size = size,
                        FileKind = FileKindMapper.FromExtension(ext),
                        Extension = ext.TrimStart('.'),
                    });
                }
                else if (item is Windows.Storage.StorageFolder folder)
                {
                    // 递归遍历文件夹
                    await foreach (var f in EnumerateFilesAsync(folder))
                    {
                        if (!existingPaths.Add(f.Path)) continue;
                        batch.Add(new SendFileItem
                        {
                            FileName = f.Name,
                            Path = f.Path,
                            Size = (long)f.Size,
                            FileKind = FileKindMapper.FromExtension(f.Ext),
                            Extension = f.Ext.TrimStart('.'),
                        });
                    }
                }
            }
            catch
            {
                // 忽略不可访问项
            }
        }
        if (batch.Count > 0) PendingFiles.AddRange(batch);
        App.LogDiag($"[SendVM] 拖拽添加完成：新增 {batch.Count} 个文件");
    }

    /// <summary>递归遍历文件夹，返回 (Path, Name, Size, Ext)。</summary>
    private static async IAsyncEnumerable<(string Path, string Name, long Size, string Ext)> EnumerateFilesAsync(
        Windows.Storage.StorageFolder folder)
    {
        // 不限制层数，但限制最大文件数避免卡死（10000 个上限）
        var count = 0;
        var items = await folder.GetItemsAsync();
        foreach (var sub in items)
        {
            if (count >= 10000) yield break;
            if (sub is Windows.Storage.StorageFile f)
            {
                var props = await f.GetBasicPropertiesAsync();
                yield return (f.Path, f.Name, (long)props.Size, System.IO.Path.GetExtension(f.Path));
                count++;
            }
            else if (sub is Windows.Storage.StorageFolder subFolder)
            {
                await foreach (var inner in EnumerateFilesAsync(subFolder))
                {
                    if (count >= 10000) yield break;
                    yield return inner;
                    count++;
                }
            }
        }
    }

    [RelayCommand]
    private void RemoveFile(SendFileItem? f)
    {
        if (f is null) return;
        PendingFiles.Remove(f);
    }

    [RelayCommand]
    private void ClearFiles() => PendingFiles.Clear();

    /// <summary>设备网格选中（单向命令：点设备卡片 → 设 SelectedTarget）。</summary>
    [RelayCommand]
    private void SelectDevice(Device? d)
    {
        SelectedTarget = d;
    }

    [RelayCommand(CanExecute = nameof(CanSend))]
    private async Task StartSendAsync()
    {
        if (SelectedTarget is null || PendingFiles.Count == 0) return;

        // 从 PendingFiles 复制一份新实例（避免复用后 BytesSent 等遗留）
        var files = PendingFiles.Select(f => new SendFileItem
        {
            Id = f.Id,
            FileName = f.FileName,
            Path = f.Path,
            Size = f.Size,
            FileKind = f.FileKind,
        }).ToList();
        var session = _sendMgr.CreateSession(SelectedTarget, files);
        Current = session;
        OnPropertyChanged(nameof(CanSend));

        // 目标设备开启 PIN 校验时，把输入的 PIN 传给 prepare-upload（官方协议 ?pin=）
        var pin = string.IsNullOrWhiteSpace(Pin) ? null : Pin.Trim();

        // UI 订阅：弹出发送进度对话框（UI 线程触发）
        TransferStarted?.Invoke(session);

        // 后台跑（不阻塞 UI 线程）
        _ = Task.Run(async () =>
        {
            await _sendMgr.RunAsync(session, pin, CancellationToken.None);
        }, CancellationToken.None);
    }

    [RelayCommand]
    private void CancelSend()
    {
        _sendMgr.CancelCurrent();
    }

    // ---------- messenger handlers ----------
    public void Receive(DeviceDiscoveredMessage message)
    {
        _dispatcher?.TryEnqueue(() =>
        {
            // 与 ReceiveViewModel 共用同步逻辑：registry 实例复用 + 原位更新
            // （SelectedTarget 仍是 existing 引用，不会变 null）
            DeviceCollectionSync.Sync(Devices, _registry, message.Ip, message.Message);
        });
    }

    public void Receive(DeviceTimedOutMessage message)
    {
        // 离线/超时设备从列表移除（手动刷新清理未响应设备也走此消息）
        _dispatcher?.TryEnqueue(() =>
        {
            var d = Devices.FirstOrDefault(x => x.Fingerprint == message.Fingerprint);
            if (d is not null)
            {
                Devices.Remove(d);
                if (ReferenceEquals(SelectedTarget, d)) SelectedTarget = null;
            }
        });
    }

    public void Receive(SendSessionFinishedMessage message)
    {
        _dispatcher?.TryEnqueue(() => ShowResult(message.Session));
    }

    private void ShowResult(SendSession s)
    {
        // 会话结束 → 关闭进度对话框（若开着）
        ProgressFinished?.Invoke();

        // 记录传输历史
        _history.Add(new TransferHistoryItem
        {
            Direction = TransferDirection.Send,
            PeerName = s.Target.Alias,
            FileCount = s.Files.Count,
            TotalBytes = s.TotalBytesSent,
            Result = s.State switch
            {
                SendSessionState.Completed => TransferResult.Success,
                SendSessionState.Failed => TransferResult.Failed,
                _ => TransferResult.Canceled,
            },
            FinishedAt = DateTime.Now,
            FirstFileName = s.Files.Count == 1 ? System.IO.Path.GetFileName(s.Files[0].Path) : null,
        });

        var info = $"{s.CompletedFiles}/{s.Files.Count} 个文件 · {FormatBytes(s.TotalBytesSent)}";
        switch (s.State)
        {
            case SendSessionState.Completed:
                NotificationTitle = "发送成功";
                NotificationMessage = $"{info} 已发送到 {s.Target.Alias}";
                NotificationSeverity = InfoBarSeverity.Success;
                break;
            case SendSessionState.Rejected:
                NotificationTitle = "对方拒绝";
                NotificationMessage = s.ErrorMessage ?? "对方拒绝了所有文件";
                NotificationSeverity = InfoBarSeverity.Warning;
                break;
            case SendSessionState.Cancelled:
                NotificationTitle = "已取消";
                NotificationMessage = s.ErrorMessage ?? "你已取消本次发送";
                NotificationSeverity = InfoBarSeverity.Warning;
                break;
            case SendSessionState.CancelledByPeer:
                NotificationTitle = "会话被打断";
                NotificationMessage = s.ErrorMessage ?? "对方终止了会话";
                NotificationSeverity = InfoBarSeverity.Warning;
                break;
            case SendSessionState.Failed:
            default:
                NotificationTitle = "发送失败";
                NotificationMessage = s.ErrorMessage ?? "未知错误";
                NotificationSeverity = InfoBarSeverity.Error;
                break;
        }
        IsNotificationOpen = true;
        // 成功/警告 5 秒自动关；错误不关
        if (NotificationSeverity != InfoBarSeverity.Error)
        {
            if (_closeTimer is not null)
            {
                _closeTimer.Stop();
                _closeTimer.Start();
            }
        }
    }

    private static string FormatBytes(long b)
    {
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double size = b;
        int i = 0;
        while (size >= 1024 && i < units.Length - 1) { size /= 1024; i++; }
        return $"{size:0.##} {units[i]}";
    }
}
