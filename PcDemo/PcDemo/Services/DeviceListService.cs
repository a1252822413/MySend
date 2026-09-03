// DeviceListService：白名单/黑名单的内存 + 持久化实现。
// 持久化到 device-lists.json（原子写：.tmp + Replace）；内存用 List + 锁，
// 对外暴露只读快照避免外部修改内部状态。Changed 事件供 UI 订阅刷新。
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using PcDemo.Helpers;
using PcDemo.Models;
using PcDemo.Models.Dto;

namespace PcDemo.Services;

public sealed class DeviceListService : IDeviceListService
{
    private readonly object _gate = new();
    private readonly string _filePath;
    private readonly object _fileGate = new();
    private List<DeviceListEntry> _whitelist = new();
    private List<DeviceListEntry> _blacklist = new();

    public DeviceListService()
    {
        _filePath = PathHelper.DeviceListsFilePath;
    }

    public IReadOnlyList<DeviceListEntry> Whitelist
    {
        get { lock (_gate) return _whitelist.ToList(); }
    }

    public IReadOnlyList<DeviceListEntry> Blacklist
    {
        get { lock (_gate) return _blacklist.ToList(); }
    }

    public event EventHandler? Changed;

    public void Load()
    {
        try
        {
            if (!File.Exists(_filePath)) return;
            var doc = JsonSerializer.Deserialize<PersistModel>(File.ReadAllText(_filePath), JsonOptions.Default);
            if (doc is null) return;
            lock (_gate)
            {
                _whitelist = doc.Whitelist ?? new();
                _blacklist = doc.Blacklist ?? new();
            }
            App.LogDiag($"[DeviceList] 已加载 白名单={_whitelist.Count} 黑名单={_blacklist.Count}");
        }
        catch (Exception ex)
        {
            App.LogDiag($"[DeviceList] 加载失败：{ex.Message}");
        }
    }

    public void AddWhitelist(string fingerprint, string alias, string? deviceModel = null, DeviceType? deviceType = null)
    {
        lock (_gate)
        {
            // 黑白互斥：先从黑名单移除（避免一个设备既是白又是黑）
            _blacklist.RemoveAll(x => x.Fingerprint == fingerprint);
            var existing = _whitelist.FirstOrDefault(x => x.Fingerprint == fingerprint);
            if (existing is not null)
            {
                existing.Alias = alias;
                if (deviceModel is not null) existing.DeviceModel = deviceModel;
                if (deviceType is not null) existing.DeviceType = deviceType;
            }
            else
            {
                _whitelist.Add(new DeviceListEntry
                {
                    Fingerprint = fingerprint,
                    Alias = alias,
                    DeviceModel = deviceModel,
                    DeviceType = deviceType,
                    AutoAccept = false,
                });
            }
        }
        // 始终广播 + 持久化：即使已存在（元数据更新），UI 也需刷新别名/型号
        OnChanged();
    }

    public void RemoveWhitelist(string fingerprint)
    {
        bool changed;
        lock (_gate)
        {
            changed = _whitelist.RemoveAll(x => x.Fingerprint == fingerprint) > 0;
        }
        if (changed) OnChanged();
    }

    public void SetWhitelistAutoAccept(string fingerprint, bool autoAccept)
    {
        bool changed;
        lock (_gate)
        {
            var entry = _whitelist.FirstOrDefault(x => x.Fingerprint == fingerprint);
            if (entry is null) return;
            if (entry.AutoAccept == autoAccept) return;
            entry.AutoAccept = autoAccept;
            changed = true;
        }
        if (changed) OnChanged();
    }

    public void AddBlacklist(string fingerprint, string alias, string? deviceModel = null, DeviceType? deviceType = null)
    {
        lock (_gate)
        {
            // 黑白互斥：先从白名单移除
            _whitelist.RemoveAll(x => x.Fingerprint == fingerprint);
            var existing = _blacklist.FirstOrDefault(x => x.Fingerprint == fingerprint);
            if (existing is not null)
            {
                existing.Alias = alias;
                if (deviceModel is not null) existing.DeviceModel = deviceModel;
                if (deviceType is not null) existing.DeviceType = deviceType;
            }
            else
            {
                _blacklist.Add(new DeviceListEntry
                {
                    Fingerprint = fingerprint,
                    Alias = alias,
                    DeviceModel = deviceModel,
                    DeviceType = deviceType,
                    AutoAccept = false, // 黑名单恒 false
                });
            }
        }
        // 始终广播 + 持久化：即使已存在（元数据更新），UI 也需刷新
        OnChanged();
    }

    public void RemoveBlacklist(string fingerprint)
    {
        bool changed;
        lock (_gate)
        {
            changed = _blacklist.RemoveAll(x => x.Fingerprint == fingerprint) > 0;
        }
        if (changed) OnChanged();
    }

    public bool IsBlacklisted(string fingerprint)
    {
        lock (_gate) return _blacklist.Exists(x => x.Fingerprint == fingerprint);
    }

    public DeviceListEntry? FindWhitelist(string fingerprint)
    {
        lock (_gate) return _whitelist.FirstOrDefault(x => x.Fingerprint == fingerprint)?.Clone();
    }

    public void Rename(string fingerprint, string newAlias)
    {
        bool changed;
        lock (_gate)
        {
            var w = _whitelist.FirstOrDefault(x => x.Fingerprint == fingerprint);
            if (w is not null)
            {
                w.Alias = newAlias;
                changed = true;
            }
            else
            {
                var b = _blacklist.FirstOrDefault(x => x.Fingerprint == fingerprint);
                if (b is not null)
                {
                    b.Alias = newAlias;
                    changed = true;
                }
                else changed = false;
            }
        }
        if (changed) OnChanged();
    }

    private void OnChanged()
    {
        Persist();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void Persist()
    {
        try
        {
            PersistModel snapshot;
            lock (_gate)
            {
                snapshot = new PersistModel
                {
                    Whitelist = _whitelist.ToList(),
                    Blacklist = _blacklist.ToList(),
                };
            }
            lock (_fileGate)
            {
                var tmp = _filePath + ".tmp";
                File.WriteAllText(tmp, JsonSerializer.Serialize(snapshot, JsonOptions.Default));
                if (File.Exists(_filePath)) File.Replace(tmp, _filePath, null);
                else File.Move(tmp, _filePath);
            }
        }
        catch (Exception ex)
        {
            App.LogDiag($"[DeviceList] 持久化失败：{ex.Message}");
        }
    }
}

// 持久化 JSON 顶层结构：{ "whitelist": [...], "blacklist": [...] }
internal sealed class PersistModel
{
    public List<DeviceListEntry> Whitelist { get; set; } = new();
    public List<DeviceListEntry> Blacklist { get; set; } = new();
}

// 便捷扩展：深拷贝（FindWhitelist 返回副本，避免外部改动内部状态）
internal static class DeviceListEntryExtensions
{
    public static DeviceListEntry? Clone(this DeviceListEntry? entry)
        => entry is null ? null : new DeviceListEntry
        {
            Fingerprint = entry.Fingerprint,
            Alias = entry.Alias,
            DeviceModel = entry.DeviceModel,
            DeviceType = entry.DeviceType,
            AddedAtUtc = entry.AddedAtUtc,
            AutoAccept = entry.AutoAccept,
        };
}
