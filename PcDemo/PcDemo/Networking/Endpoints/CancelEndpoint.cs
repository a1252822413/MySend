// POST /api/localsend/v2/cancel?sessionId=
// 不做鉴权；始终 200 空 body。
// 仅当 sessionId + senderIp 都匹配本机会话时才真正中断，否则只记录（避免被恶意 cancel 打断他人）。
using Microsoft.AspNetCore.Http;
using PcDemo.Services;

namespace PcDemo.Networking.Endpoints;

public static class CancelEndpoint
{
    public const string Path = "/api/localsend/v2/cancel";

    public static IResult Handle(HttpContext ctx, IReceiveSessionManager sessions)
    {
        var q = ctx.Request.Query;
        var sessionId = q.TryGetValue("sessionId", out var s) ? s.ToString() : string.Empty;
        var senderIp = ctx.Connection.RemoteIpAddress?.ToString() ?? string.Empty;
        sessions.Cancel(sessionId, senderIp);
        return Results.StatusCode(200);
    }
}
