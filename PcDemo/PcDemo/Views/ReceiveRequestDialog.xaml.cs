// 接收确认对话框 codebehind：实例化后 ShowDialogAsync 返回 PrepareUploadDecision?。
// 外部可调用 Hide()（如决策超时自动关闭），ShowAsync 将返回 None → 视为拒绝。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.ViewModels;

namespace PcDemo.Views;

public sealed partial class ReceiveRequestDialog : ContentDialog
{
    private ReceiveRequestDialog(ReceiveRequestViewModel vm)
    {
        // 派生类不匹配 TargetType="ContentDialog" 的隐式样式，必须显式应用新版模板
        this.Style = Application.Current.Resources["DefaultContentDialogStyle"] as Style;
        this.InitializeComponent();
        this.DataContext = vm;
    }

    /// <summary>由会话创建对话框（VM 从 session 构建）。</summary>
    public ReceiveRequestDialog(ReceiveSession session)
        : this(ReceiveRequestViewModel.FromSession(session))
    {
    }

    /// <summary>弹出对话框；返回用户决策（接受时附 fileId 列表，拒绝/被外部关闭时 Accepted=false）。</summary>
    public async Task<PrepareUploadDecision?> ShowDialogAsync()
    {
        var result = await ShowAsync();
        App.LogDiag($"[Dialog] ShowAsync 返回 {result}，Accepted={result == ContentDialogResult.Primary}");
        return result switch
        {
            ContentDialogResult.Primary => ((ReceiveRequestViewModel)DataContext).ToDecision(),
            _ => new PrepareUploadDecision { Accepted = false },
        };
    }

    private void OnPrimaryClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // 不在此处提交，由 ShowDialogAsync 返回值统一处理
    }

    private void OnSecondaryClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // 同上
    }
}
