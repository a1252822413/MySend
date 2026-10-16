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

    /// <summary>逐文件明细（v2.2+ 记录；旧记录为 null → 详情页显示"无逐文件明细"）。</summary>
    public List<TransferFileDetail>? Files { get; init; }

    /// <summary>是否有逐文件明细可查看。</summary>
    [JsonIgnore] public bool HasDetails => Files is { Count: > 0 };

    // ---------- UI 绑定计算属性 ----------
    // 字形码点已用 fontTools 校验过存在于 C:/Windows/Fonts/SegoeIcons.ttf：
    // E896=Download（接收）、E724=Send（发送）。注意 E798 并不存在（会渲染成空心方框），
    // 之前这里的发送图标就是 E798，截图里那条"发往"记录的图标因此是个空框。
    [JsonIgnore] public string IconGlyph => Direction == TransferDirection.Receive ? "\uE896" : "\uE724";
    [JsonIgnore] public string DirectionText => Direction == TransferDirection.Receive ? "接收" : "发送";
    [JsonIgnore] public string PeerText => Direction == TransferDirection.Receive ? $"来自 {PeerName}" : $"发往 {PeerName}";
    [JsonIgnore] public string StatusText => Result switch
    {
        TransferResult.Success => "成功",
        TransferResult.Failed => "失败",
        _ => "已取消",
    };
    /// <summary>状态 chip 的前景色（深色字）：走系统语义色，深浅主题自适应。</summary>
    [JsonIgnore] public Brush StatusForegroundBrush => ThemeBrushHelper.Get(Result switch
    {
        TransferResult.Success => "SystemFillColorSuccessBrush",
        TransferResult.Failed => "SystemFillColorCriticalBrush",
        _ => "SystemFillColorCautionBrush",
    });

    /// <summary>状态 chip 的背景色（低饱和浅底）：与 StatusForegroundBrush 配对。</summary>
    [JsonIgnore] public Brush StatusBackgroundBrush => ThemeBrushHelper.Get(Result switch
    {
        TransferResult.Success => "SystemFillColorSuccessBackgroundBrush",
        TransferResult.Failed => "SystemFillColorCriticalBackgroundBrush",
        _ => "SystemFillColorCautionBackgroundBrush",
    });
    [JsonIgnore] public string SizeText => ByteFormatter.Format(TotalBytes);
    [JsonIgnore] public string FilesText => $"{FileCount} 个文件";
    [JsonIgnore] public string TimeText => FinishedAt.ToString("MM-dd HH:mm");

    /// <summary>接收成功的条目显示"打开位置"按钮。</summary>
    [JsonIgnore] public Microsoft.UI.Xaml.Visibility OpenFolderVisibility =>
        Direction == TransferDirection.Receive && Result == TransferResult.Success
            ? Microsoft.UI.Xaml.Visibility.Visible
            : Microsoft.UI.Xaml.Visibility.Collapsed;
}
