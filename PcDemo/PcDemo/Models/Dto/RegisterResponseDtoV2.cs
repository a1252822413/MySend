// 设备注册响应 DTO，对应 dto_v2.rs RegisterResponseDtoV2。
// 也可作为 GET /info 的响应（字段集相同，复用 InfoResponseDtoV2）。
namespace PcDemo.Models.Dto;

public sealed class RegisterResponseDtoV2
{
    public string Alias { get; set; } = string.Empty;
    public string Version { get; set; } = "2.2";
    public string? DeviceModel { get; set; }
    public DeviceType? DeviceType { get; set; }
    public string Fingerprint { get; set; } = string.Empty;
    public bool Download { get; set; }
}
