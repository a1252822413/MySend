// prepare-upload 成功响应，对应 dto_v2.rs PrepareUploadResponseDtoV2。
// files 仅含被接受的文件，value 是该文件的 upload token。
namespace PcDemo.Models.Dto;

public sealed class PrepareUploadResponseDtoV2
{
    public string SessionId { get; set; } = string.Empty;
    public Dictionary<string, string> Files { get; set; } = new();
}
