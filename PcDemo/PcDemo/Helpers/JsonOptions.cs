// 共享的 JSON 序列化选项，所有协议序列化/反序列化都用此单例。
// camelCase 命名策略对齐 localsend 协议；空值不写入；包含自定义枚举 converter。
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Text.Json;
using System.Text.Json.Serialization;
using PcDemo.Models.Dto;

namespace PcDemo.Helpers;

public static class JsonOptions
{
    public static readonly JsonSerializerOptions Default = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
        WriteIndented = false,
        // DeviceType / ProtocolType 通过 [JsonConverter] 特性自动注册 converter，
        // 此处无需手动加，但显式注册也无害且更直观：
        Converters =
        {
            new DeviceTypeConverter(),
            new ProtocolTypeConverter(),
        },
    };
}

/// <summary>
/// 支持批量添加的 ObservableCollection：AddRange 期间抑制逐项通知，最后一次 Reset 通知，
/// 避免拖入大量文件时 UI 逐项 CollectionChanged 触发布局刷新。
/// </summary>
public class BatchObservableCollection<T> : ObservableCollection<T>
{
    private bool _suppress;

    /// <summary>批量添加：完成后只发一次 Reset 通知（沿用现有 ItemsSource 绑定，无需改动 XAML）。</summary>
    public void AddRange(IEnumerable<T> items)
    {
        _suppress = true;
        try
        {
            foreach (var item in items) Add(item);
        }
        finally
        {
            _suppress = false;
        }
        OnCollectionChanged(new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Reset));
        OnPropertyChanged(new PropertyChangedEventArgs(nameof(Count)));
        OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
    }

    protected override void OnCollectionChanged(NotifyCollectionChangedEventArgs e)
    {
        if (!_suppress) base.OnCollectionChanged(e);
    }
}
