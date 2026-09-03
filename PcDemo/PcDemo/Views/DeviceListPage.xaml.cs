// DeviceListPage codebehind：事件转发到 ViewModel 命令（避免 ElementName 跨模板绑定）。
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PcDemo.Models;
using PcDemo.ViewModels;

namespace PcDemo.Views;

public sealed partial class DeviceListPage : Page
{
    public DeviceListViewModel ViewModel { get; }

    public DeviceListPage()
    {
        ViewModel = App.Services.GetRequiredService<DeviceListViewModel>();
        this.InitializeComponent();
        ViewModel.SetDispatcher(DispatcherQueue);
    }

    private void OnRefreshDiscoveredClick(object sender, RoutedEventArgs e) => ViewModel.RefreshDiscovered();

    private void OnAddWhitelistFromDiscoveredClick(object sender, RoutedEventArgs e)
        => ViewModel.AddWhitelistFromDiscoveredCommand.Execute(null);

    private void OnAddBlacklistFromDiscoveredClick(object sender, RoutedEventArgs e)
        => ViewModel.AddBlacklistFromDiscoveredCommand.Execute(null);

    private void OnAddWhitelistManualClick(object sender, RoutedEventArgs e)
        => ViewModel.AddWhitelistManualCommand.Execute(null);

    private void OnAddBlacklistManualClick(object sender, RoutedEventArgs e)
        => ViewModel.AddBlacklistManualCommand.Execute(null);

    // ToggleSwitch 切换后通知服务（IsOneWay 绑定不回写源，服务是唯一真源；
    // Changed 事件会重新 SyncList 把新值推回 entry.AutoAccept → OneWay 刷新视觉）
    private void OnWhitelistAutoAcceptToggled(object sender, RoutedEventArgs e)
    {
        if (sender is ToggleSwitch ts && ts.DataContext is DeviceListEntry entry)
        {
            ViewModel.SetWhitelistAutoAccept(entry.Fingerprint, ts.IsOn);
        }
    }

    private void OnRemoveWhitelistClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button b && b.DataContext is DeviceListEntry entry)
            ViewModel.RemoveWhitelistCommand.Execute(entry);
    }

    private void OnRemoveBlacklistClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button b && b.DataContext is DeviceListEntry entry)
            ViewModel.RemoveBlacklistCommand.Execute(entry);
    }
}
