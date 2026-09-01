// 协议类型枚举（http/https），MVP 仅用 http，但保留 https 以兼容外部解析。
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PcDemo.Models.Dto;

[JsonConverter(typeof(ProtocolTypeConverter))]
public enum ProtocolType
{
    Http,
    Https,
}

public sealed class ProtocolTypeConverter : JsonConverter<ProtocolType>
{
    public override ProtocolType Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var value = reader.GetString();
        return value switch
        {
            "http" => ProtocolType.Http,
            "https" => ProtocolType.Https,
            _ => ProtocolType.Http, // 默认 http
        };
    }

    public override void Write(Utf8JsonWriter writer, ProtocolType value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(value == ProtocolType.Https ? "https" : "http");
    }
}
