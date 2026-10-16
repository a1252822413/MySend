// HistoryPage codebehind：传输历史列表页。
using System.Diagnostics;
using System.IO;
using CommunityToolkit.Mvvm.Messaging;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
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
        App.LogDiag("[HistoryPage] ctor: enter");
        ViewModel = App.Services.GetRequiredService<HistoryViewModel>();
        this.InitializeComponent();
        App.LogDiag("[HistoryPage] ctor: InitializeComponent 完成");
        this.Loaded += (_, _) =>
        {
            // 诊断面包屑：与 ReceivePage/ShellWindow 一样的 LogDiag 约定，
            // 便于定位"进入页面后卡住"这类问题（是卡在数据刷新、样式还是动画）。
            App.LogDiag("[HistoryPage] OnLoaded: enter");
            ViewModel.Refresh();
            App.LogDiag("[HistoryPage] OnLoaded: Refresh 完成");
            UpdateFilterButtonStyles();
            App.LogDiag("[HistoryPage] OnLoaded: 筛选按钮样式完成");
            // 空态图标呼吸动画（WinUI 无 WPF 式 EventTrigger，需 code-behind 触发）
            EmptyPulseStoryboard.Begin();
            App.LogDiag("[HistoryPage] OnLoaded: 空态动画已启动，页面就绪");
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

    /// <summary>清空全部历史：二次确认后再执行（不可撤销）。</summary>
    private async void OnClearClick(object sender, RoutedEventArgs e)
    {
        var root = App.MainWindow.Content?.XamlRoot;
        if (root is null) return;
        var confirm = new ContentDialog
        {
            XamlRoot = root,
            Title = "清空传输历史？",
            Content = "将删除全部收发记录（不会删除已接收的文件本身）。此操作不可撤销。",
            PrimaryButtonText = "清空",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };
        try
        {
            if (await confirm.ShowAsync() == ContentDialogResult.Primary)
                ViewModel.Clear();
        }
        catch (Exception ex)
        {
            App.LogDiag($"[History] clear confirm failed: {ex.Message}");
        }
    }

    // ---------- 列表项 hover：边框点亮 + 背景微提亮（Border 无 VisualState） ----------
    // 取主题画刷一律走 ThemeBrush(key, fallback)：取不到时保留原值，避免把卡片颜色刷丢。

    private void OnItemPointerEntered(object sender, PointerRoutedEventArgs e)
    {
        if (sender is not Border b) return;
        b.BorderBrush = ThemeBrush("AccentFillColorDefaultBrush", b.BorderBrush);
        b.Background = ThemeBrush("CardBackgroundFillColorSecondaryBrush", b.Background);
    }

    private void OnItemPointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (sender is not Border b) return;
        b.BorderBrush = ThemeBrush("CardStrokeColorDefaultBrush", b.BorderBrush);
        b.Background = ThemeBrush("CardBackgroundFillColorDefaultBrush", b.Background);
    }

    private static Brush ThemeBrush(string key, Brush fallback)
        => Application.Current.Resources[key] as Brush ?? fallback;

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
