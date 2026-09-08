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
    private readonly IDeviceListService _deviceLists;
    private readonly ISettingsService _settings;
    private DispatcherQueue? _dispatcher;

    public ObservableCollection<Device> Devices { get; } = new();
    public BatchObservableCollection<SendFileItem> PendingFiles { get; } = new();

    /// <summary>当前/最近一次会话（UI 绑定进度）。</summary>
    [ObservableProperty]
    private SendSession? _current;

    /// <summary>发送 PIN：目标设备开启了 PIN 校验时必填（prepare-upload ?pin=）。</summary>
    [ObservableProperty]
    private string _pin = string.Empty;

    /// <summary>UI 处理器（每次页面加载覆盖为最新，避免在单例 VM 上 += 累积连弹多个对话框）。
    /// 发送会话创建后弹出发送进度对话框（UI 线程触发）。</summary>
    public Action<SendSession>? TransferStarted { get; set; }

    /// <summary>UI 处理器：会话结束（完成/取消/失败）时关闭进度对话框（UI 线程触发）。</summary>
    public Action? ProgressFinished { get; set; }

    /// <summary>选中的目标设备集合（多选；点“开始发送”逐台排队发送）。</summary>
    public ObservableCollection<Device> SelectedTargets { get; } = new();

    /// <summary>首个选中设备（兼容旧绑定/双击跳转：ShellWindow 置此字段 = 单选该设备）。</summary>
    public Device? SelectedTarget => SelectedTargets.FirstOrDefault();

    /// <summary>选中横幅展示文本：单台显示设备详情，多台显示“已选 N 台设备”。</summary>
    public string SelectedTargetSummary
    {
        get
        {
            var n = SelectedTargets.Count;
            if (n == 0) return string.Empty;
            if (n == 1)
            {
                var d = SelectedTargets[0];
                return $"{d.Alias}  ·  {d.Ip}:{d.Port}  ·  {d.DeviceModel}";
            }
            return $"已选 {n} 台设备";
        }
    }

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
            if (!HasSelectedTarget) return "⚠️ 请先在上方设备网格中勾选一个或多个目标设备";
            if (!HasPendingFiles)    return "⚠️ 请先添加要发送的文件";
            if (!IsIdleOrFinished)   return "⏳ 正在发送，请等待完成或点击“取消”后再发送";
            return "可以发送";
        }
    }

    // ---------- 多设备群发状态 ----------
    /// <summary>是否正处于多设备群发（并行发送）中。为 true 时不弹单台 toast、结束后统一汇总。</summary>
    [ObservableProperty] private bool _isQueueSending;

    /// <summary>群发成功/失败计数（结束时汇总）。</summary>
    private int _queueOkCount;
    private int _queueFailCount;

    /// <summary>批次剩余未收尾台数（UI 线程维护）。</summary>
    private int _queuePending;

    /// <summary>批次全部会话（ShowResult/兜底据此判断“是否群发中”并抑制单台 toast）。</summary>
    private readonly HashSet<SendSession> _queueSessions = new();

    /// <summary>已完成收尾的会话（防 ShowResult 与异常兜底重复收尾/重复记历史）。</summary>
    private readonly HashSet<SendSession> _queueSettled = new();

    /// <summary>整批完成信号：UI 线程 pending 归零时触发，SendBatchAsync 据此收尾复位。</summary>
    private TaskCompletionSource<bool>? _batchDoneTcs;

    /// <summary>UI 处理器：整批会话创建后一次性传入（UI 线程触发）。
    /// SendPage 用它弹“每台一行”的列表进度弹窗。</summary>
    public Action<IReadOnlyList<SendSession>>? QueueBatchStarted { get; set; }

    partial void OnIsQueueSendingChanged(bool value) => RecomputeCanSend();

    public bool HasDevices => Devices.Count > 0;
    public bool HasNoDevices => Devices.Count == 0;
    public bool HasFiles => PendingFiles.Count > 0;
    public bool HasNoFiles => PendingFiles.Count == 0;

    /// <summary>公共刷新状态：从 MulticastDiscoveryService 镜像（绑定 XAML 刷新按钮转圈/禁用）。</summary>
    [ObservableProperty] private bool _isRefreshing;

    /// <summary>正在导入（拖拽/选文件夹后台枚举中）→ 发送页显示“导入中…”。</summary>
    [ObservableProperty] private bool _isImporting;

    public SendViewModel(ISendSessionManager sendMgr, IDeviceRegistry registry,
        MulticastDiscoveryService discovery, IMessenger messenger, TransferHistoryService history,
        IDeviceListService deviceLists, ISettingsService settings)
    {
        _sendMgr = sendMgr;
        _registry = registry;
        _discovery = discovery;
        _messenger = messenger;
        _history = history;
        _deviceLists = deviceLists;
        _settings = settings;
        _messenger.RegisterAll(this);

        // 注入启动时 registry 已有的设备
        foreach (var d in _registry.GetSnapshot()) Devices.Add(d);
        SyncDeviceListFlags();
        _deviceLists.Changed += (_, _) => SyncDeviceListFlags();
        _settings.Changed += (_, _) => SyncDeviceListFlags();
        Devices.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(HasDevices));
            OnPropertyChanged(nameof(HasNoDevices));
            // 设备实例可能被 registry 原位更新（DeviceCollectionSync.Sync），重刷勾选高亮
            SyncIsPickedFlags();
            SyncDeviceListFlags();
        };
        PendingFiles.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(HasFiles));
            OnPropertyChanged(nameof(HasNoFiles));
            RecomputeCanSend();
        };
        SelectedTargets.CollectionChanged += (_, _) =>
        {
            SyncIsPickedFlags();
            OnPropertyChanged(nameof(SelectedTarget));
            OnPropertyChanged(nameof(SelectedTargetSummary));
            OnPropertyChanged(nameof(HasSelectedTarget));
            RecomputeCanSend();
        };
    }

    /// <summary>按 SelectedTargets 集合内容刷新设备卡 IsPicked 高亮。</summary>
    private void SyncIsPickedFlags()
    {
        var picked = SelectedTargets.Select(d => d.Fingerprint).ToHashSet();
        foreach (var d in Devices) d.IsPicked = d.Fingerprint is not null && picked.Contains(d.Fingerprint);
    }

    /// <summary>刷新所有设备的白/黑名单状态（名单变更/设备列表变更/白名单模式切换时调用）。</summary>
    private void SyncDeviceListFlags()
    {
        var whitelistOnly = _settings.Current.WhitelistOnly;
        foreach (var d in Devices)
        {
            d.IsBlacklisted = _deviceLists.IsBlacklisted(d.Fingerprint);
            d.IsWhitelisted = _deviceLists.FindWhitelist(d.Fingerprint) is not null;
            // 白名单模式开启时，非白名单设备也置灰（复用 IsBlacklisted 的置灰效果）
            if (whitelistOnly && !d.IsWhitelisted)
                d.IsBlacklisted = true;
        }
    }

    /// <summary>单选：清空多选，仅选中一台（兼容双击跳转/旧命令）。</summary>
    public void SetSingleTarget(Device? d)
    {
        if (d is null) { SelectedTargets.Clear(); return; }
        if (SelectedTargets.Count == 1 && ReferenceEquals(SelectedTargets[0], d)) return;
        SelectedTargets.Clear();
        SelectedTargets.Add(d);
    }

    /// <summary>切换某台设备的多选状态（UI 勾选设备卡调用）。黑名单设备及白名单模式下的非白名单设备不可选中。</summary>
    public void ToggleTarget(Device? d)
    {
        if (d is null || d.Fingerprint is null) return;
        // 黑名单设备拦截
        if (_deviceLists.IsBlacklisted(d.Fingerprint))
        {
            _messenger.Send(new ShowToastMessage
            {
                Kind = ToastKind.Warning,
                Message = $"「{d.Alias}」已在黑名单中，无法选择发送",
                DurationMs = 1800,
            });
            return;
        }
        // 白名单模式拦截：非白名单设备不可选择
        if (_settings.Current.WhitelistOnly && _deviceLists.FindWhitelist(d.Fingerprint) is null)
        {
            _messenger.Send(new ShowToastMessage
            {
                Kind = ToastKind.Warning,
                Message = $"「{d.Alias}」不在白名单中（仅白名单模式已开启）",
                DurationMs = 1800,
            });
            return;
        }
        var existing = SelectedTargets.FirstOrDefault(x => x.Fingerprint == d.Fingerprint);
        if (existing is not null) SelectedTargets.Remove(existing);
        else SelectedTargets.Add(d);
    }

    /// <summary>是否已勾选该设备（供卡片显示勾选态）。</summary>
    public bool IsTargetSelected(Device? d)
        => d?.Fingerprint is not null && SelectedTargets.Any(x => x.Fingerprint == d.Fingerprint);

    /// <summary>重算所有置灰子条件并刷新 RelayCommand CanExecute + UI 绑定。</summary>
    private void RecomputeCanSend()
    {
        HasSelectedTarget = SelectedTargets.Count > 0;
        HasPendingFiles   = PendingFiles.Count > 0;
        IsIdleOrFinished  = !IsQueueSending
            && (Current is null
                || Current.State == SendSessionState.Completed
                || Current.State == SendSessionState.Cancelled
                || Current.State == SendSessionState.Rejected
                || Current.State == SendSessionState.Failed
                || Current.State == SendSessionState.CancelledByPeer);

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
        if (items is null || items.Count == 0) return;
        IsImporting = true;
        try
        {
            // 枚举/读取（Storage API 与递归）放到后台线程，避免占用 UI 上下文
            var added = await Task.Run(async () =>
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
                            // 递归遍历文件夹并保留相对目录结构（fileName = 相对路径含 '/'，接收端据此重建目录）
                            await CollectFolderFilesAsync(folder, string.Empty, existingPaths, batch);
                        }
                    }
                    catch
                    {
                        // 忽略不可访问项
                    }
                }
                return batch;
            });
            await AppendInChunks(added); // 分批加入，超大目录不一次塞满 UI
            App.LogDiag($"[SendVM] 拖拽添加完成：新增 {added.Count} 个文件");
        }
        finally
        {
            IsImporting = false;
        }
    }

    /// <summary>文件夹选择器入口：后台保留目录结构递归加入（fileName = 相对路径，'/'-分隔）。</summary>
    public async Task AddFolderAsync(Windows.Storage.StorageFolder folder)
    {
        if (folder is null) return;
        IsImporting = true;
        try
        {
            var added = await Task.Run(async () =>
            {
                var existingPaths = new HashSet<string>(PendingFiles.Select(f => f.Path), StringComparer.OrdinalIgnoreCase);
                var batch = new List<SendFileItem>();
                await CollectFolderFilesAsync(folder, string.Empty, existingPaths, batch);
                return batch;
            });
            await AppendInChunks(added);
            App.LogDiag($"[SendVM] 添加文件夹完成：新增 {added.Count} 个文件");
        }
        finally
        {
            IsImporting = false;
        }
    }

    /// <summary>分批加入待发列表：每批之间让出 UI 线程，超大目录下界面仍可响应/渐进显示。</summary>
    private async Task AppendInChunks(List<SendFileItem> items, int chunkSize = 200)
    {
        if (items is null || items.Count == 0) return;
        for (var i = 0; i < items.Count; i += chunkSize)
        {
            var count = Math.Min(chunkSize, items.Count - i);
            var part = items.GetRange(i, count);
            PendingFiles.AddRange(part);
            await Task.Yield();
        }
    }

    // ---------- 发送文字 / 剪贴板文本 ----------

    /// <summary>一次性文本消息的临时目录（发送会话结束后清理）。</summary>
    private static readonly string _textTempDir =
        System.IO.Path.Combine(System.IO.Path.GetTempPath(), "PcDemo", "messages");

    /// <summary>
    /// 把一段文字作为 text/plain 消息发送（官方桌面端同款"发送文字"能力，接收端按 .txt 保存）。
    /// 已选目标且空闲 → 立即发送；否则把文字项加入待发送列表并提示。
    /// </summary>
    public async Task SendTextAsync(string text)
    {
        text = text?.Trim() ?? string.Empty;
        if (text.Length == 0) return;

        PendingFiles.Add(CreateTransientTextItem(text));

        if (SelectedTargets.Count == 0)
        {
            _messenger.Send(new ShowToastMessage
            {
                Kind = ToastKind.Info,
                Message = "文字已加入待发送列表，请先选择目标设备再点「开始发送」",
            });
            return;
        }
        if (!IsIdleOrFinished)
        {
            _messenger.Send(new ShowToastMessage
            {
                Kind = ToastKind.Info,
                Message = "当前正在发送，文字已加入待发送列表",
            });
            return;
        }
        await StartSendAsync();
    }

    /// <summary>把文本写入一次性临时 .txt，构造 SendFileItem（FileName 可读，MIME text/plain）。</summary>
    private static SendFileItem CreateTransientTextItem(string text)
    {
        try { System.IO.Directory.CreateDirectory(_textTempDir); } catch { }
        var fileName = $"消息-{DateTime.Now:yyyyMMdd-HHmmss}.txt";
        var path = System.IO.Path.Combine(_textTempDir, $"{Guid.NewGuid():N}.txt");
        try
        {
            System.IO.File.WriteAllText(path, text, new System.Text.UTF8Encoding(false));
        }
        catch (Exception ex)
        {
            App.LogDiag($"[SendVM] 写入文本临时文件失败：{ex.Message}");
            path = string.Empty; // 发送该文件时将报错提示，不让异常逃逸
        }
        return new SendFileItem
        {
            FileName = fileName,
            Path = path,
            Size = new System.Text.UTF8Encoding(false).GetByteCount(text),
            FileKind = FileKind.Text,
            Extension = "txt",
            IsTransient = true,
        };
    }

    /// <summary>会话结束后清理一次性文本临时文件并从待发列表移除（避免重发已删文件）。</summary>
    private void CleanupTransient(SendSession s)
    {
        if (s is null) return;
        foreach (var f in s.Files)
        {
            if (!f.IsTransient) continue;
            var pending = PendingFiles.FirstOrDefault(p => p.Id == f.Id && p.IsTransient);
            if (pending is not null) PendingFiles.Remove(pending);
            if (!string.IsNullOrEmpty(f.Path))
            {
                try { if (System.IO.File.Exists(f.Path)) System.IO.File.Delete(f.Path); } catch { }
            }
        }
    }

    /// <summary>
    /// 递归遍历文件夹，保留相对目录结构。每个叶子文件的 FileName 设为相对根文件夹的
    /// '/'-分隔路径（如 "sub/img.png"），与官方目录传输编码一致 —— 接收端（含官方 App）
    /// 会在保存目录下按此重建子目录。文件夹不可访问（权限受限）时跳过该目录。
    /// </summary>
    private static async Task CollectFolderFilesAsync(
        Windows.Storage.StorageFolder folder,
        string prefix,
        HashSet<string> existingPaths,
        List<SendFileItem> batch)
    {
        IReadOnlyList<Windows.Storage.IStorageItem> items;
        try { items = await folder.GetItemsAsync(); }
        catch { return; } // 不可访问目录跳过，不影响其余文件

        // 不限制层数但限制总文件数，避免拖入超大目录卡死（10000 上限，沿用原行为）
        var count = 0;
        foreach (var sub in items)
        {
            if (count >= 10000) return;
            try
            {
                if (sub is Windows.Storage.StorageFile file)
                {
                    var path = file.Path;
                    if (string.IsNullOrEmpty(path) || !existingPaths.Add(path)) continue;
                    var props = await file.GetBasicPropertiesAsync();
                    var rel = prefix + file.Name;
                    batch.Add(new SendFileItem
                    {
                        FileName = rel, // 相对路径（含 '/'），发送后接收端重建目录结构
                        Path = path,
                        Size = (long)props.Size,
                        FileKind = FileKindMapper.FromExtension(System.IO.Path.GetExtension(rel)),
                        Extension = System.IO.Path.GetExtension(rel).TrimStart('.'),
                    });
                    count++;
                }
                else if (sub is Windows.Storage.StorageFolder child)
                {
                    await CollectFolderFilesAsync(child, prefix + child.Name + "/", existingPaths, batch);
                }
            }
            catch
            {
                // 忽略单个不可访问项
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

    /// <summary>设备网格选中（单向命令：点设备卡片 → 单选该设备）。</summary>
    [RelayCommand]
    private void SelectDevice(Device? d) => SetSingleTarget(d);

    [RelayCommand(CanExecute = nameof(CanSend))]
    private async Task StartSendAsync()
    {
        if (SelectedTargets.Count == 0 || PendingFiles.Count == 0) return;
        var targets = SelectedTargets.ToList();

        // 从 PendingFiles 复制一份“模板”（每台设备再各克隆一份，避免多台共享文件对象导致进度互相污染）
        var template = PendingFiles.Select(CloneFileItem).ToList();

        // 目标设备开启 PIN 校验时，把输入的 PIN 传给 prepare-upload（官方协议 ?pin=）
        var pin = string.IsNullOrWhiteSpace(Pin) ? null : Pin.Trim();

        if (targets.Count == 1)
        {
            // 单台：维持原弹窗式进度对话框体验
            var session = _sendMgr.CreateSession(targets[0], template);
            Current = session;
            OnPropertyChanged(nameof(CanSend));
            TransferStarted?.Invoke(session);
            _ = Task.Run(async () =>
            {
                await _sendMgr.RunAsync(session, pin, CancellationToken.None);
            }, CancellationToken.None);
            return;
        }

        // 多台：并行发送（各台独立会话同时跑，谁接受谁先传）
        await SendBatchAsync(targets, template, pin);
    }

    private CancellationTokenSource? _queueCts;

    /// <summary>多设备群发（并行）：为每台创建独立会话并同时启动 RunAsync。
    /// 所有会话“谁先接受谁先传”，互不等待；全部结束后统一汇总提示、关闭列表弹窗。</summary>
    private async Task SendBatchAsync(List<Device> targets, List<SendFileItem> template, string? pin)
    {
        if (targets is null || targets.Count == 0) return;
        var total = targets.Count;
        IsQueueSending = true;
        _queueOkCount = 0;
        _queueFailCount = 0;
        _queueSessions.Clear();
        _queueSettled.Clear();
        _sendMgr.SuppressCompletionToast = true; // 单台完成通知由本方法末尾统一汇总
        _queueCts = new CancellationTokenSource();
        var ct = _queueCts.Token;

        // 一次性为每台创建独立会话（互不覆盖、互不取消）
        var sessions = new List<SendSession>(total);
        for (var i = 0; i < total; i++)
        {
            var files = template.Select(CloneFileItem).ToList();
            var session = _sendMgr.CreateSession(targets[i], files);
            sessions.Add(session);
            _queueSessions.Add(session);
            App.LogDiag($"[SendVM] 群发 {i + 1}/{total} → {targets[i].Alias} ({targets[i].Ip})");
        }
        Current = sessions[0];
        OnPropertyChanged(nameof(CanSend));

        // 通知 UI：打开“每台一行”的列表弹窗（一次性传入整批会话，之后各自独立刷新）
        if (_dispatcher is not null && QueueBatchStarted is not null)
        {
            var snapshot = sessions.ToList();
            _dispatcher.TryEnqueue(() => QueueBatchStarted?.Invoke(snapshot));
        }

        _queuePending = total;
        var doneTcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _batchDoneTcs = doneTcs;

        // 并行启动每台：各会话独立跑 prepare → upload
        foreach (var s in sessions)
        {
            var session = s;
            _ = Task.Run(async () =>
            {
                try
                {
                    await _sendMgr.RunAsync(session, pin, ct);
                }
                catch (Exception ex)
                {
                    App.LogDiag($"[SendVM] 群发单台异常（兜底收尾继续其它台）：{ex}");
                }
                finally
                {
                    // 正常路径：RunAsync 已触发 NotifySendFinished → ShowResult 收尾；
                    // 异常逃逸路径：ShowResult 未触发，这里在 UI 线程补一次收尾（幂等防双计）。
                    _dispatcher?.TryEnqueue(() =>
                    {
                        if (_queueSessions.Contains(session) && !_queueSettled.Contains(session))
                        {
                            if (session.State is not (SendSessionState.Completed
                                or SendSessionState.Rejected or SendSessionState.Cancelled
                                or SendSessionState.CancelledByPeer or SendSessionState.Failed))
                            {
                                session.State = SendSessionState.Failed;
                                session.ErrorMessage = "发送中断";
                            }
                            SettleQueueSession(session);
                        }
                    });
                }
            }, CancellationToken.None);
        }

        // 等全部会话在 UI 线程收尾完成（状态已最终化、历史已记录）
        await doneTcs.Task;

        // —— 以下在 UI 线程（await 恢复于命令的 UI 上下文）——
        var ok = _queueOkCount;
        var fail = _queueFailCount;
        _sendMgr.SuppressCompletionToast = false;
        _queueCts?.Dispose();
        _queueCts = null;
        _queueSettled.Clear();
        IsQueueSending = false;
        Current = null;
        // 群发多台共享同一临时文本文件，整批结束后才清理
        CleanupQueueTransients(template);
        OnPropertyChanged(nameof(CanSend));
        OnPropertyChanged(nameof(SendDisabledHint));
        StartSendCommand.NotifyCanExecuteChanged();

        // 汇总提示（成功/失败统计）
        var done = ok + fail;
        if (done > 0)
        {
            var msg = fail == 0
                ? $"已成功发送给全部 {done} 台设备"
                : ok == 0
                    ? $"发送给 {done} 台设备均失败"
                    : $"成功 {ok} 台，失败 {fail} 台（共 {done} 台）";
            _messenger.Send(new ShowToastMessage { Kind = fail == 0 ? ToastKind.Success : ToastKind.Warning, Message = $"群发完成\n{msg}" });
        }

        // 群发结束 → 关闭列表弹窗（与单发共用 ProgressFinished）
        ProgressFinished?.Invoke();

        // 让最后可能仍在队列里的 ShowResult 先跑完，再清空会话集合
        await Task.Yield();
        _queueSessions.Clear();
    }

    /// <summary>单台会话收尾（UI 线程）：记录历史、统计成功/失败，批次最后一台结束时置位完成信号。
    /// 幂等：同一会话只收尾一次（_queueSettled 判重）。</summary>
    private void SettleQueueSession(SendSession s)
    {
        if (!_queueSessions.Contains(s)) return;
        if (!_queueSettled.Add(s)) return; // 已收尾（ShowResult / 兜底 / 正常路径可能重入）

        RecordHistory(s);

        if (s.State == SendSessionState.Completed) _queueOkCount++;
        else _queueFailCount++;

        _queuePending--;
        if (_queuePending <= 0)
        {
            _batchDoneTcs?.TrySetResult(true);
        }
    }

    /// <summary>克隆一个 SendFileItem（保留 Id 以匹配接收端文件 token；进度状态字段为新实例）。</summary>
    private static SendFileItem CloneFileItem(SendFileItem f) => new()
    {
        Id = f.Id,
        FileName = f.FileName,
        Path = f.Path,
        Size = f.Size,
        FileKind = f.FileKind,
        IsTransient = f.IsTransient,
    };

    [RelayCommand]
    private void CancelSend()
    {
        // 群发中：取消整批所有活动会话；单发：取消当前会话
        _queueCts?.Cancel();
        _sendMgr.CancelAll();
    }

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
                // 若离线的是已勾选目标，把它从多选集移除（避免对已消失设备发送）
                var picked = SelectedTargets.FirstOrDefault(x => x.Fingerprint == message.Fingerprint);
                if (picked is not null) SelectedTargets.Remove(picked);
            }
        });
    }

    public void Receive(SendSessionFinishedMessage message)
    {
        // 群发中这条消息由 SendSessionManager.NotifySendFinished 的 messenger.Send 同步投递；
        // 这里必须 try/catch，避免本处理方法抛异常反向传染回 RunAsync 的 catch 块（会绕过
        // 其平级 catch(Exception) 直接逃逸 → tcs 永不完成、群发卡死）。
        try
        {
            _dispatcher?.TryEnqueue(() => ShowResult(message.Session));
        }
        catch (Exception ex)
        {
            App.LogDiag($"[SendVM] SendSessionFinishedMessage 处理异常：{ex}");
        }
    }

    /// <summary>从发送会话构建逐文件明细快照（发送项无保存路径）。</summary>
    private static List<TransferFileDetail> BuildDetails(SendSession s)
    {
        return s.Files.Select(f => new TransferFileDetail
        {
            FileName = f.FileName,
            Size = f.Size,
            Result = f.Status switch
            {
                SendFileStatus.Done => FileDetailResult.Success,
                SendFileStatus.Failed => FileDetailResult.Failed,
                SendFileStatus.Skipped => FileDetailResult.Skipped,
                // Pending/Uploading（会话结束时仍未完成）：按会话整体状态归类
                _ => s.State switch
                {
                    SendSessionState.Cancelled or SendSessionState.CancelledByPeer => FileDetailResult.Canceled,
                    SendSessionState.Rejected => FileDetailResult.Skipped,
                    _ => FileDetailResult.Failed,
                },
            },
            Error = f.ErrorMessage,
        }).ToList();
    }

    private void ShowResult(SendSession s)
    {
        // 群发中（并行多台）：每台完成只做历史与计数（SettleQueueSession 幂等收尾），
        // 不弹单台 toast、不关列表弹窗（整批结束由 SendBatchAsync 统一关闭）。
        if (_queueSessions.Contains(s))
        {
            SettleQueueSession(s);
            return;
        }

        // —— 单发路径 ——
        ProgressFinished?.Invoke();   // 会话结束 → 关闭进度对话框
        CleanupTransient(s);
        RecordHistory(s);

        var failedCount = s.Files.Count(f => f.Status == SendFileStatus.Failed);
        var info = $"{s.CompletedFiles}/{s.Files.Count} 个文件 · {FormatBytes(s.TotalBytesSent)}";
        (string title, string message, ToastKind kind) = s.State switch
        {
            SendSessionState.Completed when failedCount == 0 =>
                ("发送成功", $"{info}\n已发送到 {s.Target.Alias}", ToastKind.Success),
            SendSessionState.Completed =>
                ("发送完成（部分失败）", $"{info}\n{failedCount} 个文件发送失败", ToastKind.Warning),
            SendSessionState.Rejected =>
                ("对方拒绝", s.ErrorMessage ?? "对方拒绝了所有文件", ToastKind.Warning),
            SendSessionState.Cancelled =>
                ("已取消", s.ErrorMessage ?? "你已取消本次发送", ToastKind.Warning),
            SendSessionState.CancelledByPeer =>
                ("会话被打断", s.ErrorMessage ?? "对方终止了会话", ToastKind.Warning),
            _ =>
                ("发送失败", s.ErrorMessage ?? "未知错误", ToastKind.Error),
        };
        _messenger.Send(new ShowToastMessage
        {
            Message = title == message ? message : $"{title}\n{message}",
            Kind = kind,
        });
    }

    /// <summary>记录一条发送历史（单发路径用；群发路径经 SettleQueueSession 调用）。</summary>
    private void RecordHistory(SendSession s)
    {
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
            Files = BuildDetails(s),
        });
    }

    /// <summary>群发整批结束后：清理该批模板中的一次性文本临时文件（多台共享同一文件，不能逐台删）。</summary>
    private void CleanupQueueTransients(List<SendFileItem> template)
    {
        if (template is null) return;
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in template)
        {
            if (!f.IsTransient || string.IsNullOrEmpty(f.Path) || !seen.Add(f.Path)) continue;
            var pending = PendingFiles.FirstOrDefault(p => p.Id == f.Id && p.IsTransient);
            if (pending is not null) PendingFiles.Remove(pending);
            try { if (System.IO.File.Exists(f.Path)) System.IO.File.Delete(f.Path); } catch { }
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
