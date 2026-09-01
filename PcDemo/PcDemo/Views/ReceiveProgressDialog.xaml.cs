// 接收进度对话框：绑定 ReceiveSession.Progress（环形进度/阶段/速度/剩余时间），取消需二次确认。
// 由 ReceivePage 在 ViewModel.TransferAccepted 事件中弹出；SessionFinished → ProgressFinished → dialog.Hide。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PcDemo.Converters;
using PcDemo.Models;

namespace PcDemo.Views;

public sealed partial class ReceiveProgressDialog : ContentDialog
{
    /// <summary>聚合进度（ReceiveSessionManager 在 UI 线程更新，x:Bind OneWay 自动响应）。</summary>
    public ReceiveProgress P { get; }

    private readonly ReceiveSession _session;
    private readonly Action _onCancel;

    internal ReceiveProgressDialog(ReceiveSession session, Action onCancel)
    {
        _session = session;
        P = session.Progress;
        _onCancel = onCancel;
        // 派生类不匹配 TargetType="ContentDialog" 的隐式样式，必须显式应用新版模板
        // （否则 fallback 外观：无圆角/无内容区与按钮区的色带分层）
        this.Style = Application.Current.Resources["DefaultContentDialogStyle"] as Style;
        this.InitializeComponent();
        // RingValue 是 P 的计算属性（不触发通知），订阅后手动刷新
        P.PropertyChanged += (_, _) => this.Bindings.Update();
    }

    // ---------- x:Bind 绑定源 ----------
    public string SenderText => $"来自 {_session.Sender.Alias}（{_session.SenderIp}）";

    /// <summary>环形进度 0~100（转圈模式下不显示）。</summary>
    public double RingValue => P.Progress * 100.0;

    public string FilesText => $"{P.CompletedFiles} / {P.TotalFiles} 个文件";

    public string StatText => ComputeStatText();

    private string ComputeStatText()
    {
        var speed = ByteFormatter.FormatSpeed(P.SpeedBytesPerSecond);
        var eta = ByteFormatter.FormatEta(P.EtaSeconds);
        return $"{ByteFormatter.Format(P.ReceivedBytes)} / {ByteFormatter.Format(P.TotalBytes)} · {RingValue:0}%{speed}{eta}";
    }

    // ---------- 交互：二次确认在底部命令区切换（内容区始终显示进度） ----------
    private bool _confirming;

    private void OnCancelClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (!_confirming)
        {
            // 第一次点击：不关闭，把按钮区切换为 [确认取消(accent)] [继续接收]
            args.Cancel = true;
            _confirming = true;
            PrimaryButtonText = "确认取消";
            SecondaryButtonText = "继续接收";
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
        // 继续接收：不关闭，恢复按钮区为 [取消接收]
        if (_confirming)
        {
            args.Cancel = true;
            _confirming = false;
            PrimaryButtonText = "取消接收";
            SecondaryButtonText = string.Empty;
            PrimaryButtonStyle = null; // 恢复默认按钮样式
        }
    }

    /// <summary>弹出接收进度对话框；会话结束由外部 Hide（ShowAsync 返回）。</summary>
    public static async Task ShowAsync(Microsoft.UI.Xaml.XamlRoot root, ReceiveSession session, Action onCancel)
    {
        var dialog = new ReceiveProgressDialog(session, onCancel) { XamlRoot = root };
        try
        {
            await dialog.ShowAsync();
        }
        catch (Exception ex)
        {
            App.LogDiag($"[ReceiveDialog] ShowAsync 异常：{ex.Message}");
        }
    }
}
