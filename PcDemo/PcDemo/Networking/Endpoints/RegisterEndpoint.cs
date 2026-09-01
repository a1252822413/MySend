// POST /api/localsend/v2/register
// 接收对方注册请求，返回本机设备信息（200 + RegisterResponseDtoV2）。
// 不做 PIN/证书校验（HTTP MVP 模式）。可顺便把对方设备登记到 DeviceRegistry。
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Extensions;
using PcDemo.Helpers;
using PcDemo.Models.Dto;
using PcDemo.Services;

namespace PcDemo.Networking.Endpoints;

public static class RegisterEndpoint
{
    public const string Path = "/api/localsend/v2/register";

    public static async Task<IResult> Handle(
        HttpContext ctx,
        IDeviceInfoBuilder info,
        IDeviceRegistry devices)
    {
        // 解析对方发来的 RegisterDtoV2，登记到设备列表（便于 UI 展示）
        RegisterDtoV2? req = null;
        if (ctx.Request.ContentLength is > 0)
        {
            try
            {
                req = await System.Text.Json.JsonSerializer.DeserializeAsync<RegisterDtoV2>(ctx.Request.Body, JsonOptions.Default);
            }
            catch
            {
                // 解析失败忽略：仍返回本机 info，保持兼容
            }
        }

        if (req is not null)
        {
            var ip = ctx.Connection.RemoteIpAddress?.ToString() ?? string.Empty;
            devices.Upsert(
                ip: ip,
                alias: req.Alias,
                deviceModel: req.DeviceModel,
                deviceType: req.DeviceType,
                fingerprint: req.Fingerprint,
                port: req.Port,
                protocol: req.Protocol,
                version: req.Version,
                download: req.Download);
        }

        return Results.Json(info.BuildRegisterResponse(), JsonOptions.Default);
    }
}
