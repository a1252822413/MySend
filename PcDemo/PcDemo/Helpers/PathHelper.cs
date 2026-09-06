// 路径辅助：本地应用数据目录 + 文件名冲突重命名。
// MSIX 打包模式下用 ApplicationData.Current.LocalFolder（沙箱明确可写）。
using Windows.Storage;

namespace PcDemo.Helpers;

public static class PathHelper
{
    /// <summary>本地应用数据目录（MSIX 沙箱下的 LocalFolder）。</summary>
    public static string AppDataDir => ApplicationData.Current.LocalFolder.Path;

    public static string SettingsFilePath => System.IO.Path.Combine(AppDataDir, "settings.json");

    /// <summary>白名单/黑名单持久化文件（与 settings.json 分离，避免名单增长撑大配置）。</summary>
    public static string DeviceListsFilePath => System.IO.Path.Combine(AppDataDir, "device-lists.json");

    /// <summary>
    /// 解析网络提供的 fileName（可能是含 '/' 或 '\' 分隔的相对路径——官方目录传输就把
    /// 相对路径编码进 fileName）到 destinationDir 下的安全绝对路径。
    /// 
    /// 安全规则（对齐官方 file_saver 的 traversal 防护）：
    ///   - 绝对路径（以 / 或 \ 开头）→ 拒绝（返回 null）
    ///   - 任何组件为 "." 或 ".." → 拒绝（返回 null），杜绝路径穿越
    ///   - 盘符头组件（如 "C:"）→ 拒绝
    ///   - 含 NUL / 非法文件名字符的组件 → 非法字符替换为 '_'，超长截断
    /// 返回的路径保证位于 destinationDir 之下（逐段净化 + 最终 FullPath 前缀校验）。
    /// 返回 null 表示不安全/不可接受，调用方应整体拒绝该文件。
    /// </summary>
    public static string? ResolveSafeDestinationPath(string destinationDir, string rawFileName)
    {
        if (string.IsNullOrWhiteSpace(rawFileName)) return null;
        if (rawFileName.IndexOf('\0') >= 0) return null;

        // 统一分隔符（官方发送端把相对路径 replaceAll('\\','/') 后放入 fileName）
        var norm = rawFileName.Replace('\\', '/');
        // 绝对路径（/etc/passwd、\foo 等）整体拒绝，不做相对化，避免歧义
        if (norm.StartsWith("/", StringComparison.Ordinal)) return null;

        var baseDir = System.IO.Path.GetFullPath(destinationDir);
        var components = norm.Split('/');
        var dirs = new List<string>(components.Length);
        var last = string.Empty;

        foreach (var raw in components)
        {
            var seg = raw.Trim();
            if (seg.Length == 0) continue;               // 连续分隔符/尾斜杠：忽略
            if (seg is "." or "..") return null;         // 穿越 → 整体拒绝
            if (seg.Length == 2 && char.IsLetter(seg[0]) && seg[1] == ':') return null; // 盘符

            var cleaned = SanitizeSegment(seg);
            if (cleaned.Length == 0) continue;
            dirs.Add(cleaned);
        }
        if (dirs.Count == 0) return null;

        last = dirs[^1];
        dirs.RemoveAt(dirs.Count - 1);

        var parentDir = baseDir;
        foreach (var d in dirs) parentDir = System.IO.Path.Combine(parentDir, d);

        // 防御性前缀校验：即便每段已净化，仍确保归一化后仍落在 baseDir 之内
        var fullParent = System.IO.Path.GetFullPath(parentDir);
        if (!IsWithin(fullParent, baseDir)) return null;

        return MakeUnique(fullParent, last);
    }

    /// <summary>非法字符替换为 '_'，去掉首尾空白/点，超长截断；返回净化后的单段组件。</summary>
    private static string SanitizeSegment(string segment)
    {
        // Windows 保留字符 < > : " / \ | ? * 与控制字符
        var cleaned = new string(segment.Select(ch =>
            System.Array.IndexOf(System.IO.Path.GetInvalidFileNameChars(), ch) >= 0 ? '_' : ch).ToArray());
        cleaned = cleaned.Trim().TrimEnd('.');
        if (cleaned.Length == 0) return "_";
        // Windows 单段上限 ~255（含路径结构留余量）
        return cleaned.Length > 200 ? cleaned[..200] : cleaned;
    }

    private static bool IsWithin(string path, string root)
    {
        var r = root.TrimEnd('\\', '/');
        return path.Equals(root, StringComparison.OrdinalIgnoreCase)
            || path.StartsWith(r + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// 给定目标目录与文件名，若已存在则追加 _1/_2 等后缀避免覆盖。
    /// 算法与 localsend FileSaver 行为一致：保留扩展名。
    /// </summary>
    private static string MakeUnique(string directory, string fileName)
    {
        var fullPath = System.IO.Path.Combine(directory, fileName);
        if (!System.IO.File.Exists(fullPath))
        {
            return fullPath;
        }

        var nameWithoutExt = System.IO.Path.GetFileNameWithoutExtension(fileName);
        var ext = System.IO.Path.GetExtension(fileName);
        for (var i = 1; i < 1000; i++)
        {
            var candidate = System.IO.Path.Combine(directory, $"{nameWithoutExt}_{i}{ext}");
            if (!System.IO.File.Exists(candidate))
            {
                return candidate;
            }
        }
        // 极端情况：附加 GUID 兜底
        return System.IO.Path.Combine(directory, $"{nameWithoutExt}_{Guid.NewGuid():N}{ext}");
    }
}
