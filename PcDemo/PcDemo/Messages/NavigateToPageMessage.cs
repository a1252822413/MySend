// 顶部提醒的「查看历史 / 查看详情」动作：请 ShellWindow 切到指定页面。
// Tag 与 ShellWindow.xaml 中 NavigationViewItem.Tag 一致：
// Receive / Send / DeviceList / History / Settings。
namespace PcDemo.Messages;

public sealed class NavigateToPageMessage
{
    public string Tag { get; init; } = "History";
}
