// TopToast：内容区右上角非模态提醒。
// 取代旧 CenteredToast：不再铺全屏遮罩、不再盖住页面标题与内容。
// 16ms 计时器驱动「淡入 160ms → 停留（悬停暂停）→ 淡出 160ms」，
// 与旧控件同一套 DispatcherQueueTimer 机制，避免引入 Storyboard 的模板依赖。
using System;
using CommunityToolkit.Mvvm.Messaging;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers; // AutomationLiveSetting 枚举在此命名空间
using Microsoft.UI.Xaml.Controls;
using PcDemo.Messages;

namespace PcDemo.Controls;

public sealed partial class TopToast : UserControl
{
    private enum Phase { In, Hold, Out }

    private DispatcherQueueTimer? _timer;
    private bool _registered;
    private bool _paused;
    private Phase _phase;
    private int _tick;
    private int _elapsedMs;
    private int _durationMs;
    private Action? _primaryAction;
    private Action? _secondaryAction;

    private const int TickMs = 16;
    private const int TransitionTicks = 10; // 160ms

    public TopToast()
    {
        this.InitializeComponent();
        // 悬停暂停自动收起，方便用户点动作按钮或读完失败原因
        PointerEntered += (_, _) => _paused = true;
        PointerExited += (_, _) => _paused = false;
        ApplyVisual(ToastVisual.Info);
    }

    /// <summary>附加到 ShellWindow 根 Grid 的内容区（Row=1）右上角，作为最后一个子元素置于最上层。</summary>
    public static TopToast AttachTo(Grid rootGrid)
    {
        var toast = new TopToast
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
        };
        if (rootGrid.RowDefinitions.Count > 1)
        {
            Grid.SetRow(toast, 1);
        }
        Canvas.SetZIndex(toast, 999);
        rootGrid.Children.Add(toast);
        return toast;
    }

    /// <summary>注册消息总线（只注册一次）。通用提示与 4 态传输结果走同一个悬浮层。</summary>
    public void EnsureRegistered()
    {
        if (_registered) return;
        _registered = true;

        WeakReferenceMessenger.Default.Register<ShowToastMessage>(this, (_, m) =>
            DispatcherQueue.TryEnqueue(() => Show(m)));

        WeakReferenceMessenger.Default.Register<TransferResultMessage>(this, (_, m) =>
            DispatcherQueue.TryEnqueue(() => Show(m)));
    }

    // ------------------------------------------------------------------
    // 通用提示：把旧代码的 "标题\n正文" 约定拆成标题 + 副文本
    // ------------------------------------------------------------------
    public void Show(ShowToastMessage m)
    {
        var raw = (m.Message ?? string.Empty).Replace("\\n", "\n");
        var cut = raw.IndexOf('\n');
        var title = cut > 0 ? raw[..cut].Trim() : "快传";
        var detail = cut > 0 ? raw[(cut + 1)..].Replace("\n", " · ").Trim() : raw.Trim();

        var visual = m.Kind switch
        {
            ToastKind.Success => ToastVisual.Ok,
            ToastKind.Error => ToastVisual.Fail,
            _ => ToastVisual.Info,
        };
        Present(title, detail, visual, m.DurationMs > 0 ? m.DurationMs : 2500,
                string.Empty, string.Empty, null, null);
    }

    // ------------------------------------------------------------------
    // 4 态传输结果：接收/发送 × 成功/失败
    // ------------------------------------------------------------------
    public void Show(TransferResultMessage m)
    {
        var (visual, defaultDuration) = m.Kind switch
        {
            TransferResultKind.ReceiveSuccess or TransferResultKind.SendSuccess => (ToastVisual.Ok, 4000),
            TransferResultKind.ReceiveFailure or TransferResultKind.SendFailure => (ToastVisual.Fail, 8000),
            _ => (ToastVisual.Info, 4000),
        };
        var duration = m.DurationMs > 0 ? m.DurationMs : defaultDuration;
        Present(m.Title, m.Detail, visual, duration,
                m.PrimaryActionText, m.SecondaryActionText,
                m.PrimaryAction, m.SecondaryAction);
    }

    private void Present(string title, string detail, ToastVisual visual, int durationMs,
                         string primaryText, string secondaryText,
                         Action? primary, Action? secondary)
    {
        TitleText.Text = string.IsNullOrWhiteSpace(title) ? "快传" : title;
        DetailText.Text = detail ?? string.Empty;
        _primaryAction = primary;
        _secondaryAction = secondary;

        var hasPrimary = !string.IsNullOrWhiteSpace(primaryText);
        var hasSecondary = !string.IsNullOrWhiteSpace(secondaryText);
        PrimaryButton.Content = primaryText;
        SecondaryButton.Content = secondaryText;
        PrimaryButton.Visibility = hasPrimary ? Visibility.Visible : Visibility.Collapsed;
        SecondaryButton.Visibility = hasSecondary ? Visibility.Visible : Visibility.Collapsed;
        ActionRow.Visibility = hasPrimary || hasSecondary ? Visibility.Visible : Visibility.Collapsed;

        ApplyVisual(visual);

        _durationMs = Math.Max(1200, durationMs);
        _elapsedMs = 0;
        _tick = 0;
        _paused = false;
        _phase = Phase.In;
        Visibility = Visibility.Visible;
        CardBorder.Opacity = 0;
        CardTranslate.Y = -12;
        TimerBar.Value = 100;
        TimerBarFail.Value = 100;

        _timer?.Stop();
        _timer = DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(TickMs);
        _timer.Tick += (_, _) => OnTick();
        _timer.Start();
    }

    private void OnTick()
    {
        switch (_phase)
        {
            case Phase.In:
            {
                _tick++;
                var p = Math.Min(1.0, _tick / (double)TransitionTicks);
                CardBorder.Opacity = p;
                CardTranslate.Y = -12 * (1 - p);
                if (p >= 1)
                {
                    _phase = Phase.Hold;
                    _tick = 0;
                }
                break;
            }
            case Phase.Hold:
            {
                if (_paused) break;
                _elapsedMs += TickMs;
                var remaining = Math.Max(0, 100 * (1 - _elapsedMs / (double)_durationMs));
                TimerBar.Value = remaining;
                TimerBarFail.Value = remaining;
                if (_elapsedMs >= _durationMs)
                {
                    _phase = Phase.Out;
                    _tick = 0;
                }
                break;
            }
            case Phase.Out:
            {
                _tick++;
                var p = Math.Min(1.0, _tick / (double)TransitionTicks);
                CardBorder.Opacity = 1 - p;
                if (p >= 1)
                {
                    HideNow();
                }
                break;
            }
        }
    }

    private void HideNow()
    {
        _timer?.Stop();
        _timer = null;
        _paused = false;
        CardBorder.Opacity = 0;
        Visibility = Visibility.Collapsed;
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => HideNow();

    private void OnPrimaryActionClick(object sender, RoutedEventArgs e)
    {
        var action = _primaryAction;
        HideNow();
        action?.Invoke();
    }

    private void OnSecondaryActionClick(object sender, RoutedEventArgs e)
    {
        var action = _secondaryAction;
        HideNow();
        action?.Invoke();
    }

    private enum ToastVisual { Ok, Fail, Info }

    private void ApplyVisual(ToastVisual visual)
    {
        IconOk.Visibility = visual == ToastVisual.Ok ? Visibility.Visible : Visibility.Collapsed;
        IconFail.Visibility = visual == ToastVisual.Fail ? Visibility.Visible : Visibility.Collapsed;
        IconInfo.Visibility = visual == ToastVisual.Info ? Visibility.Visible : Visibility.Collapsed;
        var isFail = visual == ToastVisual.Fail;
        TimerBar.Visibility = isFail ? Visibility.Collapsed : Visibility.Visible;
        TimerBarFail.Visibility = isFail ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetLiveSetting(RootGrid,
            visual == ToastVisual.Fail ? AutomationLiveSetting.Assertive : AutomationLiveSetting.Polite);
        AutomationProperties.SetName(RootGrid, visual == ToastVisual.Fail ? "传输失败提醒" : "快传提醒");
    }
}
