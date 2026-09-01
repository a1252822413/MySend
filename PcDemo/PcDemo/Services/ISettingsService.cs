// 设置服务接口：提供内存中可读写的设置访问，并持久化到 settings.json。
using PcDemo.Models;

namespace PcDemo.Services;

public interface ISettingsService
{
    AppSettings Current { get; }

    /// <summary>从 settings.json 加载到内存；不存在则创建默认值并保存。</summary>
    void Load();

    /// <summary>更新字段并立即持久化。</summary>
    void Update(Action<AppSettings> mutator);

    event EventHandler<AppSettings>? Changed;
}
