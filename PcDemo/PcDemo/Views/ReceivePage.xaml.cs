// ReceivePage codebehind：通过 App.Services 拿 ReceiveViewModel，注入 DispatcherQueue 与弹窗回调。
using CommunityToolkit.Mvvm.Messaging;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.ViewModels;
using Windows.UI;

namespace PcDemo.Views;

public sealed partial class ReceivePage : Page
{
    public ReceiveViewModel ViewModel { get; }

    private ContentDialog? _progressDialog;
    private ContentDialog? _requestDialog;
    private DispatcherQueueTimer? _toastTimer;
    private bool _toastRegistered;

    // Toast 图标 Glyph（Segoe MDL2 Assets）+ 颜色
    private const string ToastGlyphSuccess = "\uE73E"; // ✓ 对勾
    private const string ToastGlyphError   = "\uE711"; // ✗ 叉
    private const string ToastGlyphInfo    = "\uE946"; // ℹ Info
    private const string ToastGlyphWarn    = "\uE7BA"; // ⚠ 警告
    private static readonly Brush ToastColorSuccess = new SolidColorBrush(Color.FromArgb(0xFF, 0x3F, 0xB6, 0x68));
    private static readonly Brush ToastColorError   = new SolidColorBrush(Color.FromArgb(0xFF, 0xD1, 0x34, 0x38));
    private static readonly Brush ToastColorInfo    = new SolidColorBrush(Color.FromArgb(0xFF, 0x00, 0x78, 0xD4));
    private static readonly Brush ToastColorWarn    = new SolidColorBrush(Color.FromArgb(0xFF, 0xFF, 0x8C, 0x00));

    public ReceivePage()
    {
        ViewModel = App.Services.GetRequiredService<ReceiveViewModel>();
        this.InitializeComponent();
        this.DataContext = ViewModel;
        this.Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        // 拿到 UI 线程 DispatcherQueue，便于跨线程同步 ObservableCollection
        ViewModel.SetDispatcher(DispatcherQueue.GetForCurrentThread());

        // 注册居中 Toast 消息（每个 ReceivePage 实例只注册一次，避免 OnLoaded 重复注册）
        if (!_toastRegistered)
        {
            _toastRegistered = true;
            WeakReferenceMessenger.Default.Register<ShowToastMessage>(this, (_, m) => ShowToast(m));
        }

        // 用 ShellWindow 的持久 XamlRoot（而非 Page 的 XamlRoot），
        // 避免 NavigationView 切 Tab 后 Page 被卸载导致 XamlRoot 失效、ContentDialog 弹不出
        var shellRoot = App.MainWindow.Content?.XamlRoot;
        if (shellRoot is null)
        {
            App.LogDiag("[ReceivePage] OnLoaded 时 ShellWindow XamlRoot 仍为 null");
        }
        else
        {
            App.LogDiag("[ReceivePage] OnLoaded 注入 RequestUserDecision，ShellWindow XamlRoot 已就绪");
        }

        // 设置弹窗回调：收到 prepare-upload 时弹 ReceiveRequestDialog
        ViewModel.RequestUserDecision = async session =>
        {
            // 窗口隐藏在托盘时弹系统通知提醒用户（前台可见时 ShowTransferToast 内部静默跳过）
            App.ShowTransferToast("收到文件传输请求",
                $"{session.Sender.Alias} 想发送 {session.Files.Count} 个文件，请尽快打开 PcDemo 处理");

            var root = shellRoot ?? this.XamlRoot;
            if (root is null)
            {
                App.LogDiag("[ReceivePage] RequestUserDecision: XamlRoot 仍为 null，返回 null → Decline");
                return null;
            }
            var dialog = new ReceiveRequestDialog(session) { XamlRoot = root };
            _requestDialog = dialog;
            try
            {
                return await dialog.ShowDialogAsync();
            }
            finally
            {
                if (_requestDialog == dialog) _requestDialog = null;
            }
        };

        // 等待决策期间会话超时/被取消 → 自动关闭请求对话框（避免用户对已死会话点"接收"）
        ViewModel.DecisionExpired += () => _requestDialog?.Hide();

        // 用户接受后 → 弹接收进度对话框（取消走二次确认 → ViewModel.CancelTransfer → CancelLocal）
        ViewModel.TransferAccepted += session => _ = ShowReceiveProgressAsync(session);

        // 会话结束 → 关闭进度对话框（ProgressFinished 在 UI 线程触发）
        ViewModel.ProgressFinished += () => _progressDialog?.Hide();
    }

    private void OnOpenFolderClick(object sender, RoutedEventArgs e) => ViewModel.OpenDestinationFolder();

    // 设备卡片右键菜单 → 加入白/黑名单
    private void OnAddToWhitelistClick(object sender, RoutedEventArgs e)
    {
        if (sender is MenuFlyoutItem mfi && mfi.DataContext is Device d)
            ViewModel.AddToWhitelistCommand.Execute(d);
    }

    private void OnAddToBlacklistClick(object sender, RoutedEventArgs e)
    {
        if (sender is MenuFlyoutItem mfi && mfi.DataContext is Device d)
            ViewModel.AddToBlacklistCommand.Execute(d);
    }

    private async Task ShowReceiveProgressAsync(ReceiveSession session)
    {
        var root = App.MainWindow.Content?.XamlRoot;
        if (root is null)
        {
            App.LogDiag("[ReceivePage] TransferAccepted: XamlRoot 为 null，进度对话框跳过（后台继续接收）");
            return;
        }
        var dialog = new ReceiveProgressDialog(session,
                () => ViewModel.CancelTransfer(session.SessionId),
                () => ViewModel.OpenDestinationFolder())
        {
            XamlRoot = root,
        };
        _progressDialog = dialog;
        await dialog.ShowAsync();
        if (_progressDialog == dialog) _progressDialog = null;
    }

    // ---------- 居中 Toast：淡入（240ms）→ 停留 DurationMs → 淡出（320ms） ----------

    private void ShowToast(ShowToastMessage msg)
    {
        // 设置图标 + 颜色
        (ToastIcon.Glyph, ToastIcon.Foreground) = msg.Kind switch
        {
            ToastKind.Error   => (ToastGlyphError,   ToastColorError),
            ToastKind.Warning => (ToastGlyphWarn,    ToastColorWarn),
            ToastKind.Info    => (ToastGlyphInfo,    ToastColorInfo),
            _                 => (ToastGlyphSuccess, ToastColorSuccess),
        };
        ToastText.Text = msg.Message;

        // 停掉正在跑的动画（防止连续复制时上一次没播完就被重入）
        _toastTimer?.Stop();
        ToastBorder.Visibility = Visibility.Visible;
        ToastBorder.Opacity = 0;

        const int TickMs = 30;
        const double FadeInStep = 1.0 / (240.0 / TickMs);       // 240ms 淡入
        double fadeOutStep = 1.0 / (320.0 / TickMs);            // 320ms 淡出
        int ticksHeld = 0;
        int holdTicks = Math.Max(1, msg.DurationMs / TickMs);
        double opacity = 0;
        ToastPhase phase = ToastPhase.FadeIn;

        _toastTimer = DispatcherQueue.CreateTimer();
        _toastTimer.Interval = TimeSpan.FromMilliseconds(TickMs);
        _toastTimer.Tick += (_, _) =>
        {
            switch (phase)
            {
                case ToastPhase.FadeIn:
                    opacity += FadeInStep;
                    if (opacity >= 1) { opacity = 1; phase = ToastPhase.Hold; }
                    ToastBorder.Opacity = opacity;
                    break;
                case ToastPhase.Hold:
                    ticksHeld++;
                    if (ticksHeld >= holdTicks) phase = ToastPhase.FadeOut;
                    break;
                case ToastPhase.FadeOut:
                    opacity -= fadeOutStep;
                    if (opacity <= 0)
                    {
                        ToastBorder.Opacity = 0;
                        ToastBorder.Visibility = Visibility.Collapsed;
                        _toastTimer.Stop();
                    }
                    else ToastBorder.Opacity = opacity;
                    break;
            }
        };
        _toastTimer.Start();
    }

    private enum ToastPhase { FadeIn, Hold, FadeOut }
}
