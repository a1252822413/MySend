// FileProgressRow：一行一个文件的进度（design/unified v1.3）。
// 颜色/圆角/字阶全在 XAML 用 ThemeResource，C# 只改文本、数值与叠层可见性，
// 因此深浅主题切换不需要任何代码侧画刷查表。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace PcDemo.Controls;

public enum FileRowState
{
    Wait,    // 队列中，0% 空心轨道
    Active,  // 正在传输，accent-soft 行底 + 4px 左竖条
    Done,    // 已完成 / 已校验
    Failed,  // 单文件失败，不影响其余文件
}

public sealed partial class FileProgressRow : UserControl
{
    // Segoe Fluent Icons
    private const string GCheck = "\uE73E";
    private const string GTransfer = "\uE768";
    private const string GWait = "\uE823";
    private const string GCross = "\uE711";

    public FileProgressRow()
    {
        this.InitializeComponent();
    }

    /// <summary>绑定静态信息（文件名、总大小）。</summary>
    public void Bind(string fileName, string sizeText)
    {
        NameText.Text = fileName;
        SizeText.Text = sizeText;
        AutomationProperties.SetName(Bar, fileName + " 进度");
        AutomationProperties.SetName(BarDanger, fileName + " 进度");
    }

    /// <summary>按各自 BytesReceived / Size 刷新，不复用总进度的值。</summary>
    public void Update(double percent, string statusText, FileRowState state, string detailText)
    {
        var pct = System.Math.Clamp(percent, 0, 100);
        Bar.Value = pct;
        BarDanger.Value = pct;

        var active = state == FileRowState.Active;
        var failed = state == FileRowState.Failed;
        var wait = state == FileRowState.Wait;

        ActiveLayer.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        ActiveEdge.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        Bar.Visibility = failed || wait ? Visibility.Collapsed : Visibility.Visible;
        BarDanger.Visibility = failed ? Visibility.Visible : Visibility.Collapsed;
        WaitTrack.Visibility = wait ? Visibility.Visible : Visibility.Collapsed;

        StateIcon.Glyph = state switch
        {
            FileRowState.Done => GCheck,
            FileRowState.Active => GTransfer,
            FileRowState.Failed => GCross,
            _ => GWait,
        };
        StatusText.Text = statusText;
        DetailText.Text = detailText;
        DetailText.Visibility = string.IsNullOrEmpty(detailText)
            ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(Bar, $"{NameText.Text} 进度 {pct:0}%");
    }
}
