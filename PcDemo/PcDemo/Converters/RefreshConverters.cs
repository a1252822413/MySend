// 刷新按钮专用 Converter：InvertedBoolConverter（刷中禁用）+ RefreshingTextConverter（刷中变"刷新中"）。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace PcDemo.Converters;

public sealed class InvertedBoolConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is bool b ? !b : true;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}

public sealed class RefreshingTextConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is bool b && b ? "刷新中" : "刷新";

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}

/// <summary>bool false -> Visible，true -> Collapsed。与 SendConverters.BoolToVisibility 互补，
/// 用于「仅白名单模式」统计条的开/关两态 chip 互斥显示。</summary>
public sealed class InvertedBoolToVisibility : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => value is Visibility.Collapsed;
}
