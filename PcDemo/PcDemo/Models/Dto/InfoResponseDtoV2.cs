// GET /api/localsend/v2/info 响应，对应 dto_v2.rs InfoResponseDtoV2。
// 字段集与 RegisterResponseDtoV2 一致，独立保留以便后续单独扩展。
namespace PcDemo.Models.Dto;

public sealed class InfoResponseDtoV2
{
    public string Alias { get; set; } = string.Empty;
    public string Version { get; set; } = "2.2";
    public string? DeviceModel { get; set; }
    public DeviceType? DeviceType { get; set; }
    public string Fingerprint { get; set; } = string.Empty;
    public bool Download { get; set; }
    /// <summary>官方 LocalSend App：true 时只接受 HTTPS 请求。</summary>
    public bool HttpsOnly { get; set; }
    /// <summary>对方在 HTTP(S) 层监听的实际端口（公告端口 + HTTPS-only 会 +1）。</summary>
    public int Port { get; set; }
    /// <summary>对方声明的协议：http / https。</summary>
    public ProtocolType Protocol { get; set; }
}
