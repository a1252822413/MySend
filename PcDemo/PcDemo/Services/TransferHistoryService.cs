// TransferHistoryService：传输历史（内存 ObservableCollection + JSON 持久化到 LocalState）。
// Add/Clear 要求在 UI 线程调用（SessionFinished 处理器与页面加载均在 UI 线程）；
// 落盘带 1.5s 合并窗口（debounce），多文件传输结束只写一次盘，Timer 线程通过锁安全快照。
using System.Collections.ObjectModel;
using System.Text.Json;
using System.Threading;
using PcDemo.Models;

namespace PcDemo.Services;

public sealed class TransferHistoryService
{
    private const int MaxItems = 50;
    private const int PersistDelayMs = 1500;
    private readonly string _filePath;
    private static readonly JsonSerializerOptions _jsonOptions = new() { WriteIndented = true };
    private readonly object _itemsGate = new();
    private readonly object _fileGate = new(); // .tmp 写盘互斥（Timer 线程 / UI Clear 并发防交叉写坏文件）
    // 复用单实例定时器：Add 时 Change 重置 1.5s 到期，不再反复 new/Dispose Timer
    private readonly Timer _persistTimer;

    /// <summary>历史列表（最新在前）。</summary>
    public ObservableCollection<TransferHistoryItem> Items { get; } = new();

    public TransferHistoryService()
    {
        var localState = Helpers.PathHelper.AppDataDir;
        _filePath = Path.Combine(localState, "transfer-history.json");
        _persistTimer = new Timer(_ => Persist(), null, Timeout.Infinite, Timeout.Infinite);
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

    /// <summary>新增一条记录（插到最前，超出上限裁剪，1.5s 内合并落盘一次）。</summary>
    public void Add(TransferHistoryItem item)
    {
        lock (_itemsGate)
        {
            Items.Insert(0, item);
            while (Items.Count > MaxItems) Items.RemoveAt(Items.Count - 1);
        }
        SchedulePersist();
    }

    /// <summary>清空历史并删除持久化文件（用户操作，立即落盘）。</summary>
    public void Clear()
    {
        lock (_itemsGate)
        {
            Items.Clear();
        }
        CancelPendingPersist();
        Persist();
    }

    /// <summary>1.5s 合并窗口：窗口内多次 Add 只在最后一次触发后落盘一次。</summary>
    private void SchedulePersist()
    {
        _persistTimer.Change(PersistDelayMs, Timeout.Infinite);
    }

    private void CancelPendingPersist()
    {
        _persistTimer.Change(Timeout.Infinite, Timeout.Infinite);
    }

    private void Persist()
    {
        try
        {
            List<TransferHistoryItem> snapshot;
            lock (_itemsGate)
            {
                snapshot = Items.ToList();
            }
            // 原子写：先写临时文件再替换，避免进程崩溃留下损坏的 JSON；
            // _fileGate 防 Timer 线程与 UI 线程 Clear() 并发写同一个 .tmp
            lock (_fileGate)
            {
                var tmp = _filePath + ".tmp";
                File.WriteAllText(tmp, JsonSerializer.Serialize(snapshot, _jsonOptions));
                if (File.Exists(_filePath)) File.Replace(tmp, _filePath, null);
                else File.Move(tmp, _filePath);
            }
        }
        catch (Exception ex)
        {
            App.LogDiag($"[History] 持久化失败：{ex.Message}");
        }
    }
}
