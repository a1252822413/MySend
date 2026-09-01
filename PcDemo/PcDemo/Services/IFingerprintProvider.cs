// 本机设备信息构造器接口：根据 settings 构造 RegisterResponse/Info 响应。
// 用接口便于端点注入与测试替换。
using PcDemo.Models.Dto;

namespace PcDemo.Services;

public interface IDeviceInfoBuilder
{
    RegisterResponseDtoV2 BuildRegisterResponse();
    InfoResponseDtoV2 BuildInfoResponse();
    AnnouncedMessage BuildAnnouncedMessage();
}
