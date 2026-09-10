// HistoryViewModel：传输历史页（数据来自 TransferHistoryService 单例）。
// 支持按方向/关键词筛选：原始数据在 _history.Items，FilteredItems 是筛选后视图。
using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using PcDemo.Models;
using PcDemo.Services;

namespace PcDemo.ViewModels;

public sealed partial class HistoryViewModel : ObservableObject
{
    private readonly TransferHistoryService _history;

    /// <summary>筛选后展示的列表（UI 绑定）。</summary>
    public ObservableCollection<TransferHistoryItem> FilteredItems { get; } = new();

    /// <summary>全部历史（只读访问）。</summary>
    public ObservableCollection<TransferHistoryItem> Items => _history.Items;

    public HistoryViewModel(TransferHistoryService history)
    {
        _history = history;
    }

    // ---------- 筛选条件 ----------

    /// <summary>方向筛选：0=全部, 1=发送, 2=接收</summary>
    [ObservableProperty] private int _filterDirection;

    /// <summary>搜索关键词（按设备名/文件名模糊匹配）</summary>
    [ObservableProperty] private string _searchText = string.Empty;

    partial void OnFilterDirectionChanged(int value) => RebuildFiltered();
    partial void OnSearchTextChanged(string value) => RebuildFiltered();

    [ObservableProperty] private bool _hasItems;
    [ObservableProperty] private bool _isEmpty = true;

    /// <summary>加载后刷新筛选列表 + 空态（页面 Loaded / 历史变更时调用）。</summary>
    public void Refresh()
    {
        RebuildFiltered();
        HasItems = _history.Items.Count > 0;
    }

    /// <summary>根据当前筛选条件重建 FilteredItems。</summary>
    private void RebuildFiltered()
    {
        FilteredItems.Clear();
        var keyword = (SearchText ?? string.Empty).Trim();
        foreach (var item in _history.Items)
        {
            if (FilterDirection == 1 && item.Direction != TransferDirection.Send) continue;
            if (FilterDirection == 2 && item.Direction != TransferDirection.Receive) continue;
            if (keyword.Length > 0)
            {
                var peerMatch = item.PeerName.Contains(keyword, StringComparison.OrdinalIgnoreCase);
                var fileMatch = item.FirstFileName?.Contains(keyword, StringComparison.OrdinalIgnoreCase) == true;
                if (!peerMatch && !fileMatch) continue;
            }
            FilteredItems.Add(item);
        }
        IsEmpty = FilteredItems.Count == 0;
    }

    public void Clear()
    {
        _history.Clear();
        Refresh();
    }

    public void Delete(TransferHistoryItem item)
    {
        if (item is null) return;
        _history.Remove(item);
        Refresh();
    }
}
