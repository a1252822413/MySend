// 接收会话状态机接口：由 HTTP endpoints 调用，由 ReceiveSessionManager 实现。
// 严格按协议 v2.2 行为返回 PrepareUploadResult。
using PcDemo.Models;
using PcDemo.Models.Dto;

namespace PcDemo.Services;

/// <summary>prepare-upload 处理结果。code=200 时 Response 非空；其他情况 Response 为 null，由端点拼 ErrorResponse。</summary>
public sealed class PrepareUploadResult
{
    public int StatusCode { get; init; }
    public PrepareUploadResponseDtoV2? Response { get; init; }
    public string? ErrorMessage { get; init; } // 非空时拼成 ErrorResponse.message
}

/// <summary>upload 处理结果。</summary>
public sealed class UploadResult
{
    public int StatusCode { get; init; }
    public string? ErrorMessage { get; init; }
}

public interface IReceiveSessionManager
{
    /// <summary>处理 POST /prepare-upload。返回状态码 + 响应体。
    /// 内部会异步等待 UI 决策（用户点接受/拒绝），完成后才返回。</summary>
    /// <param name="senderIp">发送方 IP（用于后续 upload 校验）。</param>
    /// <param name="request">请求体。</param>
    Task<PrepareUploadResult> HandlePrepareUploadAsync(string senderIp, PrepareUploadRequestDtoV2 request);

    /// <summary>UI 决策：接受指定 fileId 列表（生成 tokens），其余文件被拒绝。</summary>
    void Accept(string sessionId, IEnumerable<string> acceptedFileIds);

    /// <summary>UI 决策：拒绝当前 pending 会话。</summary>
    void Decline(string sessionId);

    /// <summary>处理 POST /upload：流式写盘（带进度上报与本机取消支持）。</summary>
    /// <param name="sessionId">会话 ID。</param>
    /// <param name="fileId">文件 ID。</param>
    /// <param name="token">upload token。</param>
    /// <param name="senderIp">发送方 IP，需与会话记录匹配。</param>
    /// <param name="body">HTTP 请求体流。</param>
    /// <param name="httpCtx">请求上下文（本机用户取消时 Abort 断开对方连接）。</param>
    Task<UploadResult> HandleUploadAsync(string sessionId, string fileId, string token, string senderIp, Stream body,
        Microsoft.AspNetCore.Http.HttpContext? httpCtx = null);

    /// <summary>处理 POST /cancel。始终返回成功，仅当 IP+sessionId 匹配才真取消。</summary>
    void Cancel(string sessionId, string senderIp);

    /// <summary>本机用户主动取消（中断写盘 + Abort 对方连接）。</summary>
    void CancelLocal(string sessionId);

    /// <summary>获取当前活动会话（用于调试/状态展示）。</summary>
    ReceiveSession? CurrentSession { get; }
}
