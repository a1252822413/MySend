// 设置页辅助转换器：防火墙检测级别 → 图标字形 / 状态色（语义主题色，深浅自适应）。
// 级别约定：0=检测中/未检测（中性） 1=已放行（成功） 2=未放行（警告） 3=检测/添加失败（错误）
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;

namespace PcDemo.Converters;

public sealed class FirewallLevelToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => System.Convert.ToInt32(value ?? 0) switch
        {
            1 => "\uE73E",  // CheckMark
            2 => "\uE7BA",  // Warning
            3 => "\uE783",  // Error
            _ => "\uE72C",  // Refresh
        };

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}

public sealed class FirewallLevelToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => (Brush)Application.Current.Resources[System.Convert.ToInt32(value ?? 0) switch
        {
            1 => "SystemFillColorSuccessBrush",
            2 => "SystemFillColorCautionBrush",
            3 => "SystemFillColorCriticalBrush",
            _ => "TextFillColorSecondaryBrush",
        }];

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}
