// SettingsViewModel：alias/port/multicastGroup/destination/deviceModel/deviceType + 主题 + 开机自启。
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml;
using PcDemo.Models;
using PcDemo.Models.Dto;
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
    [ObservableProperty] private bool _autoLaunchEnabled; // 开机自启
    [ObservableProperty] private string _autoLaunchInfo = string.Empty;

    [ObservableProperty] private string _saveStatus = string.Empty;

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
        });

        // 主题即时切换
        ThemeApplier.Apply(_settings.Current.ThemeMode);

        // 开机自启同步
        await SyncAutoLaunchAsync();

        LoadFromSettings();
        SaveStatus = "已保存（端口/多播组变更需重启应用）";
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
}
