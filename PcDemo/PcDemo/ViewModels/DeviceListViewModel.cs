// DeviceListViewModel：白名单/黑名单管理页的视图模型。
// 数据源是 IDeviceListService（只读快照），Changed 事件触发后镜像到本地 ObservableCollection。
// 从已发现设备添加：注入 IDeviceRegistry 提供 GetSnapshot()，UI 用 ComboBox 选设备。
using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using PcDemo.Models;
using PcDemo.Services;

namespace PcDemo.ViewModels;

public partial class DeviceListViewModel : ViewModelBase
{
    private readonly IDeviceListService _service;
    private readonly IDeviceRegistry _registry;
    private DispatcherQueue? _dispatcher;

    public ObservableCollection<DeviceListEntry> Whitelist { get; } = new();
    public ObservableCollection<DeviceListEntry> Blacklist { get; } = new();

    /// <summary>「从已发现设备添加」下拉框的数据源（实时快照，UI 选一个加入）。</summary>
    public ObservableCollection<Device> DiscoveredDevices { get; } = new();

    [ObservableProperty] private Device? _selectedDiscovered;
    [ObservableProperty] private string _newFingerprint = string.Empty;
    [ObservableProperty] private string _newAlias = string.Empty;
    [ObservableProperty] private string _statusText = string.Empty;

    public DeviceListViewModel(IDeviceListService service, IDeviceRegistry registry)
    {
        _service = service;
        _registry = registry;
        _service.Changed += OnServiceChanged;
        RefreshFromService();
        RefreshDiscovered();
    }

    public void SetDispatcher(DispatcherQueue dq)
    {
        _dispatcher = dq;
    }

    private void OnServiceChanged(object? sender, EventArgs e)
    {
        // _dispatcher 可能在 VM 构造后、Page 尚未 SetDispatcher 时为 null
        // （如用户在 SendPage 右键加入，DeviceListPage 还没打开过）；
        // 此时直接同步刷新（在调用线程），首次导航到管理页时会再 RefreshFromService 一次
        if (_dispatcher is null)
        {
            RefreshFromService();
            return;
        }
        _dispatcher.TryEnqueue(RefreshFromService);
    }

    /// <summary>把服务的只读快照镜像到本地 ObservableCollection（差分：保留引用，触发 UI 刷新）。</summary>
    private void RefreshFromService()
    {
        SyncList(Whitelist, _service.Whitelist);
        SyncList(Blacklist, _service.Blacklist);
    }

    private static void SyncList(ObservableCollection<DeviceListEntry> target, IReadOnlyList<DeviceListEntry> source)
    {
        // 简化：移除不在 source 中的，新增 source 中新增的（按 Fingerprint 比对）
        for (var i = target.Count - 1; i >= 0; i--)
        {
            if (!source.Any(x => x.Fingerprint == target[i].Fingerprint))
                target.RemoveAt(i);
        }
        foreach (var entry in source)
        {
            var existing = target.FirstOrDefault(x => x.Fingerprint == entry.Fingerprint);
            if (existing is null)
            {
                target.Add(entry);
            }
            else
            {
                // 原位更新（保留 UI 选中态）
                existing.Alias = entry.Alias;
                existing.AutoAccept = entry.AutoAccept;
                existing.DeviceModel = entry.DeviceModel;
                existing.DeviceType = entry.DeviceType;
            }
        }
    }

    /// <summary>刷新已发现设备下拉框（从 DeviceRegistry 取快照）。</summary>
    [RelayCommand]
    public void RefreshDiscovered()
    {
        var snapshot = _registry.GetSnapshot();
        // 移除已不在的
        for (var i = DiscoveredDevices.Count - 1; i >= 0; i--)
        {
            if (!snapshot.Any(d => d.Fingerprint == DiscoveredDevices[i].Fingerprint))
                DiscoveredDevices.RemoveAt(i);
        }
        // 新增
        foreach (var d in snapshot)
        {
            if (!DiscoveredDevices.Any(x => x.Fingerprint == d.Fingerprint))
                DiscoveredDevices.Add(d);
        }
    }

    // ---------- 白名单 ----------

    /// <summary>从下拉框选中的已发现设备加入白名单。</summary>
    [RelayCommand]
    private void AddWhitelistFromDiscovered()
    {
        if (SelectedDiscovered is null)
        {
            StatusText = "请先在上方选择一个已发现的设备";
            return;
        }
        _service.AddWhitelist(SelectedDiscovered.Fingerprint, SelectedDiscovered.Alias,
            SelectedDiscovered.DeviceModel, SelectedDiscovered.DeviceType);
        StatusText = $"已将「{SelectedDiscovered.Alias}」加入白名单";
        SelectedDiscovered = null;
    }

    /// <summary>手动输入指纹+别名加入白名单（离线设备）。</summary>
    [RelayCommand]
    private void AddWhitelistManual()
    {
        var fp = NewFingerprint.Trim();
        if (fp.Length == 0)
        {
            StatusText = "请输入设备指纹";
            return;
        }
        _service.AddWhitelist(fp, string.IsNullOrWhiteSpace(NewAlias) ? "(未命名)" : NewAlias.Trim());
        StatusText = $"已将「{NewAlias}」加入白名单";
        NewFingerprint = string.Empty;
        NewAlias = string.Empty;
    }

    [RelayCommand]
    private void RemoveWhitelist(DeviceListEntry? entry)
    {
        if (entry is null) return;
        _service.RemoveWhitelist(entry.Fingerprint);
        StatusText = $"已从白名单移除「{entry.Alias}」";
    }

    /// <summary>UI ToggleSwitch 调用：直接设置指定设备的自动接收开关（服务为唯一真源）。</summary>
    public void SetWhitelistAutoAccept(string fingerprint, bool autoAccept)
        => _service.SetWhitelistAutoAccept(fingerprint, autoAccept);

    // ---------- 黑名单 ----------

    [RelayCommand]
    private void AddBlacklistFromDiscovered()
    {
        if (SelectedDiscovered is null)
        {
            StatusText = "请先在上方选择一个已发现的设备";
            return;
        }
        _service.AddBlacklist(SelectedDiscovered.Fingerprint, SelectedDiscovered.Alias,
            SelectedDiscovered.DeviceModel, SelectedDiscovered.DeviceType);
        StatusText = $"已将「{SelectedDiscovered.Alias}」加入黑名单";
        SelectedDiscovered = null;
    }

    [RelayCommand]
    private void AddBlacklistManual()
    {
        var fp = NewFingerprint.Trim();
        if (fp.Length == 0)
        {
            StatusText = "请输入设备指纹";
            return;
        }
        _service.AddBlacklist(fp, string.IsNullOrWhiteSpace(NewAlias) ? "(未命名)" : NewAlias.Trim());
        StatusText = $"已将「{NewAlias}」加入黑名单";
        NewFingerprint = string.Empty;
        NewAlias = string.Empty;
    }

    [RelayCommand]
    private void RemoveBlacklist(DeviceListEntry? entry)
    {
        if (entry is null) return;
        _service.RemoveBlacklist(entry.Fingerprint);
        StatusText = $"已从黑名单移除「{entry.Alias}」";
    }
}
