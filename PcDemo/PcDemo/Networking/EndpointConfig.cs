// 对外服务端点计算辅助。
// settings.Port = UDP 多播端口 = 服务端口（默认 53317）。UDP 多播(TCP 之外) 恒走 53317；
// 未启用 HTTPS 时该端口提供明文 HTTP；启用 HTTPS 时同一端口 53317 改以 TLS(加密) 提供。
// 说明：同一 TCP 端口无法同时跑 HTTP 与 HTTPS，故启用 HTTPS 后 53317 即提供加密传输，
// 公告同步改为 https（手机经 https 连本机实现加密）。
using PcDemo.Models.Dto;
using PcDemo.Services;

namespace PcDemo.Networking;

internal static class EndpointConfig
{
    /// <summary>是否启用 HTTPS（加密传输，监听在 服务端口 上）。</summary>
    public static bool HttpsEnabled(ISettingsService s) => s.Current.Https;

    /// <summary>服务端口（恒 = Port，默认 53317）。</summary>
    public static int ServicePort(ISettingsService s) => s.Current.Port;

    /// <summary>对外公告/服务协议：启用 HTTPS → https（加密），否则 http。</summary>
    public static ProtocolType ServiceProtocol(ISettingsService s)
        => HttpsEnabled(s) ? ProtocolType.Https : ProtocolType.Http;
}
