// 接收会话状态：一个 prepare-upload 会话的状态机。
// 单槽约束：ReceiveSessionManager 同时只允许一个 Active/Pending 会话。
using Microsoft.AspNetCore.Http;
using PcDemo.Models.Dto;

namespace PcDemo.Models;

public enum ReceiveSessionStatus
{
    PendingDecision,  // 等待 UI 接受/拒绝
    Accepted,        // 已接受，等待 upload 请求
    InProgress,      // 正在接收文件
    Completed,        // 所有文件接收完毕
    Rejected,        // 用户拒绝
    Canceled,        // 被发送方取消
    Failed,
}

public sealed class ReceiveSession
{
    public string SessionId { get; init; } = string.Empty;

    /// <summary>发送方 IP，用于 upload 校验。</summary>
    public string SenderIp { get; init; } = string.Empty;

    /// <summary>发送方设备信息。</summary>
    public RegisterDtoV2 Sender { get; init; } = null!;

    /// <summary>会话内所有文件（fileId -> ReceiveFile）。</summary>
    public Dictionary<string, ReceiveFile> Files { get; init; } = new();

    public ReceiveSessionStatus Status { get; set; } = ReceiveSessionStatus.PendingDecision;

    /// <summary>会话创建时间，用于超时清理。</summary>
    public DateTime CreatedAtUtc { get; init; } = DateTime.UtcNow;

    /// <summary>本机用户主动取消的信号（中断写盘流）。</summary>
    public CancellationTokenSource Cts { get; } = new();

    /// <summary>当前 upload 请求的 HttpContext（本机取消时 Abort 断开对方连接）。</summary>
    public HttpContext? HttpContext { get; set; }

    /// <summary>聚合进度（UI 弹窗绑定），由 ReceiveSessionManager 在 dispatcher 上更新。</summary>
    public ReceiveProgress Progress { get; } = new();
}
