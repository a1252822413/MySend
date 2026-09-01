// HTTP server → UI 消息：收到 prepare-upload，请求 UI 弹对话框让用户授权。
using PcDemo.Models;

namespace PcDemo.Messages;

public sealed class PrepareUploadRequestedMessage
{
    public ReceiveSession Session { get; init; } = null!;

    /// <summary>UI 决策完成后回调此完成源，让 prepare-upload 端点返回响应。</summary>
    public TaskCompletionSource<PrepareUploadDecision> Decision { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
}

/// <summary>UI 决策结果：接受哪些 fileId（若为空集则返回 204 NoContent）；或拒绝。</summary>
public sealed class PrepareUploadDecision
{
    public bool Accepted { get; init; }
    public IReadOnlyList<string> AcceptedFileIds { get; init; } = Array.Empty<string>();
}
