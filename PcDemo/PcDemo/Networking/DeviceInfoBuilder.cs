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
            Protocol = s.Https ? ProtocolType.Https : ProtocolType.Http,
            Download = s.Download,
            Announce = true,
        };
    }
}
