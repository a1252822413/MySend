// 应用设置项持久化模型（settings.json 反序列化目标）。
// 字段对齐 app/lib/model/state/settings_state.dart 的 MVP 子集；其余字段后续阶段补。
using PcDemo.Models.Dto;

namespace PcDemo.Models;

public sealed class AppSettings
{
    /// <summary>本机显示别名。默认主机名。</summary>
    public string Alias { get; set; } = Environment.MachineName;

    /// <summary>HTTP/UDP 服务端口。默认 53317。</summary>
    public ushort Port { get; set; } = 53317;

    /// <summary>多播组 IPv4。默认 224.0.0.167。</summary>
    public string MulticastGroup { get; set; } = "224.0.0.167";

    /// <summary>接收文件保存目录。默认 Downloads。</summary>
    public string Destination { get; set; } =
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) is var home && !string.IsNullOrEmpty(home)
            ? System.IO.Path.Combine(home, "Downloads")
            : Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    /// <summary>设备模型字符串，作为公告/注册响应的 deviceModel。</summary>
    public string DeviceModel { get; set; } = "Windows";

    /// <summary>设备类型枚举，作为公告/注册响应的 deviceType。</summary>
    public DeviceType? DeviceType { get; set; } = Models.Dto.DeviceType.Desktop;

    /// <summary>是否使用 HTTPS。MVP 固定 false。</summary>
    public bool Https { get; set; } = false;

    /// <summary>本机设备指纹（HTTP 模式下随机字符串；HTTPS 模式下应为证书 SHA-256）。</summary>
    /// <remarks>每次设置变更或新设备首次启动时生成一次并持久化。</remarks>
    public string Fingerprint { get; set; } = string.Empty;

    /// <summary>是否支持 Download API。MVP 固定 false。</summary>
    public bool Download { get; set; } = false;

    /// <summary>主题偏好：0=跟随系统（默认）/1=浅色/2=深色。</summary>
    public int ThemeMode { get; set; } = 0;

    /// <summary>接收 PIN 码。空 = 不启用；非空时对方 prepare-upload 必须带 ?pin= 精确匹配。</summary>
    public string Pin { get; set; } = string.Empty;
}
