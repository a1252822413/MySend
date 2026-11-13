// ClearHistoryDialog：清空传输历史的二次确认。
// 记录数由调用方传入（ViewModel.Items.Count = 全部记录，不是当前筛选结果），
// 避免「筛选后只显示 3 条，却提示将删除 3 条」的口径错误。
using Microsoft.UI.Xaml.Controls;

namespace PcDemo.Views;

public sealed partial class ClearHistoryDialog : ContentDialog
{
    public ClearHistoryDialog(int recordCount)
    {
        this.InitializeComponent();
        SubtitleText.Text = recordCount > 0
            ? $"共 {recordCount} 条记录将被删除，此操作无法撤销。已接收的文件不受影响。"
            : "将删除全部收发记录，此操作无法撤销。已接收的文件不受影响。";
    }
}
