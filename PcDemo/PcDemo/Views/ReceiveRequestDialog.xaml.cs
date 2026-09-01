// 接收确认对话框 codebehind：静态 ShowDialogAsync 返回 PrepareUploadDecision?。
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

    /// <summary>静态弹出对话框；返回用户决策（接受时附 fileId 列表，拒绝时 Accepted=false）。</summary>
    public static async Task<PrepareUploadDecision?> ShowDialogAsync(XamlRoot root, ReceiveSession session)
    {
        App.LogDiag($"[Dialog] ShowDialogAsync 开始，root={(root is null ? "null" : "ok")} 文件数={session.Files.Count}");
        var vm = ReceiveRequestViewModel.FromSession(session);
        var dialog = new ReceiveRequestDialog(vm)
        {
            XamlRoot = root,
        };
        var result = await dialog.ShowAsync();
        App.LogDiag($"[Dialog] ShowAsync 返回 {result}，Accepted={result == ContentDialogResult.Primary}");
        return result switch
        {
            ContentDialogResult.Primary => vm.ToDecision(),
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
