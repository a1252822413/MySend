// HistoryViewModel：传输历史页（数据来自 TransferHistoryService 单例）。
using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using PcDemo.Models;
using PcDemo.Services;

namespace PcDemo.ViewModels;

public sealed partial class HistoryViewModel : ObservableObject
{
    private readonly TransferHistoryService _history;

    public HistoryViewModel(TransferHistoryService history)
    {
        _history = history;
    }

    public ObservableCollection<TransferHistoryItem> Items => _history.Items;

    [ObservableProperty] private bool _hasItems;
    [ObservableProperty] private bool _isEmpty = true;

    /// <summary>加载后刷新空态/清空按钮可见性（页面 Loaded 时调用）。</summary>
    public void Refresh()
    {
        HasItems = Items.Count > 0;
        IsEmpty = Items.Count == 0;
    }

    public void Clear()
    {
        _history.Clear();
        Refresh();
    }
}
