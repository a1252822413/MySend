// FlowPanel：轻量自动换行面板。子元素按可用宽度从左到右排列，放不下自动折行。
// 逐行测量/布置保持一致，行内子元素按其 VerticalAlignment 垂直对齐。
// 用于发送页操作条等「窄窗口不截断、自动换行」的场景。
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace PcDemo.Controls
{
    /// <summary>自动换行面板：按可用宽度顺序排布子元素，放不下自动折行。</summary>
    public sealed class FlowPanel : Panel
    {
        public static readonly DependencyProperty HorizontalSpacingProperty =
            DependencyProperty.Register(nameof(HorizontalSpacing), typeof(double), typeof(FlowPanel),
                new PropertyMetadata(8.0, OnSpacingChanged));

        public static readonly DependencyProperty VerticalSpacingProperty =
            DependencyProperty.Register(nameof(VerticalSpacing), typeof(double), typeof(FlowPanel),
                new PropertyMetadata(8.0, OnSpacingChanged));

        /// <summary>相邻子元素之间的水平间距。</summary>
        public double HorizontalSpacing
        {
            get => (double)GetValue(HorizontalSpacingProperty);
            set => SetValue(HorizontalSpacingProperty, value);
        }

        /// <summary>相邻行之间的垂直间距。</summary>
        public double VerticalSpacing
        {
            get => (double)GetValue(VerticalSpacingProperty);
            set => SetValue(VerticalSpacingProperty, value);
        }

        private static void OnSpacingChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
            => ((FlowPanel)d).InvalidateMeasure();

        // 测量阶段记录的可见子元素（保持与 Children 顺序一致），供布置复用
        private readonly List<FrameworkElement> _visible = new();

        protected override Size MeasureOverride(Size availableSize)
        {
            _visible.Clear();
            foreach (var child in Children)
            {
                if (child is FrameworkElement fe && fe.Visibility != Visibility.Collapsed)
                {
                    fe.Measure(new Size(double.PositiveInfinity, availableSize.Height));
                    _visible.Add(fe);
                }
            }

            var hSpacing = HorizontalSpacing;
            var width = double.IsInfinity(availableSize.Width) ? double.MaxValue : availableSize.Width;

            var totalHeight = 0.0;
            var lineWidth = 0.0;      // 当前行已占用宽
            var maxLineWidth = 0.0;   // 最宽一行
            var currentLineHeight = 0.0;
            var lineCount = 0;

            for (var i = 0; i < _visible.Count; i++)
            {
                var child = _visible[i];
                var w = child.DesiredSize.Width + child.Margin.Left + child.Margin.Right;
                var h = child.DesiredSize.Height + child.Margin.Top + child.Margin.Bottom;

                if (i > 0 && lineWidth + w > width)
                {
                    // 折行：结算上一行
                    maxLineWidth = System.Math.Max(maxLineWidth, lineWidth);
                    totalHeight += currentLineHeight;
                    lineWidth = 0;
                    currentLineHeight = 0;
                    lineCount++;
                }

                if (lineWidth > 0) lineWidth += hSpacing; // 行内首元素前不加间距
                lineWidth += w;
                currentLineHeight = System.Math.Max(currentLineHeight, h);
            }

            if (_visible.Count > 0)
            {
                maxLineWidth = System.Math.Max(maxLineWidth, lineWidth);
                totalHeight += currentLineHeight;
                lineCount++;
            }

            // 行间间距：N 行 → N-1 个间距
            if (lineCount > 1) totalHeight += VerticalSpacing * (lineCount - 1);

            return new Size(System.Math.Min(availableSize.Width, maxLineWidth), totalHeight);
        }

        protected override Size ArrangeOverride(Size finalSize)
        {
            var hSpacing = HorizontalSpacing;
            var vSpacing = VerticalSpacing;
            var width = double.IsInfinity(finalSize.Width) ? double.MaxValue : finalSize.Width;

            var y = 0.0;
            var rowStart = 0;
            var i = 0;

            while (i < _visible.Count)
            {
                // 计算本行应包含的子元素 [rowStart, next) 以及本行高度
                var lineWidth = 0.0;
                var next = i;
                while (next < _visible.Count)
                {
                    var child = _visible[next];
                    var w = child.DesiredSize.Width + child.Margin.Left + child.Margin.Right;
                    if (next > rowStart && lineWidth + w > width) break;
                    if (lineWidth > 0) lineWidth += hSpacing;
                    lineWidth += w;
                    next++;
                }

                // 本行高度
                var lineHeight = 0.0;
                for (var k = rowStart; k < next; k++)
                {
                    var ch = _visible[k];
                    lineHeight = System.Math.Max(lineHeight, ch.DesiredSize.Height + ch.Margin.Top + ch.Margin.Bottom);
                }

                // 逐子布置（行内垂直居中）
                var x = 0.0;
                var placed = false;
                for (var k = rowStart; k < next; k++)
                {
                    var child = _visible[k];
                    var m = child.Margin;
                    var cw = child.DesiredSize.Width;
                    var ch = child.DesiredSize.Height;

                    // 间距只加在“已有元素之后”，零宽/行首元素不产生前置间距
                    if (placed) x += hSpacing;

                    double top;
                    switch (child.VerticalAlignment)
                    {
                        case VerticalAlignment.Top: top = m.Top; break;
                        case VerticalAlignment.Bottom: top = lineHeight - ch - m.Bottom; break;
                        default: top = m.Top + (lineHeight - ch - m.Top - m.Bottom) / 2.0; break;
                    }
                    if (top < 0) top = 0;

                    child.Arrange(new Rect((float)(x + m.Left), (float)(y + top), (float)cw, (float)ch));
                    x += cw + m.Left + m.Right;
                    placed = true;
                }

                y += lineHeight + vSpacing;
                rowStart = next;
                i = next;
            }

            return finalSize;
        }
    }
}

