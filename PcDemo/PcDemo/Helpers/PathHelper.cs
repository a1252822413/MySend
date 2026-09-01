// 路径辅助：本地应用数据目录 + 文件名冲突重命名。
// MSIX 打包模式下用 ApplicationData.Current.LocalFolder（沙箱明确可写）。
using Windows.Storage;

namespace PcDemo.Helpers;

public static class PathHelper
{
    /// <summary>本地应用数据目录（MSIX 沙箱下的 LocalFolder）。</summary>
    public static string AppDataDir => ApplicationData.Current.LocalFolder.Path;

    public static string SettingsFilePath => System.IO.Path.Combine(AppDataDir, "settings.json");

    /// <summary>
    /// 给定目标目录与文件名，若已存在则追加 _1/_2 等后缀避免覆盖。
    /// 算法与 localsend FileSaver 行为一致：保留扩展名。
    /// </summary>
    public static string ResolveUniquePath(string directory, string fileName)
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
