// SendSessionState：发送端会话状态机
namespace PcDemo.Models;

public enum SendSessionState
{
    /// <summary>尚未开始（UI 已选设备与文件，等用户点击发送）。</summary>
    Idle,
    /// <summary>正在请求对方接受（prepare-upload 等待对方决策）。</summary>
    WaitingForReceiver,
    /// <summary>已被对方拒绝（prepare-upload 403）。</summary>
    Rejected,
    /// <summary>正在传输文件（逐个 upload）。</summary>
    InProgress,
    /// <summary>全部传输成功。</summary>
    Completed,
    /// <summary>用户取消（我们主动 cancel）。</summary>
    Cancelled,
    /// <summary>对方取消或拒绝个别文件（409 单槽等）。</summary>
    CancelledByPeer,
    /// <summary>未知错误导致失败。</summary>
    Failed,
}
