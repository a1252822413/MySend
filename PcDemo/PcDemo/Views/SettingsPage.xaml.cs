// SettingsPage codebehind：暴露 DeviceTypeOptions 给 ComboBox。
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PcDemo.Models.Dto;
using PcDemo.ViewModels;
using Windows.Storage.Pickers;

namespace PcDemo.Views;

public sealed partial class SettingsPage : Page
{
    public SettingsViewModel ViewModel { get; }

    // ComboBox 选项列表；保持与 enum 一致的字符串显示
    public object[] DeviceTypeOptions { get; } =
        { DeviceType.Desktop, DeviceType.Mobile, DeviceType.Web, DeviceType.Headless, DeviceType.Server };

    public SettingsPage()
    {
        ViewModel = App.Services.GetRequiredService<SettingsViewModel>();
        this.InitializeComponent();
        this.DataContext = ViewModel;
    }

    /// <summary>
    /// 弹 FolderPicker 选择保存目录，更新 ViewModel.Destination。
    /// 支持中文目录名（.NET Path/File API 原生支持 Unicode）。
    /// </summary>
    private async void OnBrowseDestinationClick(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker();
        // MSIX/WinUI3 必需：通过 InitializeWithWindow 关联到主窗口句柄，否则 picker 抛 "invalid window handle" 异常
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

        picker.ViewMode = PickerViewMode.List;
        picker.SuggestedStartLocation = PickerLocationId.Downloads;
        picker.FileTypeFilter.Add("*");

        var folder = await picker.PickSingleFolderAsync();
        if (folder != null)
        {
            ViewModel.Destination = folder.Path;
        }
    }

    private bool _pinSyncing;

    private void OnPinPasswordChanged(object sender, RoutedEventArgs e)
    {
        if (_pinSyncing) return;
        _pinSyncing = true;
        ViewModel.Pin = PinPasswordBox.Password;
        _pinSyncing = false;
    }

    private void OnPinTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_pinSyncing) return;
        _pinSyncing = true;
        ViewModel.Pin = PinVisibleBox.Text;
        _pinSyncing = false;
    }

    private void OnPinToggleClick(object sender, RoutedEventArgs e)
    {
        _pinSyncing = true;
        if (PinPasswordBox.Visibility == Visibility.Visible)
        {
            // → 显示明文
            PinVisibleBox.Text = PinPasswordBox.Password;
            PinPasswordBox.Visibility = Visibility.Collapsed;
            PinVisibleBox.Visibility = Visibility.Visible;
        }
        else
        {
            // → 隐藏为密码
            PinPasswordBox.Password = PinVisibleBox.Text;
            PinPasswordBox.Visibility = Visibility.Visible;
            PinVisibleBox.Visibility = Visibility.Collapsed;
        }
        _pinSyncing = false;
    }
}

