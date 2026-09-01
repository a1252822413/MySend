// HTTP server → UI 消息：会话结束（成功/失败/取消），用于 UI 状态展示与历史。
using PcDemo.Models;

namespace PcDemo.Messages;

public sealed class SessionFinishedMessage
{
    public ReceiveSession Session { get; init; } = null!;
}
