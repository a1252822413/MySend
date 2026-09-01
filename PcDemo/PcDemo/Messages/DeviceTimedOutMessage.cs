// DeviceRegistry 周期清理 → UI 消息：某设备超时下线。
namespace PcDemo.Messages;

public sealed class DeviceTimedOutMessage
{
    public string Fingerprint { get; init; } = string.Empty;
}
