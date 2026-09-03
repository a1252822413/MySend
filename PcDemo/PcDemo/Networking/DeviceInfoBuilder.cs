// 本机设备信息构造器：根据 settings 构造 RegisterResponse/Info/AnnouncedMessage。
// 对应 app/lib/util/device_info.dart 的角色。
using PcDemo.Helpers;
using PcDemo.Models.Dto;
using PcDemo.Services;

namespace PcDemo.Networking;

public sealed class DeviceInfoBuilder : IDeviceInfoBuilder
{
    private readonly ISettingsService _settings;
    public DeviceInfoBuilder(ISettingsService settings) => _settings = settings;

    public RegisterResponseDtoV2 BuildRegisterResponse()
    {
        var s = _settings.Current;
        return new RegisterResponseDtoV2
        {
            Alias = s.Alias,
            Version = "2.2",
            DeviceModel = s.DeviceModel,
            DeviceType = s.DeviceType,
            Fingerprint = s.Fingerprint,
            Download = s.Download,
        };
    }

    public InfoResponseDtoV2 BuildInfoResponse()
    {
        var s = _settings.Current;
        return new InfoResponseDtoV2
        {
            Alias = s.Alias,
            Version = "2.2",
            DeviceModel = s.DeviceModel,
            DeviceType = s.DeviceType,
            Fingerprint = s.Fingerprint,
            Download = s.Download,
        };
    }

    public AnnouncedMessage BuildAnnouncedMessage()
    {
        var s = _settings.Current;
        return new AnnouncedMessage
        {
            Alias = s.Alias,
            Version = "2.2",
            DeviceModel = s.DeviceModel,
            DeviceType = s.DeviceType,
            Fingerprint = s.Fingerprint,
            Port = s.Port,
            // 公告必须与服务器实际能力一致：本机 Kestrel 仅监听明文 HTTP（LocalSendHttpServer 未配 TLS）。
            // 若按 s.Https 公告 https，对方会按 https 连接本机 → 握手失败 → prepare-upload 全部失败。
            Protocol = ProtocolType.Http,
            Download = s.Download,
            Announce = true,
        };
    }
}
