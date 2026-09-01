// 设备类型枚举，对应 localsend 协议 deviceType 字段（小写字符串）。
// 协议 7.1 规定：未知值必须降级为 desktop。
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PcDemo.Models.Dto;

[JsonConverter(typeof(DeviceTypeConverter))]
public enum DeviceType
{
    Mobile,
    Desktop,
    Web,
    Headless,
    Server,
}

/// <summary>
/// 将 DeviceType 在 JSON 中序列化为小写字符串（mobile/desktop/web/headless/server）。
/// 反序列化时未知值降级为 Desktop（协议 7.1 强制要求）。
/// </summary>
public sealed class DeviceTypeConverter : JsonConverter<DeviceType>
{
    private const string Mobile = "mobile";
    private const string Desktop = "desktop";
    private const string Web = "web";
    private const string Headless = "headless";
    private const string Server = "server";

    public override DeviceType Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var value = reader.GetString();
        return value switch
        {
            Mobile => DeviceType.Mobile,
            Desktop => DeviceType.Desktop,
            Web => DeviceType.Web,
            Headless => DeviceType.Headless,
            Server => DeviceType.Server,
            _ => DeviceType.Desktop, // 协议 7.1：未知值降级为 desktop
        };
    }

    public override void Write(Utf8JsonWriter writer, DeviceType value, JsonSerializerOptions options)
    {
        var str = value switch
        {
            DeviceType.Mobile => Mobile,
            DeviceType.Desktop => Desktop,
            DeviceType.Web => Web,
            DeviceType.Headless => Headless,
            DeviceType.Server => Server,
            _ => Desktop,
        };
        writer.WriteStringValue(str);
    }
}
