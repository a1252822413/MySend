// 发送进度对话框：绑定 SendSession（环形进度/状态/速度/剩余时间），取消需二次确认。
// 由 SendPage 在 TransferStarted 事件中弹出；SendViewModel.ShowResult 触发关闭（ProgressFinished → dialog.Hide）。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PcDemo.Converters;
using PcDemo.Models;

namespace PcDemo.Views;

public sealed partial class SendProgressDialog : ContentDialog
{
    private readonly SendSession? _single;
    private readonly IReadOnlyList<SendSession> _batch;
    private readonly Action _onCancel;

    /// <summary>单发：单个会话 + 环形进度。</summary>
    internal SendProgressDialog(SendSession session, Action onCancel)
    {
        _single = session;
        _batch = Array.Empty<SendSession>();
        _onCancel = onCancel;
        // 派生类不匹配 TargetType="ContentDialog" 的隐式样式，必须显式应用新版模板
        // （否则 fallback 外观：无圆角/无内容区与按钮区的色带分层）
        this.Style = Application.Current.Resources["DefaultContentDialogStyle"] as Style;
        this.InitializeComponent();
        // SendSessionManager 的所有状态更新都经 DispatcherQueue（UI 线程），
        // 这里只刷新会变化的节点（StatText/Ring/状态文字），不做整页 Bindings.Update()
        _single.PropertyChanged += OnSessionChanged;
        SinglePanel.Visibility = Visibility.Visible;
        BatchPanel.Visibility = Visibility.Collapsed;
        RefreshUi();
    }

    /// <summary>群发：传入整批会话，每台一行实时展示。</summary>
    internal SendProgressDialog(IReadOnlyList<SendSession> sessions, Action onCancel)
    {
        _batch = sessions;
        _single = null;
        _onCancel = onCancel;
        this.Style = Application.Current.Resources["DefaultContentDialogStyle"] as Style;
        this.InitializeComponent();
        SinglePanel.Visibility = Visibility.Collapsed;
        BatchPanel.Visibility = Visibility.Visible;
        // 弹窗显示时 XamlRoot 才可用：按窗口高度限制列表区最大高度，避免设备多时弹窗超出界面
        Opened += (_, _) => ApplyBatchListMaxHeight();
        BuildBatchRows();
        RefreshBatchSummary();
        foreach (var s in _batch) s.PropertyChanged += OnBatchSessionChanged;
    }

    /// <summary>
    /// 按当前窗口可视高度限制群发列表的最大高度：
    /// 给标题栏/汇总行/底部按钮区预留空间，余下的尽量给列表，但绝不超过可视高度的 ~46%。
    /// </summary>
    private void ApplyBatchListMaxHeight()
    {
        var root = this.XamlRoot;
        if (root is null) return;
        var viewportH = root.Size.Height;
        if (viewportH <= 0) return;
        // 预留弹窗标题区 + 汇总行 + 底部命令按钮区的固定空间；46% 视口是上限安全值
        var max = Math.Clamp(viewportH * 0.46, 120.0, 560.0);
        BatchListScroll.MaxHeight = max;
    }

    private void OnSessionChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
        => RefreshUi();

    private void OnBatchSessionChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        // 任一会话状态/进度变化 → 刷新对应行 + 顶部汇总
        RefreshRow((SendSession)sender!);
        RefreshBatchSummary();
    }

    /// <summary>增量刷新：只更新有值的节点（速度/字节/百分比/环形进度/状态文字）。</summary>
    private void RefreshUi()
    {
        if (_single is null) return;
        TargetTextBlock.Text = TargetText;
        StateTextBlock.Text = StateText;
        FilesTextBlock.Text = FilesText;
        StatTextBlock.Text = ComputeStatText(_single);
        ProgressRingControl.IsIndeterminate = IsWaiting;
        ProgressRingControl.Value = RingValue;
    }

    // ---------- x:Bind 绑定源 ----------
    public string TargetText => $"发送到 {_single!.Target.Alias}";

    /// <summary>等待对方确认时 ProgressRing 转圈模式。</summary>
    public bool IsWaiting => _single!.State == SendSessionState.WaitingForReceiver;

    /// <summary>环形进度 0~100（等待确认时为 0）。</summary>
    public double RingValue => _single!.Progress * 100.0;

    public string StateText => _single!.State switch
    {
        SendSessionState.WaitingForReceiver => "等待对方确认…",
        SendSessionState.InProgress => "传输中",
        SendSessionState.Completed => "已完成",
        SendSessionState.Cancelled => "已取消",
        SendSessionState.CancelledByPeer => "对方中断",
        SendSessionState.Rejected => "对方拒绝",
        SendSessionState.Failed => "发送失败",
        _ => "准备中",
    };

    public string FilesText => $"{_single!.CompletedFiles} / {_single.Files.Count} 个文件";

    // ---------- 群发列表行：每台一个行控件（复用增量刷新，不做整页绑定） ----------
    private sealed class RowControls
    {
        public required SendSession Session;
        public required TextBlock NameText;
        public required TextBlock StateText;
        public required ProgressBar Bar;
        public required TextBlock StatText;
    }

    private readonly List<RowControls> _rows = new();

    private void BuildBatchRows()
    {
        foreach (var s in _batch)
        {
            var row = new RowControls
            {
                Session = s,
                NameText = new TextBlock { FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis },
                StateText = new TextBlock { FontSize = 12, Opacity = 0.75, HorizontalAlignment = HorizontalAlignment.Right, TextTrimming = TextTrimming.CharacterEllipsis },
                Bar = new ProgressBar { Height = 3, CornerRadius = new CornerRadius(1.5) },
                StatText = new TextBlock { FontSize = 11, Opacity = 0.6 },
            };

            var head = new Grid
            {
                ColumnDefinitions =
                {
                    new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                    new ColumnDefinition { Width = GridLength.Auto },
                },
            };
            head.Children.Add(row.NameText);
            Grid.SetColumn(row.StateText, 1);
            head.Children.Add(row.StateText);

            var stack = new StackPanel { Spacing = 2 };
            stack.Children.Add(head);
            stack.Children.Add(row.Bar);
            stack.Children.Add(row.StatText);

            var border = new Border
            {
                Child = stack,
                Padding = new Thickness(12, 8, 12, 8),
                CornerRadius = new CornerRadius(8),
                Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardBackgroundFillColorSecondaryBrush"],
            };
            BatchListPanel.Children.Add(border);
            _rows.Add(row);
            RefreshRow(s);
        }
    }

    private void RefreshRow(SendSession s)
    {
        var row = _rows.FirstOrDefault(r => ReferenceEquals(r.Session, s));
        if (row is null) return;
        row.NameText.Text = s.Target.Alias;
        row.StateText.Text = s.State switch
        {
            SendSessionState.WaitingForReceiver => "等待确认…",
            SendSessionState.InProgress => "传输中",
            SendSessionState.Completed => "✓ 已完成",
            SendSessionState.Cancelled => "已取消",
            SendSessionState.CancelledByPeer => "对方中断",
            SendSessionState.Rejected => "✗ 对方拒绝",
            SendSessionState.Failed => "✗ 发送失败",
            _ => "准备中",
        };
        var waiting = s.State == SendSessionState.WaitingForReceiver;
        row.Bar.IsIndeterminate = waiting;
        row.Bar.Value = waiting ? 0 : Math.Clamp(s.Progress * 100.0, 0, 100);
        var extra = s.State switch
        {
            SendSessionState.WaitingForReceiver => $"请求发送 {s.Files.Count} 个文件",
            SendSessionState.Rejected => s.ErrorMessage ?? "对方拒绝",
            SendSessionState.Failed => s.ErrorMessage ?? "发送失败",
            _ => ByteFormatter.Format(s.TotalBytesSent),
        };
        row.StatText.Text = $"{s.CompletedFiles}/{s.Files.Count} 个文件 · {extra}";
    }

    private void RefreshBatchSummary()
    {
        var total = _batch.Count;
        var ok = _batch.Count(x => x.State == SendSessionState.Completed);
        var fail = _batch.Count(x => x.State is SendSessionState.Rejected
            or SendSessionState.Cancelled or SendSessionState.CancelledByPeer or SendSessionState.Failed);
        var waiting = _batch.Count(x => x.State is SendSessionState.WaitingForReceiver or SendSessionState.InProgress);
        BatchSummaryTextBlock.Text = waiting > 0
            ? $"共 {total} 台 · 已完成 {ok} · 失败 {fail} · 进行中 {waiting}"
            : $"共 {total} 台 · 已完成 {ok} · 失败 {fail}";
    }

    private static string ComputeStatText(SendSession s)
    {
        var speed = ByteFormatter.FormatSpeed(s.SpeedBytesPerSecond);
        var eta = ByteFormatter.FormatEta(s.EtaSeconds);
        return $"{ByteFormatter.Format(s.TotalBytesSent)} / {ByteFormatter.Format(s.TotalBytes)} · {s.Progress * 100.0:0}%{speed}{eta}";
    }

    // ---------- 交互：二次确认在底部命令区切换（内容区始终显示进度） ----------
    private bool _confirming;

    private void OnCancelClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (!_confirming)
        {
            // 第一次点击：不关闭，把按钮区切换为 [确认取消(accent)] [继续传输]
            args.Cancel = true;
            _confirming = true;
            PrimaryButtonText = "确认取消";
            SecondaryButtonText = "继续传输";
            // "确认取消"使用官方强调色（accent 蓝底白字）
            PrimaryButtonStyle = (Style)Application.Current.Resources["AccentButtonStyle"];
        }
        else
        {
            // 第二次点击：确认取消（让对话框关闭）
            _onCancel();
        }
    }

    private void OnContinueClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // 继续传输：不关闭，恢复按钮区为 [取消传输]
        if (_confirming)
        {
            args.Cancel = true;
            _confirming = false;
            PrimaryButtonText = "取消传输";
            SecondaryButtonText = string.Empty;
            PrimaryButtonStyle = null; // 恢复默认按钮样式
        }
    }

    /// <summary>弹出发送进度对话框；会话结束由外部 Hide（ShowAsync 返回）。</summary>
    public static async Task ShowAsync(Microsoft.UI.Xaml.XamlRoot root, SendSession session, Action onCancel)
    {
        var dialog = new SendProgressDialog(session, onCancel) { XamlRoot = root };
        try
        {
            await dialog.ShowAsync();
        }
        catch (Exception ex)
        {
            App.LogDiag($"[SendDialog] ShowAsync 异常（不影响后台传输）：{ex.Message}");
        }
    }
}
