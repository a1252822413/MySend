// 文本输入对话框 codebehind：多行输入发送文字；次级按钮把剪贴板文本填入输入框（不关闭）。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace PcDemo.Views;

public sealed partial class TextInputDialog : ContentDialog
{
    public TextInputDialog()
    {
        // 派生类不匹配 TargetType="ContentDialog" 的隐式样式，必须显式应用新版模板
        this.Style = Application.Current.Resources["DefaultContentDialogStyle"] as Style;
        this.InitializeComponent();
    }

    /// <summary>弹出；用户点「发送」返回输入文本（去首尾空白），取消/关闭返回 null。</summary>
    public async Task<string?> ShowAndGetTextAsync()
    {
        var result = await ShowAsync();
        var text = InputTextBox.Text?.Trim() ?? string.Empty;
        return result == ContentDialogResult.Primary && text.Length > 0 ? text : null;
    }

    /// <summary>「粘贴剪贴板」：把剪贴板文本填入输入框并保持对话框打开，便于继续编辑。</summary>
    private async void OnSecondaryClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true; // 不关闭，粘贴后继续编辑
        try
        {
            var data = Clipboard.GetContent();
            if (!data.Contains(StandardDataFormats.Text)) return;
            var text = await data.GetTextAsync();
            if (!string.IsNullOrEmpty(text)) InputTextBox.Text = text;
        }
        catch
        {
            // 剪贴板读取失败忽略
        }
    }
}
