// UDP 多播发现消息体，对应 multicast/mod.rs MulticastMessageV2。
// AnnouncedMessage 是此结构 + announce: true 标志位。
namespace PcDemo.Models.Dto;

public sealed class MulticastMessageV2
{
    public string Alias { get; set; } = string.Empty;
    public string Version { get; set; } = "2.2";
    public string? DeviceModel { get; set; }
    public DeviceType? DeviceType { get; set; }
    public string Fingerprint { get; set; } = string.Empty;
    public ushort Port { get; set; }
    public ProtocolType Protocol { get; set; } = ProtocolType.Http;
    public bool Download { get; set; }
}
