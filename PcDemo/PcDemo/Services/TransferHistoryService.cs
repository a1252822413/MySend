// TransferHistoryService：传输历史（内存 ObservableCollection + JSON 持久化到 LocalState）。
// 全部方法要求在 UI 线程调用（SessionFinished 处理器与页面加载均在 UI 线程）。
using System.Collections.ObjectModel;
using System.Text.Json;
using PcDemo.Models;

namespace PcDemo.Services;

public sealed class TransferHistoryService
{
    private const int MaxItems = 50;
    private readonly string _filePath;
    private static readonly JsonSerializerOptions _jsonOptions = new() { WriteIndented = true };

    /// <summary>历史列表（最新在前）。</summary>
    public ObservableCollection<TransferHistoryItem> Items { get; } = new();

    public TransferHistoryService()
    {
        var localState = Helpers.PathHelper.AppDataDir;
        _filePath = Path.Combine(localState, "transfer-history.json");
    }

    /// <summary>启动时从磁盘加载（损坏或缺失则忽略）。</summary>
    public void Load()
    {
        try
        {
            if (!File.Exists(_filePath)) return;
            var list = JsonSerializer.Deserialize<List<TransferHistoryItem>>(File.ReadAllText(_filePath));
            if (list is null) return;
            Items.Clear();
            foreach (var item in list.Take(MaxItems)) Items.Add(item);
            App.LogDiag($"[History] 已加载 {Items.Count} 条传输历史");
        }
        catch (Exception ex)
        {
            App.LogDiag($"[History] 加载失败：{ex.Message}");
        }
    }

    /// <summary>新增一条记录（插到最前，超出上限裁剪，异步落盘）。</summary>
    public void Add(TransferHistoryItem item)
    {
        Items.Insert(0, item);
        while (Items.Count > MaxItems) Items.RemoveAt(Items.Count - 1);
        Persist();
    }

    /// <summary>清空历史并删除持久化文件。</summary>
    public void Clear()
    {
        Items.Clear();
        Persist();
    }

    private void Persist()
    {
        try
        {
            // 原子写：先写临时文件再替换，避免进程崩溃留下损坏的 JSON
            var tmp = _filePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(Items.ToList(), _jsonOptions));
            if (File.Exists(_filePath)) File.Replace(tmp, _filePath, null);
            else File.Move(tmp, _filePath);
        }
        catch (Exception ex)
        {
            App.LogDiag($"[History] 持久化失败：{ex.Message}");
        }
    }
}
