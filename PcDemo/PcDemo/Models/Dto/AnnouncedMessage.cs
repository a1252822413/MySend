// 多播发送时实际使用的消息：MulticastMessageV2 字段 + announce: true 标志位。
// 对应 multicast/mod.rs AnnouncedMessage（#[serde(flatten)] message + announce: bool）。
// 接收时仅解析 MulticastMessageV2 即可，但本类用于发送时序列化。
namespace PcDemo.Models.Dto;

public sealed class AnnouncedMessage
{
    public string Alias { get; set; } = string.Empty;
    public string Version { get; set; } = "2.2";
    public string? DeviceModel { get; set; }
    public DeviceType? DeviceType { get; set; }
    public string Fingerprint { get; set; } = string.Empty;
    public ushort Port { get; set; }
    public ProtocolType Protocol { get; set; } = ProtocolType.Http;
    public bool Download { get; set; }
    public bool Announce { get; set; } = true;
}
