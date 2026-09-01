// ReceiveProgress：接收会话的聚合进度（UI 弹窗绑定），由 ReceiveSessionManager 在 dispatcher 上更新。
using CommunityToolkit.Mvvm.ComponentModel;

namespace PcDemo.Models;

public partial class ReceiveProgress : ObservableObject
{
    /// <summary>会话文件总数（接受后的集合）。</summary>
    [ObservableProperty] private int _totalFiles;

    /// <summary>已完成（写盘成功）文件数。</summary>
    [ObservableProperty] private int _completedFiles;

    /// <summary>会话总大小（字节）。</summary>
    [ObservableProperty] private long _totalBytes;

    /// <summary>已接收字节（累计）。</summary>
    [ObservableProperty] private long _receivedBytes;

    /// <summary>传输速度（字节/秒，EMA 平滑）。</summary>
    [ObservableProperty] private long _speedBytesPerSecond;

    /// <summary>预计剩余秒数。</summary>
    [ObservableProperty] private double _etaSeconds;

    /// <summary>ProgressRing 是否转圈模式（等待下一个文件时 true）。</summary>
    [ObservableProperty] private bool _isIndeterminate = true;

    /// <summary>当前阶段文字（等待/正在接收 xx/接收完成）。</summary>
    [ObservableProperty] private string _phaseText = "等待对方发送…";

    /// <summary>会话是否已全部接收完成（进度对话框据此切换为「打开文件夹/关闭」完成态）。</summary>
    [ObservableProperty] private bool _isCompleted;

    /// <summary>总进度 0.0~1.0。</summary>
    public double Progress => TotalBytes == 0 ? 0.0 : Math.Clamp((double)ReceivedBytes / TotalBytes, 0.0, 1.0);
}
