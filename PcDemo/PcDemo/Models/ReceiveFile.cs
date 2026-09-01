// 单文件接收状态：sessionId 内某个 fileId 的状态机。
using PcDemo.Models.Dto;

namespace PcDemo.Models;

public enum ReceiveFileStatus
{
    Pending,      // 等待对方上传
    InProgress,   // 正在写入
    Completed,    // 成功
    Failed,       // 写入失败
    Canceled,     // 会话被取消
}

public sealed class ReceiveFile
{
    public string FileId { get; init; } = string.Empty;
    public string Token { get; set; } = string.Empty;
    public FileDto Metadata { get; init; } = null!;

    /// <summary>最终落盘的绝对路径（接收时确定）。</summary>
    public string? SavedPath { get; set; }

    /// <summary>已接收字节数（用于进度上报）。</summary>
    public ulong BytesReceived { get; set; }

    public ReceiveFileStatus Status { get; set; } = ReceiveFileStatus.Pending;

    /// <summary>失败原因（写盘失败/SHA 校验失败时填写）。</summary>
    public string? Error { get; set; }
}
