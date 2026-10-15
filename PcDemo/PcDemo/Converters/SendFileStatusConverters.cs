// SendFileStatus -> 对应颜色/可见性的额外转换器（WinUI 不支持 DataTrigger）。
// 颜色全部走主题资源（SystemFillColor*/Accent*），深浅主题自适应，不再硬编码 hex。
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
        return status switch
        {
            SendFileStatus.Uploading => ThemeBrushHelper.Get("SystemFillColorAttentionBrush"),
            SendFileStatus.Done      => ThemeBrushHelper.Get("SystemFillColorSuccessBrush"),
            SendFileStatus.Failed    => ThemeBrushHelper.Get("SystemFillColorCriticalBrush"),
            _ => ThemeBrushHelper.Get("SystemFillColorNeutralBrush"),  // 待传/跳过 = 中性灰
        };
    }
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

public sealed class SendFileStatusToProgressColor : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var status = value is SendFileStatus s ? s : SendFileStatus.Pending;
        // WinUI ProgressBar 用 Foreground 决定前景色
        return status switch
        {
            SendFileStatus.Done   => ThemeBrushHelper.Get("SystemFillColorSuccessBrush"),
            SendFileStatus.Failed => ThemeBrushHelper.Get("SystemFillColorCriticalBrush"),
            _ => ThemeBrushHelper.Get("AccentFillColorDefaultBrush"),  // 上传中/未开始 = 品牌 accent
        };
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
