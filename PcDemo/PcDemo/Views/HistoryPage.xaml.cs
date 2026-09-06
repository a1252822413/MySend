// HistoryPage codebehind：传输历史列表页。
using System.Diagnostics;
using System.IO;
using CommunityToolkit.Mvvm.Messaging;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.ViewModels;

namespace PcDemo.Views;

public sealed partial class HistoryPage : Page
{
    public HistoryViewModel ViewModel { get; }

    public HistoryPage()
    {
        ViewModel = App.Services.GetRequiredService<HistoryViewModel>();
        this.InitializeComponent();
        this.Loaded += (_, _) => ViewModel.Refresh();
    }

    private void OnClearClick(object sender, RoutedEventArgs e) => ViewModel.Clear();

    private void OnOpenFolderClick(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not TransferHistoryItem item || item.DestinationPath is null)
            return;
        try
        {
            // 单文件 → 资源管理器中选中该文件；多文件/文件已不在 → 打开保存目录
            var target = item.FirstFileName is { } name ? Path.Combine(item.DestinationPath, name) : null;
            if (target is not null && File.Exists(target))
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{target}\"") { UseShellExecute = true });
            else
                Process.Start(new ProcessStartInfo("explorer.exe", item.DestinationPath) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            App.LogDiag($"[History] open folder failed: {ex}");
        }
    }

    /// <summary>右键「复制保存路径」：把接收保存目录（接收成功项）写入剪贴板。</summary>
    private void OnCopyPathClick(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not TransferHistoryItem item || item.DestinationPath is null)
            return;
        try
        {
            var pkg = new Windows.ApplicationModel.DataTransfer.DataPackage();
            pkg.SetText(item.DestinationPath);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(pkg);
            Windows.ApplicationModel.DataTransfer.Clipboard.Flush();
            WeakReferenceMessenger.Default.Send(new ShowToastMessage
            {
                Kind = ToastKind.Success,
                Message = "保存路径已复制到剪贴板",
                DurationMs = 1500,
            });
        }
        catch (Exception ex)
        {
            App.LogDiag($"[History] copy path failed: {ex.Message}");
        }
    }

    /// <summary>右键「查看文件明细」：弹出逐文件明细对话框（旧版本记录无明细时提示）。</summary>
    private async void OnShowDetailsClick(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not TransferHistoryItem item)
            return;
        if (!item.HasDetails)
        {
            WeakReferenceMessenger.Default.Send(new ShowToastMessage
            {
                Kind = ToastKind.Warning,
                Message = "该记录没有逐文件明细（旧版本生成）",
                DurationMs = 2200,
            });
            return;
        }
        var root = App.MainWindow.Content?.XamlRoot;
        if (root is null) return;
        await new HistoryDetailDialog(item) { XamlRoot = root }.ShowAsync();
    }

    /// <summary>右键「删除这条记录」。</summary>
    private void OnDeleteHistoryClick(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is TransferHistoryItem item)
            ViewModel.Delete(item);
    }
}
