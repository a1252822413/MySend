// TransferFileDetail：一条传输历史中单个文件的明细快照（接收/发送会话结束时的逐文件状态）。
// 随 TransferHistoryItem.Files 持久化到 transfer-history.json；向后兼容：旧记录无此字段（null）。
using System.Text.Json.Serialization;
using Microsoft.UI.Xaml.Media;
using PcDemo.Converters;

namespace PcDemo.Models;

/// <summary>单个文件的结果。</summary>
public enum FileDetailResult
{
    Success,
    Failed,
    Canceled,
    Skipped, // 未开始/未接受/会话中断未轮到
}

public sealed class TransferFileDetail
{
    /// <summary>文件名或相对路径（目录传输时含 '/' 的子路径，如 sub/img.png）。</summary>
    public string FileName { get; init; } = string.Empty;

    /// <summary>文件大小（字节）。</summary>
    public long Size { get; init; }

    /// <summary>结果。</summary>
    public FileDetailResult Result { get; init; }

    /// <summary>失败原因（Failed 时）。</summary>
    public string? Error { get; init; }

    /// <summary>接收成功时的绝对保存路径（发送项为 null；供"在资源管理器中显示"）。</summary>
    public string? SavedPath { get; init; }

    // ---------- UI 计算属性（不序列化） ----------

    [JsonIgnore] public string SizeText => ByteFormatter.Format(Size);

    [JsonIgnore] public string StatusText => Result switch
    {
        FileDetailResult.Success => "成功",
        FileDetailResult.Failed => "失败",
        FileDetailResult.Canceled => "已取消",
        _ => "跳过",
    };

    [JsonIgnore] public Brush StatusBrush => Result switch
    {
        FileDetailResult.Success => new SolidColorBrush(Windows.UI.Color.FromArgb(255, 63, 182, 104)),
        FileDetailResult.Failed => new SolidColorBrush(Windows.UI.Color.FromArgb(255, 224, 90, 79)),
        FileDetailResult.Canceled => new SolidColorBrush(Windows.UI.Color.FromArgb(255, 232, 163, 61)),
        _ => new SolidColorBrush(Windows.UI.Color.FromArgb(255, 140, 140, 140)),
    };

    /// <summary>接收成功且有保存路径 → 详情行显示"打开位置"。</summary>
    [JsonIgnore] public Microsoft.UI.Xaml.Visibility OpenVisibility =>
        Result == FileDetailResult.Success && !string.IsNullOrEmpty(SavedPath)
            ? Microsoft.UI.Xaml.Visibility.Visible
            : Microsoft.UI.Xaml.Visibility.Collapsed;
}
