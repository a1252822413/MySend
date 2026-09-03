// 文件落盘服务：流式写入目标目录，处理文件名冲突重命名（_1/_2/...）。
// 对应 packages/core/src/http/server/common/save.rs 的写盘逻辑（MVP 简化版）。
using System.Buffers;
using System.Diagnostics;
using PcDemo.Helpers;

namespace PcDemo.Services;

public sealed class FileSaver : IFileSaver
{
    // ArrayPool 复用 80KB buffer，避免频繁 new byte[] 触发 LOH 碎片
    private const int BufferSize = 81920;

    public async Task<string> SaveAsync(string directory, string fileName, Stream content,
        IProgress<long>? progress = null, CancellationToken ct = default, string? expectedSha256 = null)
    {
        Directory.CreateDirectory(directory);
        var path = PathHelper.ResolveUniquePath(directory, fileName);
        var buffer = ArrayPool<byte>.Shared.Rent(BufferSize);
        // 边收边算 SHA-256（~GB/s 级 CPU 成本，可忽略）；发送方未提供校验值则跳过
        using var sha = string.IsNullOrWhiteSpace(expectedSha256)
            ? null
            : System.Security.Cryptography.IncrementalHash.CreateHash(
                System.Security.Cryptography.HashAlgorithmName.SHA256);
        try
        {
            await using var fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            long total = 0, sinceReport = 0;
            var lastReport = Stopwatch.GetTimestamp();
            int read;
            while ((read = await content.ReadAsync(buffer, ct)) > 0)
            {
                await fs.WriteAsync(buffer.AsMemory(0, read), ct);
                sha?.AppendData(buffer, 0, read);
                total += read;
                sinceReport += read;
                // 节流上报：每 512KB 或每 0.25s 一次，避免 UI 刷新过频
                var elapsed = (Stopwatch.GetTimestamp() - lastReport) / (double)Stopwatch.Frequency;
                if (progress is not null && (sinceReport >= 512 * 1024 || elapsed >= 0.25))
                {
                    progress.Report(total);
                    sinceReport = 0;
                    lastReport = Stopwatch.GetTimestamp();
                }
            }
            await fs.FlushAsync(ct);
            progress?.Report(total); // 最终对齐

            // 校验：与官方协议一致（不匹配 → 422 Checksum mismatch），半成品在 catch 中删除
            if (sha is not null)
            {
                var actual = Convert.ToHexString(sha.GetHashAndReset());
                if (!string.Equals(actual, expectedSha256, StringComparison.OrdinalIgnoreCase))
                {
                    throw new ChecksumMismatchException(
                        $"SHA-256 mismatch: expected={expectedSha256} actual={actual}");
                }
            }

            return path;
        }
        catch
        {
            // 取消/失败时删除半成品文件
            try { File.Delete(path); } catch { }
            throw;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }
}
