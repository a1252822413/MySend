// ReceivePage codebehind：通过 App.Services 拿 ReceiveViewModel，注入 DispatcherQueue 与弹窗回调。
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.ViewModels;

namespace PcDemo.Views;

public sealed partial class ReceivePage : Page
{
    public ReceiveViewModel ViewModel { get; }

    private ContentDialog? _progressDialog;

    public ReceivePage()
    {
        ViewModel = App.Services.GetRequiredService<ReceiveViewModel>();
        this.InitializeComponent();
        this.DataContext = ViewModel;
        this.Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        // 拿到 UI 线程 DispatcherQueue，便于跨线程同步 ObservableCollection
        ViewModel.SetDispatcher(DispatcherQueue.GetForCurrentThread());

        // 用 ShellWindow 的持久 XamlRoot（而非 Page 的 XamlRoot），
        // 避免 NavigationView 切 Tab 后 Page 被卸载导致 XamlRoot 失效、ContentDialog 弹不出
        var shellRoot = App.MainWindow.Content?.XamlRoot;
        if (shellRoot is null)
        {
            App.LogDiag("[ReceivePage] OnLoaded 时 ShellWindow XamlRoot 仍为 null");
        }
        else
        {
            App.LogDiag("[ReceivePage] OnLoaded 注入 RequestUserDecision，ShellWindow XamlRoot 已就绪");
        }

        // 设置弹窗回调：收到 prepare-upload 时弹 ReceiveRequestDialog
        ViewModel.RequestUserDecision = async session =>
        {
            var root = shellRoot ?? this.XamlRoot;
            if (root is null)
            {
                App.LogDiag("[ReceivePage] RequestUserDecision: XamlRoot 仍为 null，返回 null → Decline");
                return null;
            }
            return await ReceiveRequestDialog.ShowDialogAsync(root, session);
        };

        // 用户接受后 → 弹接收进度对话框（取消走二次确认 → ViewModel.CancelTransfer → CancelLocal）
        ViewModel.TransferAccepted += session => _ = ShowReceiveProgressAsync(session);

        // 会话结束 → 关闭进度对话框（ProgressFinished 在 UI 线程触发）
        ViewModel.ProgressFinished += () => _progressDialog?.Hide();
    }

    private void OnOpenFolderClick(object sender, RoutedEventArgs e) => ViewModel.OpenDestinationFolder();

    private async Task ShowReceiveProgressAsync(ReceiveSession session)
    {
        var root = App.MainWindow.Content?.XamlRoot;
        if (root is null)
        {
            App.LogDiag("[ReceivePage] TransferAccepted: XamlRoot 为 null，进度对话框跳过（后台继续接收）");
            return;
        }
        var dialog = new ReceiveProgressDialog(session, () => ViewModel.CancelTransfer(session.SessionId))
        {
            XamlRoot = root,
        };
        _progressDialog = dialog;
        await dialog.ShowAsync();
        if (_progressDialog == dialog) _progressDialog = null;
    }
}
