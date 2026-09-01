// 文件元数据（修改/访问时间，ISO-8601 字符串），可为空。
namespace PcDemo.Models.Dto;

public sealed class FileMetadata
{
    public string? Modified { get; set; }
    public string? Accessed { get; set; }
}
