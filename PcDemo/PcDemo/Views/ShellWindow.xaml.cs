// ShellWindow codebehind：导航在接收页/设置页之间切换。
using System.Runtime.InteropServices;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PcDemo.Controls;
using PcDemo.Models;
using PcDemo.ViewModels;
using Windows.Graphics;
using WinRT.Interop;

namespace PcDemo.Views;

public sealed partial class ShellWindow : Window
{
    private readonly ShellViewModel _viewModel;
    private CenteredToast? _toast;

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

        // ---- 全局居中 Toast：挂在 RootGrid 最上层（ZIndex 999），覆盖所有页面/侧边栏 ----
        _toast = CenteredToast.AttachTo(RootGrid);
        _toast.EnsureRegistered();

        // 默认导航到接收页
        NavView.SelectedItem = NavView.MenuItems[0];
        ContentFrame.Navigate(typeof(ReceivePage));

        // 默认窗口大小 1000x700（按 DPI 缩放，可拖动缩放）
        TrySetInitialSize(1000, 700);

        // 拖拽缩小时钳制到最小逻辑尺寸，避免 SendPage 等固定行高布局被压坏
        TryClampMinWindowSize();

        // 系统按钮（最小化/最大化/关闭）高度对齐 48px 自定义顶栏
        AlignTitleBarHeight();
    }

    /// <summary>跳到「发送」页并预选目标设备（接收页双击设备卡调用）。</summary>
    public void ShowSendPageForDevice(Device device)
    {
        // 先选中「发送」菜单项 → OnSelectionChanged → Frame 导航到 SendPage
        foreach (var item in NavView.MenuItems)
        {
            if (item is NavigationViewItem nvi && nvi.Tag?.ToString() == "Send")
            {
                NavView.SelectedItem = nvi;
                break;
            }
        }
        // 再设置目标设备：SendViewModel 是单例，SendPage 的 SelectedItem(双向) 会同步高亮选中
        App.Services.GetRequiredService<SendViewModel>().SelectedTarget = device;
    }

    // 最小窗口逻辑尺寸（避免布局被压缩破坏）
    private const int MinLogicalWidth = 720;
    private const int MinLogicalHeight = 560;

    /// <summary>拖动缩小时钳制到最小尺寸（按 DPI 缩放）。仅在普通 Restored 态钳制，不干扰最大化/全屏。</summary>
    private void TryClampMinWindowSize()
    {
        try
        {
            AppWindow.Changed += (s, e) =>
            {
                if (!e.DidSizeChange) return;
                if (s.Presenter is not OverlappedPresenter op) return;
                if (op.State != OverlappedPresenterState.Restored) return;
                try
                {
                    var hwnd = WindowNative.GetWindowHandle(this);
                    var dpi = GetDpiForWindow(hwnd);
                    var scale = dpi > 0 ? dpi / 96.0 : 1.0;
                    var minW = (int)(MinLogicalWidth * scale);
                    var minH = (int)(MinLogicalHeight * scale);
                    if (s.Size.Width < minW || s.Size.Height < minH)
                    {
                        s.Resize(new SizeInt32(
                            Math.Max(s.Size.Width, minW),
                            Math.Max(s.Size.Height, minH)));
                    }
                }
                catch
                {
                    // 钳制失败不阻塞窗口
                }
            };
        }
        catch
        {
            // 订阅失败不影响窗口
        }
    }

    /// <summary>汉堡按钮：收起/展开侧边栏。</summary>
    private void OnPaneToggleClick(object sender, RoutedEventArgs e)
    {
        NavView.IsPaneOpen = !NavView.IsPaneOpen;
    }

    /// <summary>系统 caption buttons 用 Standard 档（32px），严格对齐 32px 自定义顶栏，
    /// 无溢出无盲区，系统最小化/最大化/关闭按钮视觉与点击区精确匹配。</summary>
    private void AlignTitleBarHeight()
    {
        try
        {
            AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Standard;
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
