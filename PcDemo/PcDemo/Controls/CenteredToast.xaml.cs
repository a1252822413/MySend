// CenteredToast：全局居中的轻量浮动提示（替代顶部 InfoBar 横幅）。
// 用法：
//   1) ShellWindow 根 Grid 末尾放一个 CenteredToast（或 AttachTo）
//   2) 任何地方发 WeakReferenceMessenger.Default.Send(new ShowToastMessage{...})
//   3) 控件自注册 WeakReferenceMessenger 订阅消息，自己做动画。
//
// 动画（24ms 一帧，三阶段）：
//   - 淡入 260ms：遮罩 0→12% 黑  +  卡片 Opacity 0→1 + Scale 0.94→1.0
//   - 停留 DurationMs（Success/Info=1800、Warning=2200、Error=2800）
//   - 淡出 320ms：遮罩 12%→0       +  卡片 Opacity 1→0 + Scale 1.0→0.97
//   - 淡出结束 → Visibility = Collapsed（防止残留透明框/残影）
using CommunityToolkit.Mvvm.Messaging;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PcDemo.Messages;
using Windows.UI;

namespace PcDemo.Controls;

public sealed partial class CenteredToast : UserControl
{
    // ---------- 颜色：左竖条 + 图标背景 + 图标前景（统一色，强对比度）----------
    private static readonly (Brush Bar, Brush IconBg, Brush IconFg) SuccessStyle = (
        new SolidColorBrush(Color.FromArgb(0xFF, 0x2F, 0xB0, 0x54)),   // #2FB054
        new SolidColorBrush(Color.FromArgb(0x16, 0x2F, 0xB0, 0x54)),   // 8.8% 绿
        new SolidColorBrush(Color.FromArgb(0xFF, 0x2F, 0xB0, 0x54)));

    private static readonly (Brush Bar, Brush IconBg, Brush IconFg) ErrorStyle = (
        new SolidColorBrush(Color.FromArgb(0xFF, 0xC6, 0x28, 0x28)),   // #C62828
        new SolidColorBrush(Color.FromArgb(0x16, 0xC6, 0x28, 0x28)),   // 8.8% 红
        new SolidColorBrush(Color.FromArgb(0xFF, 0xC6, 0x28, 0x28)));

    private static readonly (Brush Bar, Brush IconBg, Brush IconFg) InfoStyle = (
        new SolidColorBrush(Color.FromArgb(0xFF, 0x00, 0x6C, 0xBE)),   // #006CBE
        new SolidColorBrush(Color.FromArgb(0x16, 0x00, 0x6C, 0xBE)),   // 8.8% 蓝
        new SolidColorBrush(Color.FromArgb(0xFF, 0x00, 0x6C, 0xBE)));

    private static readonly (Brush Bar, Brush IconBg, Brush IconFg) WarningStyle = (
        new SolidColorBrush(Color.FromArgb(0xFF, 0xE8, 0x7D, 0x00)),   // #E87D00
        new SolidColorBrush(Color.FromArgb(0x16, 0xE8, 0x7D, 0x00)),   // 8.8% 橙
        new SolidColorBrush(Color.FromArgb(0xFF, 0xE8, 0x7D, 0x00)));

    // Segoe MDL2 Assets glyphs
    private const string GSuccess = "\uE73E"; // ✓
    private const string GError   = "\uE711"; // ✗
    private const string GInfo    = "\uE946"; // ℹ
    private const string GWarn    = "\uE7BA"; // ⚠

    // 目标遮罩最终不透明度：28% 黑（肉眼明显压暗背景，衬托卡片）
    private const double MaskTarget = 0.28;

    // ---------- 依赖属性 ----------
    public string Title
    {
        get => (string)GetValue(TitleProperty);
        set => SetValue(TitleProperty, value);
    }
    public static readonly DependencyProperty TitleProperty =
        DependencyProperty.Register(nameof(Title), typeof(string), typeof(CenteredToast),
            new PropertyMetadata(string.Empty));

    public string Message
    {
        get => (string)GetValue(MessageProperty);
        set => SetValue(MessageProperty, value);
    }
    public static readonly DependencyProperty MessageProperty =
        DependencyProperty.Register(nameof(Message), typeof(string), typeof(CenteredToast),
            new PropertyMetadata(string.Empty));

    private DispatcherQueueTimer? _timer;
    private bool _registered;

    public CenteredToast()
    {
        this.InitializeComponent();
        ApplyStyle(ToastKind.Success);
    }

    /// <summary>便捷附加：把控件加入到指定 Grid 的最后一个子元素（ZIndex 最顶层）。</summary>
    public static CenteredToast AttachTo(Grid rootGrid)
    {
        var toast = new CenteredToast
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment   = VerticalAlignment.Stretch,
        };
        Grid.SetRowSpan(toast, int.MaxValue);
        // Grid.ColumnSpan 也拉满（万一 ShellWindow 根 Grid 以后有列定义也不怕）
        Grid.SetColumnSpan(toast, int.MaxValue);
        Canvas.SetZIndex(toast, 999);
        rootGrid.Children.Add(toast);
        return toast;
    }

    /// <summary>注册消息总线（只注册一次）。</summary>
    public void EnsureRegistered()
    {
        if (_registered) return;
        _registered = true;
        WeakReferenceMessenger.Default.Register<ShowToastMessage>(this, (_, m) =>
        {
            DispatcherQueue.TryEnqueue(() => Show(m));
        });
    }

    public void Show(ShowToastMessage m) => Show(m.Kind, m.Message, m.Title(), m.DurationMs);

    public void Show(ToastKind kind, string message, string? title = null, int durationMs = -1)
    {
        Title = string.IsNullOrEmpty(title) ? DefaultTitle(kind) : title;
        Message = message?.Replace("\\n", "\n") ?? string.Empty;
        ApplyStyle(kind);

        int hold = durationMs > 0 ? durationMs : DefaultDuration(kind);

        // 砍上一条的尾巴（防止连续复制多条堆叠）
        _timer?.Stop();

        // 动画开始前先统一初始状态（避免上一条淡入中途残留不一致）
        Visibility = Visibility.Visible;
        OverlayMask.Visibility = Visibility.Visible;
        OverlayMask.Opacity = 0;
        CardBorder.Opacity = 0;
        CardScale.ScaleX = 0.94;
        CardScale.ScaleY = 0.94;

        const int TickMs = 16; // 约 60fps，动画更顺滑、显效更快
        int fadeInTicks  = (int)Math.Ceiling(130.0 / TickMs);  // 淡入 130ms（之前 260ms，砍一半）
        int holdTicks    = Math.Max(1, hold / TickMs);         // 停留（保持原 1.8s/2.2s/2.8s）
        int fadeOutTicks = (int)Math.Ceiling(180.0 / TickMs);  // 淡出 180ms（之前 320ms，约 44% 时长）

        int tick = 0;
        double op = 0, sx = 0.94, sy = 0.94, mask = 0;
        double fadeInOpInc = 1.0 / Math.Max(1, fadeInTicks);
        double fadeInMaskInc = MaskTarget / Math.Max(1, fadeInTicks);
        double fadeOutOpDec = 1.0 / Math.Max(1, fadeOutTicks);
        double fadeOutMaskDec = MaskTarget / Math.Max(1, fadeOutTicks);

        _timer = DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(TickMs);
        _timer.Tick += (_, _) =>
        {
            tick++;
            if (tick <= fadeInTicks)
            {
                // 淡入：卡片 0→1 + 遮罩 0→MaskTarget + 缩放 0.94→1.0
                op += fadeInOpInc;
                mask += fadeInMaskInc;
                var p = tick / (double)fadeInTicks;
                sx = 0.94 + 0.06 * p;
                sy = sx;
                if (op > 1) op = 1;
                if (mask > MaskTarget) mask = MaskTarget;
                ApplyVisual();
            }
            else if (tick <= fadeInTicks + holdTicks)
            {
                // 停留
                if (op != 1 || mask != MaskTarget)
                {
                    op = 1; mask = MaskTarget; sx = 1.0; sy = 1.0;
                    ApplyVisual();
                }
            }
            else
            {
                // 淡出 → 结束 → Visibility.Collapsed（避免透明残影）
                op -= fadeOutOpDec;
                mask -= fadeOutMaskDec;
                var p = (tick - fadeInTicks - holdTicks) / (double)fadeOutTicks;
                if (p >= 1)
                {
                    _timer.Stop();
                    // 动画走完：两部分一起彻底隐藏
                    OverlayMask.Visibility = Visibility.Collapsed;
                    OverlayMask.Opacity = 0;
                    CardBorder.Opacity = 0;
                    Visibility = Visibility.Collapsed;
                    return;
                }
                sx = 1.0 - 0.03 * p;
                sy = sx;
                if (op < 0) op = 0;
                if (mask < 0) mask = 0;
                ApplyVisual();
            }

            void ApplyVisual()
            {
                CardBorder.Opacity = op;
                CardScale.ScaleX = sx;
                CardScale.ScaleY = sy;
                OverlayMask.Opacity = mask;
            }
        };
        _timer.Start();
    }

    // ---------- 工具 ----------

    private static string DefaultTitle(ToastKind k) => k switch
    {
        ToastKind.Success => "操作成功",
        ToastKind.Error   => "操作失败",
        ToastKind.Warning => "提示",
        _                 => "消息",
    };

    private static int DefaultDuration(ToastKind k) => k switch
    {
        ToastKind.Success => 1800,
        ToastKind.Info    => 1800,
        ToastKind.Warning => 2200,
        ToastKind.Error   => 2800,
        _                 => 2000,
    };

    private void ApplyStyle(ToastKind kind)
    {
        (Brush bar, Brush iconBg, Brush iconFg) = kind switch
        {
            ToastKind.Error   => ErrorStyle,
            ToastKind.Warning => WarningStyle,
            ToastKind.Info    => InfoStyle,
            _                 => SuccessStyle,
        };
        AccentBar.Background   = bar;
        IconBorder.Background  = iconBg;
        IconGlyph.Foreground   = iconFg;
        IconGlyph.Glyph = kind switch
        {
            ToastKind.Error   => GError,
            ToastKind.Warning => GWarn,
            ToastKind.Info    => GInfo,
            _                 => GSuccess,
        };
    }
}

/// <summary>消息扩展：从 Kind 推导默认标题。</summary>
file static class ShowToastMessageExtensions
{
    public static string Title(this ShowToastMessage m)
        => !string.IsNullOrWhiteSpace(m.Message) && m.Message.Contains('\n')
            ? Default(m.Kind)
            : Default(m.Kind);

    private static string Default(ToastKind k) => k switch
    {
        ToastKind.Success => "操作成功",
        ToastKind.Error   => "操作失败",
        ToastKind.Warning => "提示",
        _                 => "消息",
    };
}
