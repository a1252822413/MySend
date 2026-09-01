// 发送进度对话框：绑定 SendSession（环形进度/状态/速度/剩余时间），取消需二次确认。
// 由 SendPage 在 TransferStarted 事件中弹出；SendViewModel.ShowResult 触发关闭（ProgressFinished → dialog.Hide）。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PcDemo.Converters;
using PcDemo.Models;

namespace PcDemo.Views;

public sealed partial class SendProgressDialog : ContentDialog
{
    private readonly SendSession _s;
    private readonly Action _onCancel;

    internal SendProgressDialog(SendSession session, Action onCancel)
    {
        _s = session;
        _onCancel = onCancel;
        // 派生类不匹配 TargetType="ContentDialog" 的隐式样式，必须显式应用新版模板
        // （否则 fallback 外观：无圆角/无内容区与按钮区的色带分层）
        this.Style = Application.Current.Resources["DefaultContentDialogStyle"] as Style;
        this.InitializeComponent();
        // SendSessionManager 的所有状态更新都经 DispatcherQueue（UI 线程），这里直接刷新绑定即可
        _s.PropertyChanged += (_, _) => this.Bindings.Update();
    }

    // ---------- x:Bind 绑定源 ----------
    public string TargetText => $"发送到 {_s.Target.Alias}";

    /// <summary>等待对方确认时 ProgressRing 转圈模式。</summary>
    public bool IsWaiting => _s.State == SendSessionState.WaitingForReceiver;

    /// <summary>环形进度 0~100（等待确认时为 0）。</summary>
    public double RingValue => _s.Progress * 100.0;

    public string StateText => _s.State switch
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

    public string FilesText => $"{_s.CompletedFiles} / {_s.Files.Count} 个文件";

    public string StatText => ComputeStatText();

    private string ComputeStatText()
    {
        var speed = ByteFormatter.FormatSpeed(_s.SpeedBytesPerSecond);
        var eta = ByteFormatter.FormatEta(_s.EtaSeconds);
        return $"{ByteFormatter.Format(_s.TotalBytesSent)} / {ByteFormatter.Format(_s.TotalBytes)} · {RingValue:0}%{speed}{eta}";
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
