// SendPage code-behind：FileOpenPicker 选取文件、设 ViewModel 调度器、取消目标选择、移除单文件、拖拽添加文件/文件夹。
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PcDemo.Helpers;
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
    private SendProgressDialog? _queueDialog;

    public SendPage()
    {
        ViewModel = App.Services.GetRequiredService<SendViewModel>();
        this.InitializeComponent();
        ViewModel.SetDispatcher(DispatcherQueue.GetForCurrentThread());

        // Ctrl+V 粘贴文件：PreviewKeyDown 比 KeyboardAccelerator 更可靠，
        // 在 Page 的子控件获得焦点时也能触发（KeyboardAccelerator 在 WinUI3 Page 上有已知问题）。
        this.PreviewKeyDown += OnPastePreviewKeyDown;

        // “导入中…”指示：VM 后台导入时切换标题旁状态可见性
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(SendViewModel.IsImporting))
            {
                var on = ViewModel.IsImporting;
                // 整个容器 Collapsed，空闲时 FlowPanel 不会把它当作占位元素（避免按钮左侧多出间距）
                ImportingIndicator.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
            }
        };

        // 发送会话创建 → 弹出发送进度对话框（取消走二次确认 → CancelSend）。
        // 覆盖式处理器（非事件累加），避免多次进入页面后重复弹框
        ViewModel.TransferStarted = session => _ = ShowSendProgressAsync(session);

        // 群发：整批会话创建 → 弹出“每台一行”的列表进度弹窗（各会话独立刷新）
        ViewModel.QueueBatchStarted = sessions => _ = ShowBatchProgressAsync(sessions);

        // 会话结束 → 关闭进度对话框（ProgressFinished 在 UI 线程触发）
        ViewModel.ProgressFinished = () => _progressDialog?.Hide();
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

    /// <summary>群发弹窗：整批会话 → 列表式进度弹窗（每台一行，各自独立刷新）。</summary>
    private async Task ShowBatchProgressAsync(IReadOnlyList<PcDemo.Models.SendSession> sessions)
    {
        var root = App.MainWindow.Content?.XamlRoot;
        if (root is null)
        {
            App.LogDiag("[SendPage] QueueBatchStarted: XamlRoot 为 null，进度弹窗跳过（后台继续发送）");
            return;
        }
        if (sessions is null || sessions.Count == 0) return;

        var dialog = new SendProgressDialog(
            sessions,
            () => ViewModel.CancelSendCommand.Execute(null))
        {
            XamlRoot = root,
        };
        _queueDialog = dialog;
        _progressDialog = dialog;
        try
        {
            await dialog.ShowAsync();
        }
        catch (Exception ex)
        {
            App.LogDiag($"[SendPage] 群发弹窗 ShowAsync 异常：{ex.Message}");
        }
        if (_queueDialog == dialog) _queueDialog = null;
        if (_progressDialog == dialog) _progressDialog = null;
    }

    /// <summary>目标设备卡单击 → 切换多选勾选状态（可多选群发）。</summary>
    private void OnDeviceTileTapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.DataContext is Device d)
            ViewModel.ToggleTarget(d);
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

    private async void OnPickFolderClick(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FolderPicker
        {
            SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.DocumentsLibrary,
        };
        // FolderPicker 至少需要一个扩展名过滤（"*" 表示任意）
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        await ViewModel.AddFolderAsync(folder);
    }

    private async void OnSendTextClick(object sender, RoutedEventArgs e)
    {
        var root = App.MainWindow.Content?.XamlRoot;
        if (root is null)
        {
            App.LogDiag("[SendPage] OnSendTextClick: XamlRoot 为 null，忽略");
            return;
        }
        var dialog = new TextInputDialog { XamlRoot = root };
        var text = await dialog.ShowAndGetTextAsync();
        if (string.IsNullOrEmpty(text)) return;
        await ViewModel.SendTextAsync(text);
    }

    private void OnDeselectTargetClick(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectedTargets.Clear();
    }

    // 设备卡片右键菜单 → 加入白/黑名单
    private void OnAddToWhitelistClick(object sender, RoutedEventArgs e)
    {
        if (sender is MenuFlyoutItem mfi && mfi.DataContext is Device d)
            ViewModel.AddToWhitelistCommand.Execute(d);
    }

    private void OnAddToBlacklistClick(object sender, RoutedEventArgs e)
    {
        if (sender is MenuFlyoutItem mfi && mfi.DataContext is Device d)
            ViewModel.AddToBlacklistCommand.Execute(d);
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

    private bool _pinSyncing;

    /// <summary>PIN 只允许数字、最多 6 位；非法/超长部分自动剔除。</summary>
    private const int PinMaxLength = 6;

    private static string SanitizePin(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return string.Empty;
        var sb = new System.Text.StringBuilder(raw.Length);
        foreach (var ch in raw)
        {
            if (ch is >= '0' and <= '9' && sb.Length < PinMaxLength) sb.Append(ch);
        }
        return sb.ToString();
    }

    private void OnPinPasswordChanged(object sender, RoutedEventArgs e)
    {
        if (_pinSyncing) return;
        _pinSyncing = true;
        var clean = SanitizePin(PinPasswordBox.Password);
        if (clean != PinPasswordBox.Password) PinPasswordBox.Password = clean;
        ViewModel.Pin = clean;
        _pinSyncing = false;
    }

    private void OnPinTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_pinSyncing) return;
        _pinSyncing = true;
        var clean = SanitizePin(PinVisibleBox.Text);
        if (clean != PinVisibleBox.Text)
        {
            // 改动文本后把光标放到末尾，避免非法输入被剔时跳动
            PinVisibleBox.Text = clean;
            PinVisibleBox.SelectionStart = clean.Length;
        }
        ViewModel.Pin = clean;
        _pinSyncing = false;
    }

    private void OnPinToggleClick(object sender, RoutedEventArgs e)
    {
        _pinSyncing = true;
        if (PinPasswordBox.Visibility == Visibility.Visible)
        {
            PinVisibleBox.Text = PinPasswordBox.Password;
            PinPasswordBox.Visibility = Visibility.Collapsed;
            PinVisibleBox.Visibility = Visibility.Visible;
        }
        else
        {
            PinPasswordBox.Password = PinVisibleBox.Text;
            PinPasswordBox.Visibility = Visibility.Visible;
            PinVisibleBox.Visibility = Visibility.Collapsed;
        }
        _pinSyncing = false;
    }

    /// <summary>Ctrl+V：从剪贴板读取文件并加入待发列表。
    /// 当焦点在 TextBox/PasswordBox 时不拦截（让控件正常粘贴文本）。</summary>
    private async void OnPastePreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // 只处理 Ctrl+V
        if (e.Key != Windows.System.VirtualKey.V) return;
        var ctrl = Microsoft.UI.Input.InputKeyboardSource
            .GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control);
        if ((ctrl & Windows.UI.Core.CoreVirtualKeyStates.Down) != Windows.UI.Core.CoreVirtualKeyStates.Down)
            return;

        // 焦点在文本输入框时不拦截，让控件正常粘贴
        var focused = Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement();
        if (focused is TextBox or PasswordBox) return;

        e.Handled = true;
        try
        {
            var content = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
            if (content.Contains("StorageItems"))
            {
                var items = await content.GetStorageItemsAsync();
                if (items.Count > 0)
                {
                    await ViewModel.AddStorageItemsAsync(items);
                    App.LogDiag($"[SendPage] Ctrl+V: 粘贴 {items.Count} 个文件");
                }
                return;
            }
            // 兜底：从纯文本路径解析
            if (content.Contains(StandardDataFormats.Text))
            {
                var text = await content.GetTextAsync();
                var paths = text.Split('\n', '\r')
                    .Select(s => s.Trim().Trim('"'))
                    .Where(s => !string.IsNullOrEmpty(s) && System.IO.File.Exists(s))
                    .ToList();
                if (paths.Count > 0)
                {
                    ViewModel.AddFiles(paths);
                    App.LogDiag($"[SendPage] Ctrl+V: 从文本解析 {paths.Count} 个文件路径");
                }
            }
        }
        catch (Exception ex)
        {
            App.LogDiag($"[SendPage] Ctrl+V 粘贴失败：{ex.Message}");
        }
    }
}
