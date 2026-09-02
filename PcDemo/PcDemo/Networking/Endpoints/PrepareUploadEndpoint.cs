// POST /api/localsend/v2/prepare-upload
// 发送方请求接收文件；接收端生成 sessionId + tokens，等待 UI 决策。
// 严格按协议 v2.2 状态码矩阵返回：
//   - 请求体解析失败 / files 为空 → 400 "No files provided"
//   - 已有会话占用单槽 → 409 "Blocked by another session"
//   - 用户拒绝 → 403 "Rejected"
//   - 发送方等待期取消 → 403 "Cancelled by sender"
//   - 接受空集合 → 204 NoContent
//   - 接受 → 200 + { sessionId, files: { fileId: token } }
using Microsoft.AspNetCore.Http;
using PcDemo.Helpers;
using PcDemo.Models.Dto;
using PcDemo.Services;

namespace PcDemo.Networking.Endpoints;

public static class PrepareUploadEndpoint
{
    public const string Path = "/api/localsend/v2/prepare-upload";

    public static async Task<IResult> Handle(
        HttpContext ctx,
        IReceiveSessionManager sessions,
        ISettingsService settings)
    {
        PrepareUploadRequestDtoV2? req;
        try
        {
            req = await System.Text.Json.JsonSerializer
                .DeserializeAsync<PrepareUploadRequestDtoV2>(ctx.Request.Body, JsonOptions.Default);
        }
        catch
        {
            return Results.Json(new ErrorResponse { Message = "No files provided" },
                JsonOptions.Default, contentType: "application/json", statusCode: 400);
        }

        if (req is null || req.Files is null || req.Files.Count == 0)
        {
            return Results.Json(new ErrorResponse { Message = "No files provided" },
                JsonOptions.Default, contentType: "application/json", statusCode: 400);
        }

        // PIN 校验：接收端开启了 PIN（settings.Pin 非空）时，请求必须带 ?pin= 精确匹配 → 否则 401
        var expectedPin = settings.Current.Pin;
        if (!string.IsNullOrWhiteSpace(expectedPin))
        {
            var gotPin = ctx.Request.Query["pin"].ToString();
            if (!string.Equals(gotPin, expectedPin, StringComparison.Ordinal))
            {
                App.LogDiag("[PrepareUpload] invalid or missing pin");
                return Results.Json(new ErrorResponse { Message = "Invalid PIN" },
                    JsonOptions.Default, contentType: "application/json", statusCode: 401);
            }
        }

        // 磁盘空间预检：目标盘剩余空间不足时提前拒绝（507），避免传一半失败
        try
        {
            ulong totalBytes = 0;
            foreach (var f in req.Files.Values) totalBytes += f.Size;
            var drive = new DriveInfo(System.IO.Path.GetPathRoot(settings.Current.Destination)!);
            if (drive.IsReady && totalBytes > (ulong)Math.Max(0L, drive.AvailableFreeSpace))
            {
                App.LogDiag($"[PrepareUpload] insufficient disk space: need {totalBytes}, free {drive.AvailableFreeSpace}");
                return Results.Json(new ErrorResponse { Message = "Insufficient disk space" },
                    JsonOptions.Default, contentType: "application/json", statusCode: 507);
            }
        }
        catch { /* 预检失败不阻断正常流程 */ }

        var senderIp = ctx.Connection.RemoteIpAddress?.ToString() ?? string.Empty;
        var result = await sessions.HandlePrepareUploadAsync(senderIp, req);

        if (result.ErrorMessage is not null)
        {
            return Results.Json(new ErrorResponse { Message = result.ErrorMessage },
                JsonOptions.Default, contentType: "application/json", statusCode: result.StatusCode);
        }

        if (result.Response is null)
        {
            // 204 No Content（用户 Accept 空集合）
            return Results.StatusCode(result.StatusCode == 0 ? 204 : result.StatusCode);
        }

        return Results.Json(result.Response, JsonOptions.Default, contentType: "application/json",
            statusCode: result.StatusCode == 0 ? 200 : result.StatusCode);
    }
}
