// 共享的 JSON 序列化选项，所有协议序列化/反序列化都用此单例。
// camelCase 命名策略对齐 localsend 协议；空值不写入；包含自定义枚举 converter。
using System.Text.Json;
using System.Text.Json.Serialization;
using PcDemo.Models.Dto;

namespace PcDemo.Helpers;

public static class JsonOptions
{
    public static readonly JsonSerializerOptions Default = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
        WriteIndented = false,
        // DeviceType / ProtocolType 通过 [JsonConverter] 特性自动注册 converter，
        // 此处无需手动加，但显式注册也无害且更直观：
        Converters =
        {
            new DeviceTypeConverter(),
            new ProtocolTypeConverter(),
        },
    };
}
