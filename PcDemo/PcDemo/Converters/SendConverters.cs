// SendPage 使用的各种 UI 转换器（null/visibility / bytes -> string / double 0..1 -> 0..100 / 状态->可见性 / 状态灯）。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using PcDemo.Models;
using Windows.UI;

namespace PcDemo.Converters;

public sealed class NullToCollapsed : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is null ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>null 或空字符串 -> Collapsed，否则 Visible（用于状态提示文字，无内容时不占位）。</summary>
public sealed class EmptyToCollapsed : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => string.IsNullOrWhiteSpace(value as string) ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>bool true -> Visible，false -> Collapsed。</summary>
public sealed class BoolToVisibility : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => value is Visibility.Visible;
}

public sealed class BytesToString : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var b = value as long? ?? 0L;
        return ByteFormatter.Format(b);
    }
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>0.0..1.0 -> 0..100（ProgressBar 百分比刻度）。</summary>
public sealed class DoubleToPercent : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var d = value as double? ?? 0.0;
        return Math.Clamp(d * 100.0, 0.0, 100.0);
    }
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>0.0..1.0 -> "45"（Run.Text 用，string 类型）。</summary>
public sealed class DoubleToPercentText : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var d = value as double? ?? 0.0;
        return Math.Clamp(d * 100.0, 0.0, 100.0).ToString("0");
    }
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

public sealed class FailedToVisible : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is SendFileStatus.Failed ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

public sealed class PendingOnlyToVisible : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is SendFileStatus.Pending ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

// Segoe Fluent Icons 字形（配合 FontFamily="Segoe Fluent Icons" 使用）。
// 文档类（pdf/word/excel/ppt/text）MDL2 无专用字形，统一用 Page（E7C3），类型区分交给颜色/扩展名。
public sealed class FileKindToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value switch
        {
            FileKind.Image => "\uE8B9",        // Picture
            FileKind.Video => "\uE714",        // Video
            FileKind.Audio => "\uE8D6",        // Audio
            FileKind.Pdf => "\uE7C3",          // Page
            FileKind.Zip => "\uE7B8",          // Package
            FileKind.Word => "\uE7C3",         // Page
            FileKind.Excel => "\uE7C3",        // Page
            FileKind.PowerPoint => "\uE7C3",  // Page
            FileKind.Text => "\uE7C3",        // Page
            FileKind.Apk => "\uE7B8",          // Package
            _ => "\uE723",                     // Attach
        };
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>
/// FileKind → 图标配色（彩色文件图标）。
/// ConverterParameter = "glyph" 返回类型主色（字形前景）；不传或其它值返回同色的低透明底色
/// （图标方块的背景）。两级配色让图标在亮/暗主题下都能看出"一块彩色"，而不是灰线框。
/// 这里刻意用固定调色板而非 ThemeResource：文件类型色要跨主题保持稳定辨识度，
/// 取值都压在中明度，浅底不刺眼、深底也看得清。
/// </summary>
public sealed class FileKindToBrushConverter : IValueConverter
{
    private static readonly Dictionary<FileKind, Color> Palette = new()
    {
        [FileKind.Image] = Color.FromArgb(0xFF, 0x7C, 0x3A, 0xED),      // 紫
        [FileKind.Video] = Color.FromArgb(0xFF, 0xDB, 0x27, 0x77),      // 玫红
        [FileKind.Audio] = Color.FromArgb(0xFF, 0x08, 0x91, 0xB2),      // 青
        [FileKind.Pdf] = Color.FromArgb(0xFF, 0xDC, 0x26, 0x26),        // 红
        [FileKind.Zip] = Color.FromArgb(0xFF, 0xD9, 0x77, 0x06),        // 琥珀
        [FileKind.Word] = Color.FromArgb(0xFF, 0x25, 0x63, 0xEB),       // 蓝
        [FileKind.Excel] = Color.FromArgb(0xFF, 0x15, 0x80, 0x3D),      // 绿
        [FileKind.PowerPoint] = Color.FromArgb(0xFF, 0xEA, 0x58, 0x0C), // 橙
        [FileKind.Text] = Color.FromArgb(0xFF, 0x47, 0x55, 0x69),       // 石板灰
        // 安装包刻意不用绿：Excel 已经是绿，而 exe 和 xlsx 经常同框出现，
        // 两个绿并排几乎分不出来（实测截图）。改成深青绿，和 Excel 绿、音频青都拉开。
        [FileKind.Apk] = Color.FromArgb(0xFF, 0x0F, 0x76, 0x6E),        // 深青绿
        [FileKind.Other] = Color.FromArgb(0xFF, 0x94, 0xA3, 0xB8),      // 浅灰（比"文本"石板灰更淡，区分同类灰度）
    };

    // 底色透明度：约 14%，够看出色块又不至于把字形压糊
    private const byte TintAlpha = 0x24;

    // 列表滚动时 Convert 会被反复调用，刷子按 (类型, 是否字形) 缓存，避免每次 new
    private static readonly Dictionary<(FileKind, bool), SolidColorBrush> Cache = new();

    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var kind = value is FileKind k ? k : FileKind.Other;
        var isGlyph = string.Equals(parameter as string, "glyph", StringComparison.OrdinalIgnoreCase);

        if (Cache.TryGetValue((kind, isGlyph), out var cached)) return cached;

        var c = Palette.TryGetValue(kind, out var p) ? p : Palette[FileKind.Other];
        var brush = new SolidColorBrush(isGlyph ? c : Color.FromArgb(TintAlpha, c.R, c.G, c.B));
        Cache[(kind, isGlyph)] = brush;
        return brush;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>静态字节数格式化（给 XAML 直接用 c:ByteFormatter.Format(...)）。</summary>
public static class ByteFormatter
{
    public static string Format(long b)
    {
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double size = b;
        int i = 0;
        while (size >= 1024 && i < units.Length - 1) { size /= 1024; i++; }
        return $"{size:0.##} {units[i]}";
    }

    /// <summary>速度 → " · 12.3 MB/s"；0 = 未在传输（空字符串）。</summary>
    public static string FormatSpeed(long bytesPerSecond)
        => bytesPerSecond <= 0 ? string.Empty : $" · {Format(bytesPerSecond)}/s";

    /// <summary>剩余秒数 → " · 剩余 45秒 / 3分20秒 / 1小时12分"；0 = 未知（空字符串）。</summary>
    public static string FormatEta(double seconds)
    {
        if (seconds <= 0) return string.Empty;
        if (seconds < 60) return $" · 剩余 {seconds:0} 秒";
        if (seconds < 3600) return $" · 剩余 {seconds / 60:0} 分 {seconds % 60:0} 秒";
        return $" · 剩余 {seconds / 3600:0} 小时 {(seconds % 3600) / 60:0} 分";
    }
}

/// <summary>SendSessionState → 中文状态文字（进度卡显示用）。</summary>
public sealed class SendSessionStateToText : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value switch
        {
            SendSessionState.WaitingForReceiver => "等待对方确认…",
            SendSessionState.InProgress => "传输中",
            SendSessionState.Completed => "已完成",
            SendSessionState.Cancelled => "已取消",
            SendSessionState.CancelledByPeer => "对方中断",
            SendSessionState.Rejected => "对方拒绝",
            SendSessionState.Failed => "发送失败",
            _ => "准备中",
        };
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>Device.IsPicked -> 选中高亮边框色。True=品牌 accent / False=透明（占位防布局跳动）。</summary>
public sealed class BoolToSelectionBrush : IValueConverter
{
    private static readonly Brush None = new SolidColorBrush(Windows.UI.Color.FromArgb(0x00, 0x00, 0x00, 0x00));
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? ThemeBrushHelper.Get("AccentFillColorDefaultBrush") : None;
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>bool -> 状态小灯颜色：True 成功绿 / False 错误红（主题资源，深浅色自适应）。</summary>
public sealed class BoolToPassColor : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? ThemeBrushHelper.Get("SystemFillColorSuccessBrush") : ThemeBrushHelper.Get("SystemFillColorCriticalBrush");
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>bool -> 提示文字颜色：True 成功绿 / False 警告橙（主题资源）。</summary>
public sealed class BoolToHintColor : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? ThemeBrushHelper.Get("SystemFillColorSuccessBrush") : ThemeBrushHelper.Get("SystemFillColorCautionBrush");
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>每次调用从当前主题取资源 Brush（不缓存实例，主题切换后自动跟随）。</summary>
internal static class ThemeBrushHelper
{
    public static Brush Get(string key)
        => Application.Current.Resources[key] as Brush
           ?? new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0x80, 0x80, 0x80));
}

/// <summary>是否选目标设备（状态灯已由 BoolToPassColor 呈现，文字不再带图标前缀）。</summary>
public sealed class BoolToReadyTarget : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? "已选目标设备" : "未选目标设备（点上方设备卡片，可多选）";
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>是否有待发文件。</summary>
public sealed class BoolToReadyFile : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? "已添加文件" : "未添加文件（点“添加文件”）";
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>是否空闲可发。</summary>
public sealed class BoolToReadyState : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? "当前可发送（未占用）" : "正在发送中";
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>Device.IsOnline → 在线点颜色。True=成功绿，False=中性灰（主题资源）。</summary>
public sealed class BoolToOnlineDot : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? ThemeBrushHelper.Get("SystemFillColorSuccessBrush") : ThemeBrushHelper.Get("SystemFillColorNeutralBrush");
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>Device.IsOnline → "在线"/"可能离线" 文字。</summary>
public sealed class BoolToOnlineLabel : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? "在线" : "可能离线";
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>Device.IsBlacklisted → 置灰透明度。True=0.4（灰显不可选感），False=1.0（正常）。</summary>
public sealed class BlacklistOpacityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? 0.4 : 1.0;
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}
