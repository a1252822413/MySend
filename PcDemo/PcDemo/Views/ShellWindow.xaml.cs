// ShellWindow codebehind：导航在接收页/设置页之间切换。
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PcDemo.ViewModels;
using Windows.Graphics;
using WinRT.Interop;

namespace PcDemo.Views;

public sealed partial class ShellWindow : Window
{
    private readonly ShellViewModel _viewModel;

    public ShellWindow(ShellViewModel viewModel)
    {
        _viewModel = viewModel;
        this.InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        // ✅ 关键：设置 SystemBackdrop = Mica 毛玻璃
        // Win11 会自动给窗口加圆角 + 半透明主题自适应背景色；
        // 没这个的话 RequestedTheme 只改前景不改背景 → 深色主题灰白
        this.SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop();

        // 自定义标题栏区域（图标+应用名）可拖动窗口
        SetTitleBar(AppTitleBar);

        // 默认导航到接收页
        NavView.SelectedItem = NavView.MenuItems[0];
        ContentFrame.Navigate(typeof(ReceivePage));

        // 默认窗口大小 900x750（按 DPI 缩放，可拖动缩放）
        TrySetInitialSize(900, 750);

        // 系统按钮（最小化/最大化/关闭）高度对齐 48px 自定义顶栏
        AlignTitleBarHeight();
    }

    /// <summary>汉堡按钮：收起/展开侧边栏。</summary>
    private void OnPaneToggleClick(object sender, RoutedEventArgs e)
    {
        NavView.IsPaneOpen = !NavView.IsPaneOpen;
    }

    /// <summary>系统 caption buttons 用 Tall 档（48px），对齐 48px 自定义顶栏。</summary>
    private void AlignTitleBarHeight()
    {
        try
        {
            AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        }
        catch
        {
            // 设置失败不阻塞启动
        }
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    /// <summary>按 DPI 缩放设置窗口逻辑大小（用户仍可拖边框缩放）。</summary>
    private void TrySetInitialSize(int widthLogical, int heightLogical)
    {
        try
        {
            var hwnd = WindowNative.GetWindowHandle(this);
            var dpi = GetDpiForWindow(hwnd);
            var scale = dpi > 0 ? dpi / 96.0 : 1.0;
            var appWindow = AppWindow;
            if (appWindow is not null)
            {
                appWindow.Resize(new SizeInt32
                {
                    Width = (int)(widthLogical * scale),
                    Height = (int)(heightLogical * scale),
                });
            }
        }
        catch
        {
            // 设置失败不阻塞启动
        }
    }

    private void OnSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        // MenuItems 里的项 + FooterMenuItems 里的项都会触发这里，用 Tag 区分。
        var tag = (args.SelectedItem as NavigationViewItem)?.Tag?.ToString();
        switch (tag)
            {
                case "Send":
                    ContentFrame.Navigate(typeof(SendPage));
                    break;
                case "DeviceList":
                    ContentFrame.Navigate(typeof(DeviceListPage));
                    break;
                case "History":
                    ContentFrame.Navigate(typeof(HistoryPage));
                    break;
                case "Settings":
                    ContentFrame.Navigate(typeof(SettingsPage));
                    break;
                case "Receive":
                default:
                    ContentFrame.Navigate(typeof(ReceivePage));
                    break;
            }
    }
}
