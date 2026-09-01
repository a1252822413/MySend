// 单文件元数据 DTO，对应 packages/core/src/model/transfer.rs FileDto。
namespace PcDemo.Models.Dto;

public sealed class FileDto
{
    public string Id { get; set; } = string.Empty;
    public string FileName { get; set; } = string.Empty;
    public ulong Size { get; set; }
    public string FileType { get; set; } = "application/octet-stream";
    public string? Sha256 { get; set; }
    public string? Preview { get; set; }
    public FileMetadata? Metadata { get; set; }
}
