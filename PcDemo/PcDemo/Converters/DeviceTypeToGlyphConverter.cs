// 设备类型 -> 图标字形 转换器（mobile/desktop/web/headless/server -> Segoe Fluent Icons 字形）。
// 输出为 PUA 字形字符，必须配合 FontFamily="Segoe Fluent Icons" 的 TextBlock/FontIcon 使用（否则显示 tofu）。
// 字形码点依据 Segoe MDL2/Fluent Icons 官方表：E8EA CellPhone / E7F4 TVMonitor / E774 Globe /
// E968 Network / E950 Component。
using Microsoft.UI.Xaml.Data;
using PcDemo.Models.Dto;

namespace PcDemo.Converters;

public sealed class DeviceTypeToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        return value switch
        {
            DeviceType.Mobile => "\uE8EA",    // CellPhone
            DeviceType.Desktop => "\uE7F4",   // TVMonitor
            DeviceType.Web => "\uE774",       // Globe
            DeviceType.Headless => "\uE968",  // Network（无头设备 = 网络节点）
            DeviceType.Server => "\uE950",    // Component（芯片组件）
            _ => "\uE7F4",
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}
