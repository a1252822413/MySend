// SendFileStatus -> 对应颜色/可见性的额外转换器（WinUI 不支持 DataTrigger）。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using PcDemo.Models;

namespace PcDemo.Converters;

public sealed class SendFileStatusToColor : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var status = value is SendFileStatus s ? s : SendFileStatus.Pending;
        var hex = status switch
        {
            SendFileStatus.Uploading => "#0078D4",  // Accent
            SendFileStatus.Done      => "#3FB668",  // 绿
            SendFileStatus.Failed    => "#D13438",  // 红
            _ => null,  // 其他回退到 Brush 资源
        };
        if (hex is null)
        {
            // 默认灰色
            return new SolidColorBrush(new Windows.UI.Color { A = 255, R = 0xE0, G = 0xE0, B = 0xE0 });
        }
        var c = Windows.UI.Color.FromArgb(
            255,
            byte.Parse(hex.Substring(1, 2), System.Globalization.NumberStyles.HexNumber),
            byte.Parse(hex.Substring(3, 2), System.Globalization.NumberStyles.HexNumber),
            byte.Parse(hex.Substring(5, 2), System.Globalization.NumberStyles.HexNumber));
        return new SolidColorBrush(c);
    }
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

public sealed class SendFileStatusToProgressColor : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var status = value is SendFileStatus s ? s : SendFileStatus.Pending;
        // WinUI ProgressBar 用 Foreground 决定前景色
        var hex = status switch
        {
            SendFileStatus.Done => "#3FB668",
            SendFileStatus.Failed => "#D13438",
            _ => "#0078D4",   // 上传中/未开始 用 accent
        };
        var c = Windows.UI.Color.FromArgb(
            255,
            byte.Parse(hex.Substring(1, 2), System.Globalization.NumberStyles.HexNumber),
            byte.Parse(hex.Substring(3, 2), System.Globalization.NumberStyles.HexNumber),
            byte.Parse(hex.Substring(5, 2), System.Globalization.NumberStyles.HexNumber));
        return new SolidColorBrush(c);
    }
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>非失败状态（Uploading/Done/Skipped/Pending） 隐藏 ProgressBar（仅在失败时显…
public sealed class ShowProgressBarWhenInProgressOrDone : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var status = value is SendFileStatus s ? s : SendFileStatus.Pending;
        // 只有这些状态显示进度条，其他都隐藏
        return status is SendFileStatus.Uploading or SendFileStatus.Done or SendFileStatus.Failed
            ? Visibility.Visible
            : Visibility.Collapsed;
    }
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}
