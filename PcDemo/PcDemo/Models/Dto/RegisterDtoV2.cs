// 设备注册请求 DTO，对应 dto_v2.rs RegisterDtoV2。
// POST /api/localsend/v2/register 时发送方携带此结构给接收端。
namespace PcDemo.Models.Dto;

public sealed class RegisterDtoV2
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
