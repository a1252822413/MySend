// SettingsViewModel：alias/port/multicastGroup/destination/deviceModel/deviceType + 主题 + 开机自启。
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml;
using PcDemo.Models;
using PcDemo.Models.Dto;
using PcDemo.Networking;
using PcDemo.Services;
using Windows.ApplicationModel;

namespace PcDemo.ViewModels;

public partial class SettingsViewModel : ViewModelBase
{
    private readonly ISettingsService _settings;

    [ObservableProperty] private string _alias = string.Empty;
    [ObservableProperty] private int _port;
    [ObservableProperty] private string _multicastGroup = string.Empty;
    [ObservableProperty] private string _destination = string.Empty;
    [ObservableProperty] private string _deviceModel = string.Empty;
    [ObservableProperty] private DeviceType _deviceType = Models.Dto.DeviceType.Desktop;
    [ObservableProperty] private string _fingerprint = string.Empty;
    [ObservableProperty] private int _themeMode;           // 0=跟随系统 / 1=浅色 / 2=深色
    [ObservableProperty] private bool _httpsEnabled;       // 仅使用 HTTPS（监听 端口+1，公告 https + mTLS）
    [ObservableProperty] private bool _autoLaunchEnabled; // 开机自启
    [ObservableProperty] private string _autoLaunchInfo = string.Empty;
    [ObservableProperty] private string _pin = string.Empty; // 接收 PIN（空=不启用）
    [ObservableProperty] private bool _autoAcceptEnabled;    // 自动接收（官方 download 字段语义）

    [ObservableProperty] private string _saveStatus = string.Empty;

    /// <summary>防火墙入站放行状态文本（设置页「网络与防火墙」卡片）。</summary>
    [ObservableProperty] private string _firewallStatus = "未检测";

    /// <summary>正在检测防火墙（防止重复触发）。</summary>
    [ObservableProperty] private bool _isCheckingFirewall;

    /// <summary>设置页首次打开时自动检测一次。</summary>
    private bool _autoFirewallChecked;

    public SettingsViewModel(ISettingsService settings)
    {
        _settings = settings;
        LoadFromSettings();
        _ = LoadAutoLaunchAsync();
    }

    public void LoadFromSettings()
    {
        var s = _settings.Current;
        Alias = s.Alias;
        Port = s.Port;
        MulticastGroup = s.MulticastGroup;
        Destination = s.Destination;
        DeviceModel = s.DeviceModel;
        DeviceType = s.DeviceType ?? Models.Dto.DeviceType.Desktop;
        Fingerprint = s.Fingerprint;
        ThemeMode = s.ThemeMode;
        HttpsEnabled = s.Https;
        Pin = s.Pin;
        AutoAcceptEnabled = s.Download;
    }

    [RelayCommand]
    public async System.Threading.Tasks.Task SaveAsync()
    {
        _settings.Update(s =>
        {
            s.Alias = Alias?.Trim() is { Length: > 0 } a ? a : Environment.MachineName;
            s.Port = (ushort)Math.Clamp(Port, 1, 65535);
            s.MulticastGroup = string.IsNullOrWhiteSpace(MulticastGroup) ? "224.0.0.167" : MulticastGroup.Trim();
            s.Destination = string.IsNullOrWhiteSpace(Destination)
                ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) is var home && !string.IsNullOrEmpty(home)
                    ? System.IO.Path.Combine(home, "Downloads")
                    : Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
                : Destination.Trim();
            s.DeviceModel = string.IsNullOrWhiteSpace(DeviceModel) ? "Windows" : DeviceModel.Trim();
            s.DeviceType = DeviceType;
            s.ThemeMode = Math.Clamp(ThemeMode, 0, 2);
            s.Https = HttpsEnabled;
            s.Pin = Pin?.Trim() ?? string.Empty;
            s.Download = AutoAcceptEnabled;
        });

        // 主题即时切换
        ThemeApplier.Apply(_settings.Current.ThemeMode);

        // 开机自启同步
        await SyncAutoLaunchAsync();

        LoadFromSettings();
        SaveStatus = "已保存（端口/多播组等网络设置变更已即时生效）";
    }

    // ---------- 开机自启：MSIX StartupTask API ----------
    private const string StartupTaskId = "PcDemoStartup";

    private async System.Threading.Tasks.Task LoadAutoLaunchAsync()
    {
        try
        {
            var task = await StartupTask.GetAsync(StartupTaskId);
            AutoLaunchEnabled = task.State is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy;
            AutoLaunchInfo = task.State switch
            {
                StartupTaskState.Disabled => "未启用",
                StartupTaskState.DisabledByUser => "被用户禁用（请到「任务管理器 → 启动应用」重新启用）",
                StartupTaskState.Enabled => "已启用",
                StartupTaskState.EnabledByPolicy => "已启用（由策略强制）",
                StartupTaskState.DisabledByPolicy => "被策略阻止，无法启用",
                _ => task.State.ToString(),
            };
        }
        catch (Exception ex)
        {
            AutoLaunchInfo = $"获取失败：{ex.Message}";
        }
    }

    private async System.Threading.Tasks.Task SyncAutoLaunchAsync()
    {
        try
        {
            var task = await StartupTask.GetAsync(StartupTaskId);
            if (AutoLaunchEnabled)
            {
                var st = await task.RequestEnableAsync();
                AutoLaunchInfo = st switch
                {
                    StartupTaskState.Enabled => "已启用（保存生效）",
                    StartupTaskState.EnabledByPolicy => "已启用（由策略强制）",
                    StartupTaskState.DisabledByUser => "被用户禁用（请到「任务管理器 → 启动应用」启用）",
                    StartupTaskState.DisabledByPolicy => "被策略阻止，无法启用",
                    _ => $"未启用（状态={st}）",
                };
                AutoLaunchEnabled = st is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy;
            }
            else
            {
                task.Disable();
                AutoLaunchInfo = "未启用";
            }
        }
        catch (Exception ex)
        {
            AutoLaunchInfo = $"同步失败：{ex.Message}";
        }
    }

    // ---------- 防火墙诊断（设置页「网络与防火墙」卡片） ----------

    /// <summary>设置页首次加载时自动检测一次。</summary>
    public void EnsureAutoFirewallCheck()
    {
        if (_autoFirewallChecked) return;
        _autoFirewallChecked = true;
        CheckFirewallCommand.Execute(null);
    }

    /// <summary>检测当前监听端口的 Windows 防火墙入站放行状态（后台 netsh，不卡 UI）。</summary>
    [RelayCommand]
    private async Task CheckFirewallAsync()
    {
        if (IsCheckingFirewall) return;
        IsCheckingFirewall = true;
        FirewallStatus = "正在检测…";
        try { await DoCheckCoreAsync(); }
        finally { IsCheckingFirewall = false; }
    }

    private async Task DoCheckCoreAsync()
    {
        try
        {
            // UDP 多播端口 = 基端口；TCP 服务端口 = HTTPS-only 时 +1（实际监听口）
            var udpPort = (int)_settings.Current.Port;
            var tcpPort = EndpointConfig.ServicePort(_settings);
            var state = await Task.Run(() => FirewallHelper.CheckState(udpPort, tcpPort));
            FirewallStatus = state switch
            {
                FirewallState.Allowed => $"已放行：UDP {udpPort} / TCP {tcpPort} 入站规则",
                FirewallState.NotAllowed => $"未放行：TCP {tcpPort} 没有入站规则（手机可能连不上）",
                _ => $"未能确定 TCP {tcpPort} 的防火墙状态（可尝试点击下方添加规则）",
            };
        }
        catch (Exception ex)
        {
            FirewallStatus = $"检测失败：{ex.Message}";
        }
    }

    /// <summary>添加当前端口入站放行规则（触发 UAC，用户允许后生效）。</summary>
    [RelayCommand]
    private async Task AllowFirewallAsync()
    {
        if (IsCheckingFirewall) return;
        IsCheckingFirewall = true;
        var udpPort = (int)_settings.Current.Port;
        var tcpPort = EndpointConfig.ServicePort(_settings);
        FirewallStatus = "正在请求管理员授权…";
        try
        {
            var ok = await Task.Run(() => FirewallHelper.AddRules(udpPort, tcpPort));
            if (ok)
            {
                // 稍等规则落盘再复检，给出准确结论
                await Task.Delay(400);
                FirewallStatus = "正在复检…";
                await DoCheckCoreAsync();
            }
            else
            {
                FirewallStatus = "未放行：已在 UAC 弹窗中取消授权";
            }
        }
        catch (Exception ex)
        {
            FirewallStatus = $"添加失败：{ex.Message}";
        }
        finally
        {
            IsCheckingFirewall = false;
        }
    }
}
