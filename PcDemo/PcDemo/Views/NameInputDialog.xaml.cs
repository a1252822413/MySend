// 单行文本输入对话框（重命名等场景）。返回去首尾空白后的文本，取消/留空返回 null。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace PcDemo.Views;

public sealed partial class NameInputDialog : ContentDialog
{
    public NameInputDialog(string title, string initial)
    {
        // 派生类不匹配 TargetType="ContentDialog" 的隐式样式，必须显式应用新版模板
        this.Style = Application.Current.Resources["DefaultContentDialogStyle"] as Style;
        this.InitializeComponent();
        Title = title;
        InputBox.Text = initial ?? string.Empty;
        InputBox.SelectAll();
    }

    /// <summary>弹出；点「保存」且非空返回文本，取消/关闭返回 null。</summary>
    public async Task<string?> ShowAndGetAsync()
    {
        var result = await ShowAsync();
        var text = InputBox.Text?.Trim() ?? string.Empty;
        return result == ContentDialogResult.Primary && text.Length > 0 ? text : null;
    }
}
