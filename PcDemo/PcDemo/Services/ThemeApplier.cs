// ThemeApplier：把 AppSettings.ThemeMode 应用到当前 UI。
// - Content.RequestedTheme 决定前景/控件主题
// - Window.SystemBackdrop 决定窗口材质
//
// 设计约束（design/unified v1.2 §1）：窗口材质与动画强弱不是产品设置项，
// 应用内只保留「主题模式」三选。材质一律交给系统：WinUI 的 MicaBackdrop 会按
// 系统主题、电源状态、减少透明效果与高对比度自动降级为亚克力或纯色，
// 所以这里不再按"深色→亚克力"做应用侧的人为映射（那等于偷偷做了半个材质开关）。
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

            // 2) 系统材质：跟随系统，应用不提供开关、不按深浅主题改档位
            window.SystemBackdrop = new MicaBackdrop();
        }
        catch (System.Exception ex)
        {
            App.LogDiag($"[Theme] Apply failed: {ex.Message}");
        }
    }
}
