// 已发现设备视图模型：用于 ReceivePage 设备列表展示。
using System.ComponentModel;
using System.Runtime.CompilerServices;
using PcDemo.Models.Dto;

namespace PcDemo.Models;

public sealed class Device : INotifyPropertyChanged
{
    /// <summary>设备指纹，用于唯一标识去重。</summary>
    public string Fingerprint { get; init; } = string.Empty;

    public string Alias { get; set; } = string.Empty;
    public string? DeviceModel { get; set; }
    public DeviceType? DeviceType { get; set; }
    public ushort Port { get; set; }
    public ProtocolType Protocol { get; set; } = ProtocolType.Http;
    public string Version { get; set; } = "2.2";
    public bool Download { get; set; }

    /// <summary>对方 HTTP 服务器地址（来自 UDP 公告的源 IP）。</summary>
    public string Ip { get; set; } = string.Empty;

    /// <summary>最近一次收到公告/注册的时间戳（UTC ticks）。</summary>
    public long LastSeenUtcTicks { get; set; } = DateTime.UtcNow.Ticks;

    /// <summary>是否在线（距 LastSeen 小于 50s = 在线）；集合不变更引用，不破坏选中态。</summary>
    public bool IsOnline => (DateTime.UtcNow - new DateTime(LastSeenUtcTicks, DateTimeKind.Utc)).TotalSeconds < 50;

    private bool _isPicked;
    /// <summary>发送页当前是否被选为目标设备（UI 选中高亮边框用）。</summary>
    public bool IsPicked
    {
        get => _isPicked;
        set { if (_isPicked != value) { _isPicked = value; OnPropertyChanged(nameof(IsPicked)); } }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>刷新 IsOnline 视觉（时间滚动时手动触发 UI 刷新）。</summary>
    public void RefreshOnlineState() => OnPropertyChanged(nameof(IsOnline));

    /// <summary>用新收到的消息就地更新字段（避免 Remove+Add 破坏 ListView 选中引用）。</summary>
    public void UpdateFrom(Device other)
    {
        if (ReferenceEquals(this, other)) return;
        Alias = other.Alias;
        Ip = other.Ip;
        Port = other.Port;
        DeviceModel = other.DeviceModel;
        DeviceType = other.DeviceType;
        Protocol = other.Protocol;
        Version = other.Version;
        Download = other.Download;
        LastSeenUtcTicks = other.LastSeenUtcTicks;
        OnPropertyChanged(nameof(Alias));
        OnPropertyChanged(nameof(Ip));
        OnPropertyChanged(nameof(Port));
        OnPropertyChanged(nameof(DeviceModel));
        OnPropertyChanged(nameof(DeviceType));
        OnPropertyChanged(nameof(LastSeenUtcTicks));
        OnPropertyChanged(nameof(IsOnline));
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
