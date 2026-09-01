// App.xaml.cs —— 应用入口：构建 DI 容器、加载设置、启动 UDP 被动监听（Kestrel 延迟启动）。
//
// 延迟启动策略：
//   App 启动 → 只开 UDP 多播被动监听（不发公告、不开 Kestrel）
//   收到第一个 DeviceDiscoveredMessage → EnsureKestrelRunningAsync（Start Kestrel → AnnounceOnce → StartPeriodicAnnounce）
//   空闲 60s（无设备 + 无收发会话）→ Stop Kestrel + StopPeriodicAnnounce，只保留 UDP 监听
// 这样空闲态省掉 Kestrel 运行时 50-80MB 的常驻内存。
using System.Threading;
using CommunityToolkit.Mvvm.Messaging;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.Networking;
using PcDemo.Services;
using PcDemo.ViewModels;
using PcDemo.Views;
using Windows.Storage;

namespace PcDemo;

public partial class App : Application, IRecipient<DeviceDiscoveredMessage>
{
    internal static IServiceProvider Services { get; private set; } = null!;
    internal static ShellWindow MainWindow { get; private set; } = null!;
    private static LocalSendHttpServer? _http;
    private static MulticastDiscoveryService? _multicast;

    // 延迟启动相关：Kestrel 启动幂等守卫 + 空闲自动停
    private static readonly object _kestrelGate = new();
    private static bool _kestrelStarted;
    private static Timer? _idleCheckTimer;
    private const int IdleCheckIntervalMs = 15_000;   // 每 15s 检查一次
    private const int IdleTimeoutMs = 60_000;        // 连续 60s 无设备 + 无会话 → 停 Kestrel

    // 空闲最后时间戳（设备数变 0 时开始计时）
    private static long _idleSinceTicks;

    public App()
    {
        this.InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        LogDiag("OnLaunched: enter");
        try
        {
            // 1. 构建 DI 容器
            var services = new ServiceCollection();
            ConfigureServices(services);
            Services = services.BuildServiceProvider();
            LogDiag("OnLaunched: DI container built");

            // 2. 加载设置（含默认 fingerprint 生成）
            var settings = Services.GetRequiredService<ISettingsService>();
            settings.Load();
            LogDiag($"OnLaunched: settings loaded, alias={settings.Current.Alias}, port={settings.Current.Port}, fp={settings.Current.Fingerprint}");

            // 2.2 启动时根据 ThemeMode 应用主题（ShellWindow 激活后会立即生效）
            ThemeApplier.Apply(settings.Current.ThemeMode);

            // 2.5 设备身份 = mTLS 客户端证书指纹（官方协议硬性要求：
            //     HTTPS 模式下请求 body 的 fingerprint 必须与 TLS 客户端证书一致，
            //     否则对方会静默丢弃接收事件 → prepare-upload 永久挂起无响应）。
            var identityCert = ClientIdentity.GetOrCreate();
            if (identityCert is not null)
            {
                var certFp = ClientIdentity.ComputeFingerprint(identityCert);
                if (!string.Equals(settings.Current.Fingerprint, certFp, StringComparison.Ordinal))
                {
                    settings.Update(s => s.Fingerprint = certFp);
                    LogDiag($"[TLS] fingerprint 已同步为 mTLS 证书指纹: {certFp}");
                }
            }

            // 3. 订阅设置变更：端口/多播组变化时重启 discovery + server
            settings.Changed += OnSettingsChanged;

            // 3.1 订阅 UDP 发现消息（首次收到时触发 Kestrel 延迟启动）
            WeakReferenceMessenger.Default.Register(this);

            // 4. 启动网络：恢复延迟启动架构——只开 UDP 被动监听，
            //    Kestrel + 公告在首次发现设备时由 EnsureKestrelRunning 启动。
            //    （此前 no-deferred 是为绕过 Messenger 分裂导致延迟启动失效，已修复，故恢复）
            StartUdpOnly();

            // 4.1 空闲检查：每 15s 一次，无设备 + 无会话持续 60s → 停 Kestrel 省内存
            _idleCheckTimer ??= new Timer(_ => CheckAndStopIfIdle(), null,
                IdleCheckIntervalMs, IdleCheckIntervalMs);

            // 4.5 加载传输历史（JSON 持久化）
            Services.GetRequiredService<TransferHistoryService>().Load();

            // 5. 创建并显示主窗口
            MainWindow = Services.GetRequiredService<ShellWindow>();
            MainWindow.Closed += OnWindowClosed;
            MainWindow.Activate();
            LogDiag("OnLaunched: window activated");
        }
        catch (Exception ex)
        {
            LogDiag($"OnLaunched FAILED: {ex}");
            throw;
        }
    }

    private static void ConfigureServices(IServiceCollection services)
    {
        // 服务层
        services.AddSingleton<ISettingsService, SettingsService>();
        // 必须统一使用 WeakReferenceMessenger.Default 静态单例：
        // 若由容器自建实例，DeviceRegistry 发布的消息 App（注册在 Default 上）将收不到，
        // "收到公告→立即回播"失效，手机端只能等周期公告才能发现本机
        services.AddSingleton<IMessenger>(_ => WeakReferenceMessenger.Default);
        services.AddSingleton<IDeviceInfoBuilder, DeviceInfoBuilder>();
        services.AddSingleton<IFileSaver, FileSaver>();
        services.AddSingleton<IReceiveSessionManager, ReceiveSessionManager>();
        services.AddSingleton<IDeviceRegistry, DeviceRegistry>();
        services.AddSingleton<ISendSessionManager, SendSessionManager>();
        services.AddSingleton<TransferHistoryService>();

        // 网络层
        services.AddSingleton<LocalSendHttpServer>();
        services.AddSingleton<MulticastDiscoveryService>();
        // SendClient：通过工厂从 StaticHttpClient 拿单例共享 HTTP 连接
        services.AddSingleton<SendClient>(sp => new SendClient(
            Networking.StaticHttpClient.Instance,
            sp.GetRequiredService<ISettingsService>()));
        // DI 级唯一 DispatcherQueue（给 SendSessionManager 在 UI 线程推状态），
        // 首次访问时用 MainWindow.DispatcherQueue（启动后立即就绪）。
        services.AddSingleton<Microsoft.UI.Dispatching.DispatcherQueue>(_ =>
            MainWindow?.DispatcherQueue
                ?? Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());

        // ViewModels + Window
        services.AddSingleton<ShellViewModel>();
        services.AddSingleton<ReceiveViewModel>();
        services.AddSingleton<SettingsViewModel>();
        services.AddSingleton<SendViewModel>();
        services.AddSingleton<HistoryViewModel>();
        services.AddSingleton<ShellWindow>();
    }

    /// <summary>
    /// 只开 UDP 多播被动监听——Kestrel HTTP server 在首次收到其他设备的公告时才启动。
    /// 这样空闲态省掉 ASP.NET Core 运行时 50-80MB 的常驻内存。
    /// </summary>
    private static void StartUdpOnly()
    {
        try
        {
            _multicast ??= Services.GetRequiredService<MulticastDiscoveryService>();
            if (!_multicast.IsRunning)
            {
                _multicast.Start();
                // 注意：不调用 AnnounceOnceAsync，避免其他设备认为我们在线但 /prepare-upload 不可达
                LogDiag("Multicast UDP passive listener started (Kestrel deferred)");
            }
        }
        catch (Exception ex)
        {
            LogDiag($"Multicast start failed: {ex}");
        }
    }

    /// <summary>
    /// 幂等启动 Kestrel HTTP server + 周期 UDP 公告。
    /// 触发时机：收到 DeviceDiscoveredMessage、用户手动点刷新、设置变更后。
    /// </summary>
    public static void EnsureKestrelRunning()
    {
        if (_kestrelStarted) return;
        lock (_kestrelGate)
        {
            if (_kestrelStarted) return;

            _http ??= Services.GetRequiredService<LocalSendHttpServer>();
            if (!_http.IsRunning)
            {
                _http.Start();
                LogDiag($"HTTP server started on port {_http.RunningPort} (deferred)");
            }

            // Kestrel 就绪后才能发公告——否则其他设备收到公告后发 prepare-upload 会连不上
            _multicast ??= Services.GetRequiredService<MulticastDiscoveryService>();
            _ = _multicast.AnnounceOnceAsync();
            _multicast.StartPeriodicAnnounce(TimeSpan.FromSeconds(3));

            _kestrelStarted = true;
            _idleSinceTicks = long.MaxValue; // 重置空闲计时
            LogDiag("Kestrel + periodic announce activated");
        }
    }

    /// <summary>DeviceDiscoveredMessage 处理：收到设备公告 = 对方在找我们。
    /// 1) Kestrel 未启动（延迟启动/空闲已停）：先 EnsureKestrelRunning（启动 HTTP → 回播公告 → 开周期公告）
    /// 2) Kestrel 已运行：立即回播公告（官方双向可见机制的核心）
    /// 保证"手机先开 → PC 回播 → 手机看得到 PC"，且回播时 prepare-upload 端点一定就绪。</summary>
    public void Receive(DeviceDiscoveredMessage message)
    {
        _multicast ??= Services.GetRequiredService<MulticastDiscoveryService>();

        if (!_kestrelStarted)
        {
            // 首次发现：先启动 Kestrel（内部随后回播公告 + 开周期公告），
            // 保证对方收到公告、发 prepare-upload 时端口已就绪
            LogDiag($"[Kestrel] first device discovered ({message.Message.Alias}), triggering deferred start");
            EnsureKestrelRunning();
        }
        else
        {
            // 已在运行：立即回播公告（官方双向可见机制的核心）
            _ = _multicast.AnnounceOnceAsync();
        }
    }

    /// <summary>
    /// 空闲检查：每 15s 看一眼。设备数=0 且无收发会话连续 60s → 停 Kestrel 省内存。
    /// 只保留 UDP 监听（~几 MB），下次发现设备再自动启动。
    /// </summary>
    private static void CheckAndStopIfIdle()
    {
        try
        {
            if (!_kestrelStarted) return;

            var registry = Services.GetService<IDeviceRegistry>();
            var sessions = Services.GetService<IReceiveSessionManager>();
            var sendSessions = Services.GetService<ISendSessionManager>();
            if (registry is null || sessions is null || sendSessions is null) return;

            var noDevices = registry.GetSnapshot().Count == 0;
            var noReceiveSession = sessions.CurrentSession is null;
            var noSendSession = sendSessions.Current is null;
            var trulyIdle = noDevices && noReceiveSession && noSendSession;

            if (trulyIdle)
            {
                // 开始计时
                if (_idleSinceTicks == long.MaxValue)
                    _idleSinceTicks = Environment.TickCount64;

                var idleMs = Environment.TickCount64 - _idleSinceTicks;
                if (idleMs >= IdleTimeoutMs)
                {
                    LogDiag($"[Kestrel] idle {idleMs}ms, stopping to save memory");
                    _multicast?.StopPeriodicAnnounce();
                    _ = (_http?.StopAsync() ?? Task.CompletedTask);
                    _kestrelStarted = false;
                    _idleSinceTicks = long.MaxValue;
                }
            }
            else
            {
                // 有设备或会话 → 重置空闲计时
                _idleSinceTicks = long.MaxValue;
            }
        }
        catch (Exception ex)
        {
            LogDiag($"[IdleCheck] error: {ex.Message}");
        }
    }

    internal static bool TryGetMainWindow([System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out ShellWindow? window)
    {
        window = MainWindow;
        return window is not null;
    }

    internal static void LogDiag(string message)
    {
        try
        {
            System.Diagnostics.Debug.WriteLine(message);
            // MSIX 沙箱下用 ApplicationData.Current.LocalFolder，确保可写
            var folder = ApplicationData.Current.LocalFolder;
            var logPath = System.IO.Path.Combine(folder.Path, "diag.log");
            System.IO.File.AppendAllText(logPath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
        }
        catch { /* 诊断日志写盘失败不影响主流程 */ }
    }

    private static async void OnSettingsChanged(object? sender, AppSettings e)
    {
        // 设置变更 → 先全停再重启
        try
        {
            _multicast?.Stop();
            if (_http is not null) await _http.StopAsync();
            _kestrelStarted = false;
        }
        catch { /* ignore */ }

        // 只重启 UDP 被动监听；Kestrel 等下次收到 DeviceDiscoveredMessage 再启动
        StartUdpOnly();
    }

    private static async void OnWindowClosed(object sender, WindowEventArgs args)
    {
        try
        {
            WeakReferenceMessenger.Default.UnregisterAll(CurrentApp);
            _idleCheckTimer?.Dispose();
            _multicast?.Stop();
            if (_http is not null) await _http.StopAsync();
        }
        catch { /* ignore */ }
    }

    /// <summary>方便 ReceiveViewModel.RefreshDevicesAsync 等调用，从外部访问 App 单例。</summary>
    private static App CurrentApp => (App)Current;
}
