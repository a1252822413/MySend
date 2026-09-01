// 多播线程 → UI 消息：收到一个设备公告，需在 UI 线程更新设备列表。
using PcDemo.Models.Dto;

namespace PcDemo.Messages;

public sealed class DeviceDiscoveredMessage
{
    public string Ip { get; init; } = string.Empty;
    public MulticastMessageV2 Message { get; init; } = null!;
}
