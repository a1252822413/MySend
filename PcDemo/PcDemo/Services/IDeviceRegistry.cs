// 设备注册表接口：线程安全的内存设备字典（ConcurrentDictionary）。
// UI 同步由 ReceiveViewModel 监听 DeviceDiscoveredMessage / DeviceTimedOutMessage 完成。
// 这样后台线程（多播/Kestrel）可安全调用 Upsert 而不触碰 UI 集合。
using PcDemo.Models;
using PcDemo.Models.Dto;

namespace PcDemo.Services;

public interface IDeviceRegistry
{
    /// <summary>记录一次设备公告/注册（更新或插入），并发 DeviceDiscoveredMessage。</summary>
    void Upsert(string ip, string alias, string? deviceModel, DeviceType? deviceType,
                string fingerprint, ushort port, ProtocolType protocol, string version, bool download);

    /// <summary>按指纹移除设备（用于超时/主动剔除），并发 DeviceTimedOutMessage。</summary>
    void Remove(string fingerprint);

    /// <summary>清空设备字典。</summary>
    void Clear();

    /// <summary>获取设备快照列表。</summary>
    IReadOnlyList<Device> GetSnapshot();

    /// <summary>按指纹查询单个设备。</summary>
    Device? Find(string fingerprint);

    /// <summary>
    /// 主动移除超时设备：LastSeenUtcTicks 早于 cutoff 的设备被 Remove 并发 DeviceTimedOutMessage。
    /// 用于刷新时——在线设备回播后 LastSeen 新于 cutoff 被保留，离线设备没回播被清除。
    /// </summary>
    void RemoveStaleSince(DateTime cutoff);
}
