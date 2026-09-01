// 刷新按钮专用 Converter：InvertedBoolConverter（刷中禁用）+ RefreshingTextConverter（刷中变"刷新中"）。
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
