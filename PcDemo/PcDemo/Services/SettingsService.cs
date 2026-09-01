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
        try
        {
            var path = PathHelper.SettingsFilePath;
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
        catch
        {
            _current = new AppSettings();
            EnsureDefaults(_current);
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
                File.WriteAllText(PathHelper.SettingsFilePath, json);
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
            s.Port = 53317;

        if (string.IsNullOrWhiteSpace(s.MulticastGroup))
            s.MulticastGroup = "224.0.0.167";

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
