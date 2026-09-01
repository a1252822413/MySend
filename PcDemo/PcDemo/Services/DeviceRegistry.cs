// 设备注册表实现：用 ConcurrentDictionary<fingerprint, Device> 维护内存设备字典。
// 后台线程可安全 Upsert；通过 IMessenger 广播 DeviceDiscoveredMessage / DeviceTimedOutMessage。
// UI 由 ReceiveViewModel 监听这些消息，在 UI 线程同步 ObservableCollection<Device>。
using System.Collections.Concurrent;
using CommunityToolkit.Mvvm.Messaging;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.Models.Dto;

namespace PcDemo.Services;

public sealed class DeviceRegistry : IDeviceRegistry, IDisposable
{
    private const int TimeoutSeconds = 60;
    private readonly IMessenger _messenger;
    private readonly Timer _cleanupTimer;
    private readonly ConcurrentDictionary<string, Device> _devices = new();

    public DeviceRegistry(IMessenger messenger)
    {
        _messenger = messenger;
        _cleanupTimer = new Timer(_ => CleanupStale(), null,
            TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(15));
    }

    public void Upsert(string ip, string alias, string? deviceModel, DeviceType? deviceType,
        string fingerprint, ushort port, ProtocolType protocol, string version, bool download)
    {
        _devices.AddOrUpdate(
            fingerprint,
            _ => new Device
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
                LastSeenUtcTicks = DateTime.UtcNow.Ticks,
            },
            (_, existing) =>
            {
                existing.Alias = alias;
                existing.DeviceModel = deviceModel;
                existing.DeviceType = deviceType;
                existing.Port = port;
                existing.Protocol = protocol;
                existing.Version = version;
                existing.Download = download;
                existing.Ip = ip;
                existing.LastSeenUtcTicks = DateTime.UtcNow.Ticks;
                return existing;
            });

        // 广播消息（注意 Device 字段非线程安全，但此处只读属性；UI 同步在 UI 线程做）
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
        if (_devices.TryRemove(fingerprint, out _))
        {
            _messenger.Send(new DeviceTimedOutMessage { Fingerprint = fingerprint });
        }
    }

    public void Clear()
    {
        var keys = _devices.Keys.ToList();
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
                if (_devices.TryRemove(kv.Key, out _))
                {
                    _messenger.Send(new DeviceTimedOutMessage { Fingerprint = kv.Key });
                }
            }
        }
    }

    private void CleanupStale()
    {
        var now = DateTime.UtcNow.Ticks;
        var timeout = TimeSpan.FromSeconds(TimeoutSeconds).Ticks;
        foreach (var kv in _devices)
        {
            if (now - kv.Value.LastSeenUtcTicks > timeout)
            {
                if (_devices.TryRemove(kv.Key, out _))
                {
                    _messenger.Send(new DeviceTimedOutMessage { Fingerprint = kv.Key });
                }
            }
        }
    }

    public void Dispose() => _cleanupTimer.Dispose();
}
