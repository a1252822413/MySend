// 错误响应体，所有 4xx/5xx 都返回 { "message": "..." }。
namespace PcDemo.Models.Dto;

public sealed class ErrorResponse
{
    public string Message { get; set; } = string.Empty;
}
