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
