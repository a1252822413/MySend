// 历史明细对话框 codebehind：展示一条传输历史里的逐文件清单（成功/失败/取消/跳过 + 打开位置）。
using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PcDemo.Models;

namespace PcDemo.Views;

public sealed partial class HistoryDetailDialog : ContentDialog
{
    public HistoryDetailDialog(TransferHistoryItem item)
    {
        // 派生类不匹配 TargetType="ContentDialog" 的隐式样式，必须显式应用新版模板
        this.Style = Application.Current.Resources["DefaultContentDialogStyle"] as Style;
        this.InitializeComponent();

        if (item is null) return;
        HeaderText.Text = $"{item.PeerText}（{item.StatusText}）";
        SubText.Text = $"{item.TimeText} · {item.SizeText}"
                       + (string.IsNullOrEmpty(item.DestinationPath) ? string.Empty : $" · 保存：{item.DestinationPath}");

        if (item.HasDetails && item.Files is not null)
        {
            FileList.ItemsSource = item.Files;
        }
        else
        {
            FileList.Visibility = Visibility.Collapsed;
            NoDetailsText.Visibility = Visibility.Visible;
            ListCaption.Text = string.Empty;
        }
    }

    /// <summary>明细行「打开位置」：在资源管理器中选中该文件（接收成功项才有保存路径）。</summary>
    private void OnOpenDetailFileClick(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not TransferFileDetail d || string.IsNullOrEmpty(d.SavedPath))
            return;
        try
        {
            if (System.IO.File.Exists(d.SavedPath))
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{d.SavedPath}\"") { UseShellExecute = true });
            else
                Process.Start(new ProcessStartInfo("explorer.exe",
                    System.IO.Path.GetDirectoryName(d.SavedPath) ?? d.SavedPath) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            App.LogDiag($"[HistoryDetail] open failed: {ex.Message}");
        }
    }
}
