// HistoryPage codebehind：传输历史列表页。
using System.Diagnostics;
using System.IO;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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
}
