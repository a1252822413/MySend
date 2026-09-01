// POST /api/localsend/v2/upload?sessionId=&fileId=&token=
// 校验 sessionId/fileId/token 三参（缺一即 400 Missing parameters）；
// 校验失败 → 403 "Invalid token or IP address"；
// 通过则流式写盘 → 200 空 / 500 写盘失败 / 422 checksum mismatch（MVP 不做校验）。
using Microsoft.AspNetCore.Http;
using PcDemo.Helpers;
using PcDemo.Models.Dto;
using PcDemo.Services;

namespace PcDemo.Networking.Endpoints;

public static class UploadEndpoint
{
    public const string Path = "/api/localsend/v2/upload";

    public static async Task<IResult> Handle(
        HttpContext ctx,
        IReceiveSessionManager sessions)
    {
        var q = ctx.Request.Query;
        var sessionId = q.TryGetValue("sessionId", out var s) ? s.ToString() : null;
        var fileId = q.TryGetValue("fileId", out var f) ? f.ToString() : null;
        var token = q.TryGetValue("token", out var t) ? t.ToString() : null;

        if (string.IsNullOrEmpty(sessionId) || string.IsNullOrEmpty(fileId) || string.IsNullOrEmpty(token))
        {
            return Results.Json(new ErrorResponse { Message = "Missing parameters" },
                JsonOptions.Default, contentType: "application/json", statusCode: 400);
        }

        var senderIp = ctx.Connection.RemoteIpAddress?.ToString() ?? string.Empty;
        var len = ctx.Request.ContentLength ?? -1;
        App.LogDiag($"[Upload] 入站 sessionId={sessionId![..8]} fileId={fileId} len={len} senderIp={senderIp}");
        var result = await sessions.HandleUploadAsync(sessionId!, fileId!, token!, senderIp, ctx.Request.Body, ctx);
        App.LogDiag($"[Upload] 处理完成 status={result.StatusCode} err={result.ErrorMessage ?? "none"}");

        if (result.ErrorMessage is not null)
        {
            return Results.Json(new ErrorResponse { Message = result.ErrorMessage },
                JsonOptions.Default, contentType: "application/json", statusCode: result.StatusCode);
        }

        return Results.StatusCode(result.StatusCode == 0 ? 200 : result.StatusCode);
    }
}
