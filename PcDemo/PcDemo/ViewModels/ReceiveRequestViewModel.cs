// ReceiveRequestViewModel：弹窗内 VM，显示发送方信息 + 文件列表（带 CheckBox 选中状态）。
// 提供文件项类型（包装 FileDto + IsSelected），用于 ListView 绑定。
using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.Models.Dto;

namespace PcDemo.ViewModels;

public sealed partial class ReceiveFileItem : ObservableObject
{
    public string FileId { get; init; } = string.Empty;
    public string FileName { get; init; } = string.Empty;
    public ulong Size { get; init; }
    public string FileType { get; init; } = "application/octet-stream";

    [ObservableProperty] private bool _isSelected = true;

    public string DisplaySize => Size switch
    {
        < 1024 => $"{Size} B",
        < 1024 * 1024 => $"{Size / 1024.0:F1} KB",
        < 1024UL * 1024 * 1024 => $"{Size / 1024.0 / 1024:F1} MB",
        _ => $"{Size / 1024.0 / 1024 / 1024:F2} GB",
    };

    /// <summary>根据 FileType 推断文件图标 Emoji（图片/视频/音频/文档/压缩包/其他）。</summary>
    public string FileIcon => FileType switch
    {
        var t when t.StartsWith("image/") => "🖼️",
        var t when t.StartsWith("video/") => "🎬",
        var t when t.StartsWith("audio/") => "🎵",
        "application/pdf" => "📕",
        "application/zip" or "application/x-zip-compressed" or "application/x-rar-compressed"
            or "application/x-7z-compressed" or "application/gzip" => "🗜️",
        var t when t.StartsWith("text/") => "📄",
        var t when t.Contains("word") => "📘",
        var t when t.Contains("excel") || t.Contains("spreadsheet") => "📊",
        var t when t.Contains("powerpoint") || t.Contains("presentation") => "📽️",
        _ => "📎",
    };
}

public sealed partial class ReceiveRequestViewModel : ObservableObject
{
    public string SenderAlias { get; init; } = string.Empty;
    public string SenderIp { get; init; } = string.Empty;
    public string SenderDeviceModel { get; init; } = string.Empty;

    public ObservableCollection<ReceiveFileItem> Files { get; } = new();

    /// <summary>所有文件总大小（已格式化为 B/KB/MB/GB）。</summary>
    public string TotalDisplaySize
    {
        get
        {
            var total = Files.Sum(f => (decimal)f.Size);
            return total switch
            {
                < 1024 => $"{total} B",
                < 1024 * 1024 => $"{total / 1024:F1} KB",
                < 1024 * 1024 * 1024 => $"{total / 1024 / 1024:F1} MB",
                _ => $"{total / 1024 / 1024 / 1024:F2} GB",
            };
        }
    }

    /// <summary>文件总数。</summary>
    public int FileCount => Files.Count;

    /// <summary>构造 VM：从会话提取发送方信息与文件列表。</summary>
    public static ReceiveRequestViewModel FromSession(ReceiveSession session)
    {
        var vm = new ReceiveRequestViewModel
        {
            SenderAlias = session.Sender.Alias,
            SenderIp = session.SenderIp,
            SenderDeviceModel = session.Sender.DeviceModel ?? string.Empty,
        };
        foreach (var f in session.Files.Values)
        {
            var item = new ReceiveFileItem
            {
                FileId = f.FileId,
                FileName = f.Metadata.FileName,
                Size = f.Metadata.Size,
                FileType = f.Metadata.FileType,
                IsSelected = true,
            };
            // 勾选状态变化 → 刷新已选统计
            item.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName == nameof(ReceiveFileItem.IsSelected))
                    vm.RefreshSelectedSummary();
            };
            vm.Files.Add(item);
        }
        return vm;
    }

    // ---------- 全选/全不选 与 已选统计 ----------

    /// <summary>已选文件数。</summary>
    public int SelectedCount => Files.Count(f => f.IsSelected);

    /// <summary>已选文件总大小（字节）。</summary>
    public ulong SelectedBytes => Files.Where(f => f.IsSelected)
        .Aggregate(0UL, (acc, f) => acc + f.Size);

    /// <summary>标题行汇总：如 "已选 3/5 · 12.3 MB"。</summary>
    public string SelectedSummaryText
    {
        get
        {
            var size = SelectedBytes;
            var sizeText = size switch
            {
                < 1024 => $"{size} B",
                < 1024 * 1024 => $"{size / 1024.0:F1} KB",
                < 1024UL * 1024 * 1024 => $"{size / 1024.0 / 1024:F1} MB",
                _ => $"{size / 1024.0 / 1024 / 1024:F2} GB",
            };
            return $"已选 {SelectedCount}/{FileCount} · {sizeText}";
        }
    }

    public void SelectAll()
    {
        foreach (var f in Files) f.IsSelected = true;
        RefreshSelectedSummary();
    }

    public void SelectNone()
    {
        foreach (var f in Files) f.IsSelected = false;
        RefreshSelectedSummary();
    }

    private void RefreshSelectedSummary()
    {
        OnPropertyChanged(nameof(SelectedCount));
        OnPropertyChanged(nameof(SelectedBytes));
        OnPropertyChanged(nameof(SelectedSummaryText));
    }

    public PrepareUploadDecision ToDecision()
    {
        var accepted = Files.Where(f => f.IsSelected).Select(f => f.FileId).ToList();
        return new PrepareUploadDecision
        {
            Accepted = accepted.Count > 0,
            AcceptedFileIds = accepted,
        };
    }
}
