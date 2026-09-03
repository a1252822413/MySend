// 设备名单服务接口：白名单 + 黑名单的内存管理与持久化。
using PcDemo.Models;
using PcDemo.Models.Dto;

namespace PcDemo.Services;

public interface IDeviceListService
{
    /// <summary>白名单条目（只读快照；UI 绑定用，修改走服务方法）。</summary>
    IReadOnlyList<DeviceListEntry> Whitelist { get; }

    /// <summary>黑名单条目（只读快照）。</summary>
    IReadOnlyList<DeviceListEntry> Blacklist { get; }

    /// <summary>名单变化时触发（增删改 AutoAccept），UI 订阅刷新。</summary>
    event EventHandler? Changed;

    /// <summary>加载持久化数据（启动时调用）。</summary>
    void Load();

    /// <summary>加入白名单（已存在则更新别名/型号，不覆盖 AutoAccept）。</summary>
    void AddWhitelist(string fingerprint, string alias, string? deviceModel = null, DeviceType? deviceType = null);

    /// <summary>从白名单移除。</summary>
    void RemoveWhitelist(string fingerprint);

    /// <summary>切换白名单条目的自动接收开关。</summary>
    void SetWhitelistAutoAccept(string fingerprint, bool autoAccept);

    /// <summary>加入黑名单（若同时在白名单则先从白名单移除，避免冲突）。</summary>
    void AddBlacklist(string fingerprint, string alias, string? deviceModel = null, DeviceType? deviceType = null);

    /// <summary>从黑名单移除。</summary>
    void RemoveBlacklist(string fingerprint);

    /// <summary>设备是否在黑名单中（PrepareUpload 端点调用快速判断）。</summary>
    bool IsBlacklisted(string fingerprint);

    /// <summary>查找白名单条目（ReceiveViewModel 判断是否自动接收）。</summary>
    DeviceListEntry? FindWhitelist(string fingerprint);

    /// <summary>重命名白名单/黑名单条目的别名（UI 编辑用）。</summary>
    void Rename(string fingerprint, string newAlias);
}
