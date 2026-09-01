// HistoryPage codebehind：传输历史列表页。
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PcDemo.ViewModels;

namespace PcDemo.Views;

public sealed partial class HistoryPage : Page
{
    public HistoryViewModel ViewModel { get; }

    public HistoryPage()
    {
        ViewModel = App.Services.GetRequiredService<HistoryViewModel>();
        this.InitializeComponent();
        this.Loaded += (_, _) => ViewModel.Refresh();
    }

    private void OnClearClick(object sender, RoutedEventArgs e) => ViewModel.Clear();
}
