// 设置服务：读写 %LOCALAPPDATA%\PcDemo\settings.json，内存中维护当前设置。
// Unpackaged 模式下 ApplicationData.Current 不可用，改用 SpecialFolder.LocalApplicationData。
using System.Text.Json;
using PcDemo.Helpers;
using PcDemo.Models;

namespace PcDemo.Services;

public sealed class SettingsService : ISettingsService
{
    private static readonly object _fileLock = new();
    private AppSettings _current = new();

    public AppSettings Current => _current;

    public event EventHandler<AppSettings>? Changed;

    public void Load()
    {
        var path = PathHelper.SettingsFilePath;
        try
        {
            if (!File.Exists(path))
            {
                EnsureDefaults(_current);
                Save(_current);
                return;
            }
            var json = File.ReadAllText(path);
            var loaded = JsonSerializer.Deserialize<AppSettings>(json, JsonOptions.Default) ?? new AppSettings();
            EnsureDefaults(loaded);
            _current = loaded;
        }
        catch (Exception ex)
        {
            // 设置文件损坏：记录日志 + 备份原文件（方便手动恢复）+ 重建默认设置
            // 不再静默丢失，避免用户别名/端口/下载目录等配置被悄悄重置
            App.LogDiag($"[Settings] settings.json 加载失败，已备份并重建默认值：{ex.GetType().Name}: {ex.Message}");
            try
            {
                if (File.Exists(path))
                {
                    var bak = path + ".bak";
                    // 覆盖旧备份（只保留最近一次损坏文件，避免无限累积）
                    if (File.Exists(bak)) File.Delete(bak);
                    File.Move(path, bak);
                }
            }
            catch (Exception bakEx)
            {
                App.LogDiag($"[Settings] 备份损坏文件失败：{bakEx.Message}");
            }
            _current = new AppSettings();
            EnsureDefaults(_current);
            Save(_current);
        }
    }

    public void Update(Action<AppSettings> mutator)
    {
        mutator(_current);
        Save(_current);
        Changed?.Invoke(this, _current);
    }

    private static void Save(AppSettings settings)
    {
        lock (_fileLock)
        {
            try
            {
                var dir = PathHelper.AppDataDir;
                Directory.CreateDirectory(dir);
                var json = JsonSerializer.Serialize(settings, JsonOptions.Default);
                // 原子写：先写临时文件再替换，避免进程崩溃留下损坏的 JSON
                var path = PathHelper.SettingsFilePath;
                var tmp = path + ".tmp";
                File.WriteAllText(tmp, json);
                if (File.Exists(path)) File.Replace(tmp, path, null);
                else File.Move(tmp, path);
            }
            catch
            {
                // 写盘失败不影响运行（内存中仍有 _current）
            }
        }
    }

    /// <summary>首次启动时填充缺失的默认值（如 Fingerprint 随机生成一次并持久化）。</summary>
    private static void EnsureDefaults(AppSettings s)
    {
        if (string.IsNullOrWhiteSpace(s.Alias))
            s.Alias = Environment.MachineName;

        if (s.Port == 0)
            s.Port = AppSettings.DefaultPort;

        if (string.IsNullOrWhiteSpace(s.MulticastGroup))
            s.MulticastGroup = AppSettings.DefaultMulticastGroup;

        if (string.IsNullOrWhiteSpace(s.Destination))
            s.Destination = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) is var home && !string.IsNullOrEmpty(home)
                ? Path.Combine(home, "Downloads")
                : Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        if (string.IsNullOrWhiteSpace(s.DeviceModel))
            s.DeviceModel = "Windows";

        s.DeviceType ??= Models.Dto.DeviceType.Desktop;

        // Fingerprint 仅在为空时生成一次（持久化后下次启动复用同一指纹）
        if (string.IsNullOrWhiteSpace(s.Fingerprint))
            s.Fingerprint = Guid.NewGuid().ToString("N");
    }
}
