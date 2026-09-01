// GET /api/localsend/v2/info
// 返回本机设备信息。无鉴权。
using Microsoft.AspNetCore.Http;
using PcDemo.Helpers;
using PcDemo.Services;

namespace PcDemo.Networking.Endpoints;

public static class InfoEndpoint
{
    public const string Path = "/api/localsend/v2/info";

    public static IResult Handle(IDeviceInfoBuilder info)
        => Results.Json(info.BuildInfoResponse(), JsonOptions.Default);
}
