// SendSession：一次完整发送会话（目标设备 + 文件列表 + 状态 + 总体进度）。
using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;

namespace PcDemo.Models;

public partial class SendSession : ObservableObject
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");

    /// <summary>目标设备。</summary>
    public Device Target { get; set; } = null!;

    /// <summary>准备上传时对方返回的 sessionId。</summary>
    public string? RemoteSessionId { get; set; }

    /// <summary>准备上传时对方返回的 {fileId → token} 字典（只含接受的文件）。</summary>
    public IReadOnlyDictionary<string, string>? AcceptedTokens { get; set; }

    /// <summary>待发送文件。</summary>
    public ObservableCollection<SendFileItem> Files { get; } = new();

    [ObservableProperty] private SendSessionState _state = SendSessionState.Idle;
    [ObservableProperty] private string? _errorMessage;

    /// <summary>已发送字节（累计所有文件）。</summary>
    [ObservableProperty] private long _totalBytesSent;

    /// <summary>当前传输速度（字节/秒，EMA 平滑；0 = 未在传输）。</summary>
    [ObservableProperty] private long _speedBytesPerSecond;

    /// <summary>预计剩余秒数（基于 EMA 速度；0 = 未知）。</summary>
    [ObservableProperty] private double _etaSeconds;

    /// <summary>总大小（所有文件）。</summary>
    public long TotalBytes => Files.Sum(f => f.Size);

    /// <summary>已完成（成功）的文件数。</summary>
    public int CompletedFiles => Files.Count(f => f.Status == SendFileStatus.Done);

    /// <summary>接受的文件数（AcceptedTokens 有键的）。</summary>
    public int AcceptedFiles => AcceptedTokens?.Count ?? 0;

    /// <summary>总进度 0.0~1.0。</summary>
    public double Progress
    {
        get
        {
            var total = TotalBytes;
            return total == 0 ? 0.0 : Math.Clamp((double)TotalBytesSent / total, 0.0, 1.0);
        }
    }
}
