// SendFileItem：发送端待上传的单个文件（本地路径 + 协议元数据）。
using System.IO;
using CommunityToolkit.Mvvm.ComponentModel;
using PcDemo.Models.Dto;

namespace PcDemo.Models;

public partial class SendFileItem : ObservableObject
{
    /// <summary>协议端 FileId（GUID，不变）。</summary>
    public string Id { get; set; } = Guid.NewGuid().ToString("N");

    /// <summary>显示名（含扩展名）。</summary>
    public string FileName { get; set; } = string.Empty;

    /// <summary>本地完整路径（用于读流上传）。</summary>
    public string Path { get; set; } = string.Empty;

    /// <summary>文件字节数。</summary>
    public long Size { get; set; }

    /// <summary>文件类型枚举（推断）。</summary>
    public FileKind FileKind { get; set; } = FileKind.Other;

    /// <summary>扩展名（不含点，供 MIME 推断）。</summary>
    public string Extension { get; set; } = string.Empty;

    /// <summary>SHA-256（可选，留空）。</summary>
    public string? Sha256 { get; set; }

    /// <summary>预览缩略图（可选，留空）。</summary>
    public string? Preview { get; set; }

    /// <summary>上传进度 [0,Size]。</summary>
    [ObservableProperty] private long _bytesSent;

    /// <summary>传输状态。</summary>
    [ObservableProperty] private SendFileStatus _status = SendFileStatus.Pending;

    /// <summary>失败原因（仅 Failed 时）。</summary>
    [ObservableProperty] private string? _errorMessage;

    /// <summary>转为协议 DTO。</summary>
    public FileDto ToDto() => new()
    {
        Id = Id,
        FileName = FileName,
        Size = checked((ulong)Size),
        FileType = FileKindMapper.ToMime(FileKind, Extension),
        Sha256 = Sha256,
        Preview = Preview,
    };
}

/// <summary>单文件上传状态。</summary>
public enum SendFileStatus
{
    Pending,
    Uploading,
    Done,
    Failed,
    Skipped,    // 接受方没接受这个文件
}
