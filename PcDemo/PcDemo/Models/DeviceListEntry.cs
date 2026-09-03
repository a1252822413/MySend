// 设备名单条目模型：白名单与黑名单共用同一结构。
// 白名单：AutoAccept 控制该设备 prepare-upload 是否跳过确认弹窗直接接收；
// 黑名单：AutoAccept 恒 false，PrepareUpload 端点直接返回 403 拒绝。
// 继承 ObservableObject：原位更新（SyncList 修改别名/型号/AutoAccept）时 UI 绑定能刷新。
using CommunityToolkit.Mvvm.ComponentModel;
using PcDemo.Models.Dto;

namespace PcDemo.Models;

public sealed class DeviceListEntry : ObservableObject
{
    private string _fingerprint = string.Empty;
    private string _alias = string.Empty;
    private string? _deviceModel;
    private DeviceType? _deviceType;
    private DateTime _addedAtUtc = DateTime.UtcNow;
    private bool _autoAccept;

    /// <summary>对方设备指纹（主键，跨重启稳定）。</summary>
    public string Fingerprint { get => _fingerprint; set => SetProperty(ref _fingerprint, value); }

    /// <summary>对方设备别名（仅用于 UI 展示，可改）。</summary>
    public string Alias { get => _alias; set => SetProperty(ref _alias, value); }

    /// <summary>对方设备型号（可选，便于在管理页识别）。</summary>
    public string? DeviceModel { get => _deviceModel; set => SetProperty(ref _deviceModel, value); }

    /// <summary>对方设备类型（可选）。</summary>
    public DeviceType? DeviceType { get => _deviceType; set => SetProperty(ref _deviceType, value); }

    /// <summary>首次加入名单的时间（UTC）。</summary>
    public DateTime AddedAtUtc { get => _addedAtUtc; set => SetProperty(ref _addedAtUtc, value); }

    /// <summary>仅白名单条目有效：是否对该设备自动接收（跳过 UI 决策直接 Accept 全部文件）。
    /// 黑名单条目恒 false（黑名单语义是拒绝，不存在自动接收）。</summary>
    public bool AutoAccept { get => _autoAccept; set => SetProperty(ref _autoAccept, value); }
}
