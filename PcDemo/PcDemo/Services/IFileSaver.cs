// 文件落盘服务接口：流式写入目标目录，处理文件名冲突重命名。
namespace PcDemo.Services;

public interface IFileSaver
{
    /// <summary>把输入流写入目标目录下指定文件名；若已存在则自动重命名为 _1/_2/...。
    /// progress 按已写字节数上报（节流 ~0.25s/512KB）；取消或失败时删除半成品文件后抛出。</summary>
    /// <returns>实际写入的绝对路径。</returns>
    Task<string> SaveAsync(string directory, string fileName, Stream content,
        IProgress<long>? progress = null, CancellationToken ct = default);
}
