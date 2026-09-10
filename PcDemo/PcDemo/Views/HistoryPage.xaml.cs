// HistoryPage codebehind：传输历史列表页。
using System.Diagnostics;
using System.IO;
using CommunityToolkit.Mvvm.Messaging;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
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
        this.Loaded += (_, _) =>
        {
            ViewModel.Refresh();
            UpdateFilterButtonStyles();
        };
        // 筛选条件变化时刷新按钮高亮
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(HistoryViewModel.FilterDirection))
                UpdateFilterButtonStyles();
        };
    }

    /// <summary>方向筛选按钮点击：0=全部, 1=发送, 2=接收</summary>
    private void OnFilterAllClick(object sender, RoutedEventArgs e) => ViewModel.FilterDirection = 0;
    private void OnFilterSendClick(object sender, RoutedEventArgs e) => ViewModel.FilterDirection = 1;
    private void OnFilterReceiveClick(object sender, RoutedEventArgs e) => ViewModel.FilterDirection = 2;

    /// <summary>更新筛选按钮高亮：选中的按钮用强调色背景。</summary>
    private void UpdateFilterButtonStyles()
    {
        var accentBg = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["AccentFillColorDefaultBrush"];
        var accentFg = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextOnAccentFillColorPrimaryBrush"];
        var transparentBg = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);

        (Button btn, bool active)[] buttons = {
            (FilterAllBtn, ViewModel.FilterDirection == 0),
            (FilterSendBtn, ViewModel.FilterDirection == 1),
            (FilterReceiveBtn, ViewModel.FilterDirection == 2),
        };
        foreach (var (btn, active) in buttons)
        {
            btn.Background = active ? accentBg : transparentBg;
            btn.Foreground = active ? accentFg : (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorPrimaryBrush"];
            btn.FontWeight = active ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
        }
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
