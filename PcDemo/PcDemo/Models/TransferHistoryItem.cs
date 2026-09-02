// TransferHistoryItem：一条传输历史记录（JSON 持久化到 LocalState/transfer-history.json）。
// 计算属性（图标/颜色/格式化文本）供 HistoryPage DataTemplate 直接绑定，均不序列化。
using System.Text.Json.Serialization;
using Microsoft.UI.Xaml.Media;
using PcDemo.Converters;

namespace PcDemo.Models;

public enum TransferDirection { Send, Receive }

public enum TransferResult { Success, Failed, Canceled }

public sealed class TransferHistoryItem
{
    public TransferDirection Direction { get; init; }
    public string PeerName { get; init; } = string.Empty;
    public int FileCount { get; init; }
    public long TotalBytes { get; init; }
    public TransferResult Result { get; init; }
    public DateTime FinishedAt { get; init; }

    /// <summary>接收 = 保存目录（用于"打开文件夹"）；发送 = null。</summary>
    public string? DestinationPath { get; init; }

    /// <summary>单文件传输时的文件名（多文件为 null）。</summary>
    public string? FirstFileName { get; init; }

    // ---------- UI 绑定计算属性 ----------
    [JsonIgnore] public string IconGlyph => Direction == TransferDirection.Receive ? "\uE896" : "\uE798";
    [JsonIgnore] public string DirectionText => Direction == TransferDirection.Receive ? "接收" : "发送";
    [JsonIgnore] public string PeerText => Direction == TransferDirection.Receive ? $"来自 {PeerName}" : $"发往 {PeerName}";
    [JsonIgnore] public string StatusText => Result switch
    {
        TransferResult.Success => "成功",
        TransferResult.Failed => "失败",
        _ => "已取消",
    };
    [JsonIgnore] public Brush StatusBrush => Result switch
    {
        TransferResult.Success => new SolidColorBrush(Windows.UI.Color.FromArgb(255, 63, 182, 104)),
        TransferResult.Failed => new SolidColorBrush(Windows.UI.Color.FromArgb(255, 224, 90, 79)),
        _ => new SolidColorBrush(Windows.UI.Color.FromArgb(255, 232, 163, 61)),
    };
    [JsonIgnore] public string SizeText => ByteFormatter.Format(TotalBytes);
    [JsonIgnore] public string FilesText => $"{FileCount} 个文件";
    [JsonIgnore] public string TimeText => FinishedAt.ToString("MM-dd HH:mm");

    /// <summary>接收成功的条目显示"打开位置"按钮。</summary>
    [JsonIgnore] public Microsoft.UI.Xaml.Visibility OpenFolderVisibility =>
        Direction == TransferDirection.Receive && Result == TransferResult.Success
            ? Microsoft.UI.Xaml.Visibility.Visible
            : Microsoft.UI.Xaml.Visibility.Collapsed;
}
