// 设备卡片网格的动态布局：按可用宽度决定列数(1..4)，卡片自动拉伸填满行宽。
// 解决“固定 280 卡宽在临界宽度下右侧留大空白 / 缩放跨临界突然跳列”的问题。
using Microsoft.UI.Xaml.Controls;

namespace PcDemo.Helpers;

internal static class DeviceTileLayout
{
    /// <summary>单卡最小逻辑宽度（低于则减少列数）。</summary>
    public const double MinCardWidth = 300;

    /// <summary>最多列数。</summary>
    public const int MaxColumns = 4;

    /// <summary>卡片间水平间距（与卡片 ItemContainerStyle 的 Margin 右/下一致）。
    /// 注意：该间距由卡片自身 Margin 提供，ItemsWrapGrid 格子只需平均分满可用宽，无需再让出一份。</summary>
    public const double CardGap = 10;

    /// <summary>按容器当前宽度重排卡片：N = clamp(列数)，格子宽 = 可用宽 / N（占满整行，间距由卡片 Margin 承担）。</summary>
    public static void UpdateLayout(ListView list, double availableWidth)
    {
        if (list?.ItemsPanelRoot is not ItemsWrapGrid wrap) return;
        if (availableWidth <= 0) availableWidth = list.ActualWidth;
        if (availableWidth <= 0) return;

        var n = Math.Max(1, Math.Min(MaxColumns,
            (int)Math.Floor((availableWidth + CardGap) / (MinCardWidth + CardGap))));
        wrap.ItemWidth = availableWidth / n;
    }
}
