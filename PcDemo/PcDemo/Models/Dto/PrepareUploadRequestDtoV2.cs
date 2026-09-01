// 发送方请求接收文件 DTO，对应 dto_v2.rs PrepareUploadRequestDtoV2。
// POST /api/localsend/v2/prepare-upload 的请求体。
namespace PcDemo.Models.Dto;

public sealed class PrepareUploadRequestDtoV2
{
    public RegisterDtoV2 Info { get; set; } = new();
    public Dictionary<string, FileDto> Files { get; set; } = new();
}
