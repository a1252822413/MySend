// SendPage code-behind：FileOpenPicker 选取文件、设 ViewModel 调度器、取消目标选择、移除单文件、拖拽添加文件/文件夹。
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PcDemo.Models;
using PcDemo.ViewModels;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using WinRT.Interop;

namespace PcDemo.Views;

public sealed partial class SendPage : Page
{
    public SendViewModel ViewModel { get; }

    private ContentDialog? _progressDialog;

    public SendPage()
    {
        ViewModel = App.Services.GetRequiredService<SendViewModel>();
        this.InitializeComponent();
        ViewModel.SetDispatcher(DispatcherQueue.GetForCurrentThread());

        // 发送会话创建 → 弹出发送进度对话框（取消走二次确认 → CancelSend）
        ViewModel.TransferStarted += session => _ = ShowSendProgressAsync(session);

        // 会话结束 → 关闭进度对话框（ProgressFinished 在 UI 线程触发）
        ViewModel.ProgressFinished += () => _progressDialog?.Hide();
    }

    private async Task ShowSendProgressAsync(PcDemo.Models.SendSession session)
    {
        var root = App.MainWindow.Content?.XamlRoot;
        if (root is null)
        {
            App.LogDiag("[SendPage] TransferStarted: XamlRoot 为 null，进度对话框跳过（后台继续发送）");
            return;
        }
        var dialog = new SendProgressDialog(session, () => ViewModel.CancelSendCommand.Execute(null))
        {
            XamlRoot = root,
        };
        _progressDialog = dialog;
        await dialog.ShowAsync();
        if (_progressDialog == dialog) _progressDialog = null;
    }

    private async void OnPickFilesClick(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker
        {
            ViewMode = Windows.Storage.Pickers.PickerViewMode.List,
            SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.DocumentsLibrary,
        };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        var picked = await picker.PickMultipleFilesAsync();
        if (picked is null || picked.Count == 0) return;
        ViewModel.AddFiles(picked.Select(f => f.Path));
    }

    private void OnDeselectTargetClick(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectedTarget = null;
    }

    /// <summary>DataTemplate 里的移除按钮：sender.DataContext 取到 SendFileItem。</summary>
    private void OnRemoveFileClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button b && b.DataContext is SendFileItem f)
            ViewModel.RemoveFileCommand.Execute(f);
    }

    // ---------- 拖拽支持：文件 / 文件夹 ----------
    private void OnDragOver(object sender, DragEventArgs e)
    {
        // 统一标记 Copy：含 StorageItems 走标准路径；否则 Drop 里再按 AvailableFormats 兜底取
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "拖放到此处添加文件";
        e.DragUIOverride.IsCaptionVisible = true;
        e.DragUIOverride.IsContentVisible = true;
        DropHighlightBorder.Opacity = 0.18;
    }

    private void OnDragLeave(object sender, DragEventArgs e)
    {
        DropHighlightBorder.Opacity = 0;
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        DropHighlightBorder.Opacity = 0;
        var def = e.GetDeferral();
        try
        {
            // 优先按 StorageItems 取；不行则遍历 AvailableFormats 逐个 GetDataAsync 试
            IReadOnlyList<Windows.Storage.IStorageItem>? items = null;
            if (e.DataView.Contains("StorageItems"))
            {
                items = await e.DataView.GetDataAsync("StorageItems") as IReadOnlyList<Windows.Storage.IStorageItem>;
            }
            else
            {
                foreach (var fmt in e.DataView.AvailableFormats)
                {
                    var data = await e.DataView.GetDataAsync(fmt);
                    if (data is IReadOnlyList<Windows.Storage.IStorageItem> list)
                    {
                        items = list;
                        break;
                    }
                }
            }
            if (items is null || items.Count == 0)
            {
                App.LogDiag("[SendPage] Drop: items null/empty");
                return;
            }
            App.LogDiag($"[SendPage] Drop: {items.Count} items");
            await ViewModel.AddStorageItemsAsync(items);
        }
        catch (Exception ex)
        {
            App.LogDiag($"[SendPage] Drop failed: {ex}");
        }
        finally
        {
            def.Complete();
        }
    }
}
