// ShellViewModel：管理当前导航页索引（用于 ShellWindow 的 NavigationView）。
using CommunityToolkit.Mvvm.ComponentModel;

namespace PcDemo.ViewModels;

public partial class ShellViewModel : ViewModelBase
{
    [ObservableProperty]
    private int _selectedIndex;

    // 0 = 接收，1 = 设置
    public const int IndexReceive = 0;
    public const int IndexSettings = 1;
}
