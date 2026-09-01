// FileKind：发送端对文件的分类（本地 UI 图标用）。同时提供到 MIME string 的映射
//（协议端 FileDto.FileType 是 MIME 字符串，例如 "image/png"）。
namespace PcDemo.Models;

public enum FileKind
{
    Image, Video, Audio, Pdf, Zip,
    Word, Excel, PowerPoint, Text, Apk, Other,
}

public static class FileKindMapper
{
    public static FileKind FromExtension(string ext)
    {
        var e = ext.TrimStart('.').ToLowerInvariant();
        var images = new HashSet<string> { "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", "heic", "avif", "svg" };
        var videos = new HashSet<string> { "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "3gp", "mpeg", "mpg" };
        var audios = new HashSet<string> { "mp3", "wav", "flac", "aac", "ogg", "m4a", "opus", "wma" };
        if (images.Contains(e)) return FileKind.Image;
        if (videos.Contains(e)) return FileKind.Video;
        if (audios.Contains(e)) return FileKind.Audio;
        if (e == "pdf") return FileKind.Pdf;
        if (new HashSet<string> { "zip", "7z", "rar", "tar", "gz", "bz2", "xz" }.Contains(e)) return FileKind.Zip;
        if (new HashSet<string> { "doc", "docx", "docm" }.Contains(e)) return FileKind.Word;
        if (new HashSet<string> { "xls", "xlsx", "xlsm", "csv" }.Contains(e)) return FileKind.Excel;
        if (new HashSet<string> { "ppt", "pptx", "pptm" }.Contains(e)) return FileKind.PowerPoint;
        if (new HashSet<string> { "txt", "md", "json", "xml", "yml", "yaml", "toml", "ini", "log" }.Contains(e)) return FileKind.Text;
        if (new HashSet<string> { "apk", "exe", "msi", "appx", "dmg", "rpm", "deb" }.Contains(e)) return FileKind.Apk;
        return FileKind.Other;
    }

    public static string ToMime(FileKind kind, string ext)
    {
        var e = ext.TrimStart('.').ToLowerInvariant();
        return kind switch
        {
            FileKind.Image => $"image/{e.Replace("jpg", "jpeg")}",
            FileKind.Video => $"video/{e}",
            FileKind.Audio => $"audio/{e.Replace("m4a", "mp4")}",
            FileKind.Pdf => "application/pdf",
            FileKind.Zip => e switch
            {
                "zip" => "application/zip",
                "7z"  => "application/x-7z-compressed",
                "rar" => "application/vnd.rar",
                "tar" => "application/x-tar",
                "gz"  => "application/gzip",
                _     => "application/octet-stream",
            },
            FileKind.Word => e.StartsWith("doc") ? "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                                                  : "application/msword",
            FileKind.Excel => e is "xls" or "xlsx" or "xlsm"
                ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                : "text/csv",
            FileKind.PowerPoint => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            FileKind.Text => "text/plain",
            FileKind.Apk => "application/vnd.android.package-archive",
            _ => "application/octet-stream",
        };
    }
}
