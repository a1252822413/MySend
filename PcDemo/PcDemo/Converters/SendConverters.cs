// SendPage 使用的各种 UI 转换器（null/visibility / bytes -> string / double 0..1 -> 0..100 / 状态->可见性 / 状态灯）。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using PcDemo.Models;

namespace PcDemo.Converters;

public sealed class NullToCollapsed : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is null ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
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

public sealed class FileKindToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value switch
        {
            FileKind.Image => "🖼️",
            FileKind.Video => "🎬",
            FileKind.Audio => "🎵",
            FileKind.Pdf => "📕",
            FileKind.Zip => "🗜️",
            FileKind.Word => "📘",
            FileKind.Excel => "📊",
            FileKind.PowerPoint => "📽️",
            FileKind.Text => "📄",
            FileKind.Apk => "📦",
            _ => "📎",
        };
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

/// <summary>Device.IsPicked → 选中高亮边框色。True=强调蓝 / False=透明（占位防布局跳动）。</summary>
public sealed class BoolToSelectionBrush : IValueConverter
{
    private static readonly Brush Picked = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0x5A, 0x81, 0xF7));
    private static readonly Brush None = new SolidColorBrush(Windows.UI.Color.FromArgb(0x00, 0x00, 0x00, 0x00));
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? Picked : None;
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>bool → 状态小灯颜色：True 绿 (#3FB668) / False 红 (#D13438)。</summary>
public sealed class BoolToPassColor : IValueConverter
{
    private static readonly Brush Pass = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0x3F, 0xB6, 0x68));
    private static readonly Brush Fail = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0xD1, 0x34, 0x38));
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? Pass : Fail;
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>bool → 提示文字颜色：True 绿（通过）/ False 橙（提醒）。</summary>
public sealed class BoolToHintColor : IValueConverter
{
    private static readonly Brush Ok = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0x3F, 0xB6, 0x68));
    private static readonly Brush Warn = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0xFF, 0x8C, 0x00));
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? Ok : Warn;
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>是否选目标设备：✅ / ❌ 前缀 + 文字。</summary>
public sealed class BoolToReadyTarget : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? "✅ 已选目标设备" : "❌ 未选目标设备（点上方设备卡片）";
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>是否有待发文件：✅ / ❌ 前缀 + 文字。</summary>
public sealed class BoolToReadyFile : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? "✅ 已添加文件" : "❌ 未添加文件（点“添加文件”）";
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>是否空闲可发：✅ / ❌ 前缀 + 文字。</summary>
public sealed class BoolToReadyState : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? "✅ 当前可发送（未占用）" : "❌ 正在发送中";
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>Device.IsOnline → 在线点颜色。True=绿，False=灰。</summary>
public sealed class BoolToOnlineDot : IValueConverter
{
    private static readonly Brush On  = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0x3F, 0xB6, 0x68));
    private static readonly Brush Off = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0x8A, 0x8A, 0x8A));
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? On : Off;
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>Device.IsOnline → "在线"/"可能离线" 文字。</summary>
public sealed class BoolToOnlineLabel : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? "在线" : "可能离线";
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}
