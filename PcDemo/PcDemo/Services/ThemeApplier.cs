// ThemeApplier：把 AppSettings.ThemeMode 应用到当前 UI（MSIX Packaged）。
// - 同时更新 Content.RequestedTheme（前景色/控件主题）
// - 同时更新 Window.SystemBackdrop（Mica/Acrylic），让 Win11 自动给窗口圆角 + 主题自适应半透明背景
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace PcDemo.Services;

public static class ThemeApplier
{
    /// <summary>应用主题（启动早期调用 + 设置保存时调用）。</summary>
    public static void Apply(int themeMode)
    {
        try
        {
            if (!PcDemo.App.TryGetMainWindow(out var window) || window is null) return;

            var theme = themeMode switch
            {
                1 => ElementTheme.Light,
                2 => ElementTheme.Dark,
                _ => ElementTheme.Default,
            };

            // 1) 前景主题（控件/文字/边框颜色随主题切换）
            if (window.Content is FrameworkElement fe)
            {
                fe.RequestedTheme = theme;
            }

            // 2) 背景 SystemBackdrop（决定窗口背景色 + 半透明效果 + Win11 自动圆角）
            //    浅色/跟随系统：Mica（更贴近桌面）；深色：Acrylic（更明显的半透明毛玻璃）
            window.SystemBackdrop = theme switch
            {
                ElementTheme.Dark => new DesktopAcrylicBackdrop(),
                _ => new MicaBackdrop(),
            };
        }
        catch (Exception ex)
        {
            App.LogDiag($"[Theme] Apply failed: {ex.Message}");
        }
    }
}
