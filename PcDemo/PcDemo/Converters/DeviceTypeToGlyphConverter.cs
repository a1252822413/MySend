// 设备类型 -> 图标字符 转换器（mobile/desktop/web/headless/server -> 对应 Emoji/Segoe 字形）。
using Microsoft.UI.Xaml.Data;
using PcDemo.Models.Dto;

namespace PcDemo.Converters;

public sealed class DeviceTypeToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        return value switch
        {
            DeviceType.Mobile => "📱",
            DeviceType.Desktop => "💻",
            DeviceType.Web => "🌐",
            DeviceType.Headless => "🖥️",
            DeviceType.Server => "🗄️",
            _ => "💻",
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}
