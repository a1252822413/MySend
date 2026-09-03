// 设备注册表实现：用 ConcurrentDictionary<fingerprint, Device> 维护内存设备字典。
// 后台线程可安全 Upsert；通过 IMessenger 广播 DeviceDiscoveredMessage / DeviceTimedOutMessage。
// UI 由 ReceiveViewModel 监听这些消息，在 UI 线程同步 ObservableCollection<Device>。
//
// 设计哲学（对齐官方 LocalSend 2026-09-03）：
//   设备列表是快照式，不做事后超时清理。设备加入后一直保留，直到用户手动刷新
//   （RemoveStaleSince 清理未响应设备）或重启 App。避免 UDP 丢包误删在线设备。
//   UI 通过 Device.IsOnline（50s 阈值）显示离线灰态，提示用户哪些设备可能不在了。
using System.Collections.Concurrent;
using CommunityToolkit.Mvvm.Messaging;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.Models.Dto;

namespace PcDemo.Services;

public sealed class DeviceRegistry : IDeviceRegistry, IDisposable
{
    private const int BroadcastDebounceMs = 2000; // 同一指纹去抖窗口，防多 IP 轮替导致消息风暴
    private const int MaxDevices = 100;           // 容量上限：防重装换指纹的僵尸设备无限累积
    private readonly IMessenger _messenger;
    private readonly ConcurrentDictionary<string, Device> _devices = new();
    // 最近一次广播时间（UTC ticks），指纹级去抖
    private readonly ConcurrentDictionary<string, long> _lastBroadcastTicks = new();

    public DeviceRegistry(IMessenger messenger)
    {
        _messenger = messenger;
    }

    public void Upsert(string ip, string alias, string? deviceModel, DeviceType? deviceType,
        string fingerprint, ushort port, ProtocolType protocol, string version, bool download)
    {
        var now = DateTime.UtcNow.Ticks;
        var changed = false;
        var isNew = false;

        _devices.AddOrUpdate(
            fingerprint,
            _ =>
            {
                isNew = true;
                changed = true;
                return new Device
                {
                    Fingerprint = fingerprint,
                    Alias = alias,
                    DeviceModel = deviceModel,
                    DeviceType = deviceType,
                    Port = port,
                    Protocol = protocol,
                    Version = version,
                    Download = download,
                    Ip = ip,
                    LastSeenUtcTicks = now,
                };
            },
            (_, existing) =>
            {
                // 关键修复（2026-09-03）：同一指纹设备的 Ip 在多接口间轮替到达
                // （如 192.168.31.140 ↔ 172.17.1.1 Docker 网段）时，Ip 变化不再
                // 视为关键字段变化，避免每条公告都广播→UI 风暴。Ip 仍静默更新。
                changed = !string.Equals(existing.Alias, alias, StringComparison.Ordinal)
                    || existing.Port != port
                    || existing.Protocol != protocol
                    || existing.Download != download
                    || existing.DeviceType != deviceType;
                existing.Alias = alias;
                existing.DeviceModel = deviceModel;
                existing.DeviceType = deviceType;
                existing.Port = port;
                existing.Protocol = protocol;
                existing.Version = version;
                existing.Download = download;
                existing.Ip = ip;
                existing.LastSeenUtcTicks = now;
                return existing;
            });

        if (!changed) return;

        // 容量上限：对方 App 重装/清数据后指纹会变，旧条目永远收不到公告却占着内存与 UI；
        // 超限按 LastSeen 淘汰最旧设备（快照式设计仍保留——不因超时误删，只防无限增长）
        if (_devices.Count > MaxDevices)
        {
            var oldest = _devices.Values.OrderBy(v => v.LastSeenUtcTicks).FirstOrDefault();
            if (oldest is not null && !string.Equals(oldest.Fingerprint, fingerprint, StringComparison.Ordinal))
                Remove(oldest.Fingerprint); // Remove 内部会广播 DeviceTimedOutMessage → UI 同步移除
        }

        // 双保险：同一指纹去抖窗口内不重复广播。
        // 手机多网卡/多 IP 公告会在同一秒内从多个 IP 到达，上面 changed 判断已过滤 Ip 变化，
        // 但 Alias/Port 等在握手期也可能不稳定，这里再判一次时间窗口。
        var debounceTicks = TimeSpan.FromMilliseconds(BroadcastDebounceMs).Ticks;
        if (!isNew)
        {
            var lastTick = _lastBroadcastTicks.TryGetValue(fingerprint, out var t) ? t : 0;
            if (now - lastTick < debounceTicks) return;
        }
        _lastBroadcastTicks[fingerprint] = now;

        _messenger.Send(new DeviceDiscoveredMessage
        {
            Ip = ip,
            Message = new MulticastMessageV2
            {
                Alias = alias,
                Version = version,
                DeviceModel = deviceModel,
                DeviceType = deviceType,
                Fingerprint = fingerprint,
                Port = port,
                Protocol = protocol,
                Download = download,
            },
        });
    }

    public void Remove(string fingerprint)
    {
        _lastBroadcastTicks.TryRemove(fingerprint, out _);
        if (_devices.TryRemove(fingerprint, out _))
        {
            _messenger.Send(new DeviceTimedOutMessage { Fingerprint = fingerprint });
        }
    }

    public void Clear()
    {
        var keys = _devices.Keys.ToList();
        foreach (var k in keys) _lastBroadcastTicks.TryRemove(k, out _);
        _devices.Clear();
        foreach (var k in keys)
        {
            _messenger.Send(new DeviceTimedOutMessage { Fingerprint = k });
        }
    }

    public IReadOnlyList<Device> GetSnapshot() => _devices.Values.ToList();

    public Device? Find(string fingerprint)
        => _devices.TryGetValue(fingerprint, out var d) ? d : null;

    public void RemoveStaleSince(DateTime cutoff)
    {
        var cutoffTicks = cutoff.Ticks;
        foreach (var kv in _devices)
        {
            if (kv.Value.LastSeenUtcTicks < cutoffTicks)
            {
                _lastBroadcastTicks.TryRemove(kv.Key, out _);
                if (_devices.TryRemove(kv.Key, out _))
                {
                    _messenger.Send(new DeviceTimedOutMessage { Fingerprint = kv.Key });
                }
            }
        }
    }

    public void Dispose()
    {
        // 无后台定时器需要清理（对齐官方：不做事后超时清理）
    }
}

/// <summary>
/// UI 设备集合同步助手：ReceiveViewModel / SendViewModel 共用，
/// 统一「registry 实例复用 + 原位 UpdateFrom」逻辑（保留 ListView 选中引用）。
/// </summary>
public static class DeviceCollectionSync
{
    /// <summary>把一条发现消息同步进 UI 集合（必须在 UI 线程调用）。</summary>
    public static void Sync(System.Collections.ObjectModel.ObservableCollection<Device> devices,
        IDeviceRegistry registry, string ip, PcDemo.Models.Dto.MulticastMessageV2 m)
    {
        var existing = devices.FirstOrDefault(d => d.Fingerprint == m.Fingerprint);
        if (existing is null)
        {
            // 优先复用 registry 的实例：后续 Upsert 会原位刷新同一对象，两个页面共享最新状态；
            // registry 中不存在（理论少见，消息本就来自 registry）才用消息字段构造
            devices.Add(registry.Find(m.Fingerprint) ?? new Device
            {
                Fingerprint = m.Fingerprint,
                Alias = m.Alias,
                DeviceModel = m.DeviceModel,
                DeviceType = m.DeviceType,
                Port = m.Port,
                Protocol = m.Protocol,
                Version = m.Version,
                Download = m.Download,
                Ip = ip,
                LastSeenUtcTicks = DateTime.UtcNow.Ticks,
            });
            return;
        }

        // 已在列表：registry 实例与列表实例相同则无需处理（Upsert 发消息前已原位刷新）；
        // 不同（历史遗留的 fallback 构造实例）则原位更新，保留引用不破坏选中态
        var latest = registry.Find(m.Fingerprint);
        if (latest is not null && !ReferenceEquals(latest, existing))
            existing.UpdateFrom(latest);
    }
}
