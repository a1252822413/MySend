// App.xaml.cs —— 应用入口：构建 DI 容器、加载设置、启动网络（UDP 监听 + Kestrel + 周期公告，常驻）。
//
// Kestrel + 周期公告必须随应用常驻（2026-09-02 实测结论，勿改回延迟启动）：
//   官方协议是 UDP 公告 + HTTP register 应答，这要求公告方的 HTTP 服务器在线。
//   延迟启动/空闲停止会切断该通道：PC 静默 = 手机看不到 PC；
//   手机 register 打到已停止的 PC = PC 看不到手机。官方 PC 客户端从不停止服务器。
using System.Linq;
using System.Threading;
using CommunityToolkit.Mvvm.Messaging;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using PcDemo.Helpers;
using PcDemo.Messages;
using PcDemo.Models;
using PcDemo.Networking;
using PcDemo.Services;
using PcDemo.ViewModels;
using PcDemo.Views;
using Windows.Storage;
using Windows.UI.Notifications;

namespace PcDemo;

public partial class App : Application, IRecipient<DeviceDiscoveredMessage>
{
    internal static IServiceProvider Services { get; private set; } = null!;
    internal static ShellWindow MainWindow { get; private set; } = null!;
    private static LocalSendHttpServer? _http;
    private static MulticastDiscoveryService? _multicast;

    // Kestrel 启动幂等守卫
    private static readonly object _kestrelGate = new();
    private static bool _kestrelStarted;

    // 托盘常驻：关窗隐藏到托盘，后台继续接收；「退出」才真正结束进程
    private static TrayIconManager? _tray;

    /// <summary>主窗口是否被隐藏到托盘。用应用自身状态而非 AppWindow.IsVisible 判断
    /// （实测 Hide() 后 IsVisible 仍可能返回 true，会导致接收请求被误判"可见"而弹到看不见的窗口）。</summary>
    private static bool _windowHiddenToTray;

    /// <summary>是否已弹过"已最小化到托盘"的首次引导提示（每个会话只弹一次）。</summary>
    private static bool _trayGuideShown;

    public App()
    {
        this.InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        LogDiag("OnLaunched: enter");
        try
        {
            // 0. 单实例：已有实例运行时，把本次激活（重复启动图标 / 点击 toast 通知）重定向过去，
            //    由已有实例响应（显示主窗口）并退出自身，避免多开端口冲突
            var current = AppInstance.GetCurrent();
            var existing = AppInstance.GetInstances().FirstOrDefault(i => !i.IsCurrent);
            if (existing is not null)
            {
                LogDiag("[SingleInstance] redirecting activation to existing instance");
                try
                {
                    existing.RedirectActivationToAsync(current.GetActivatedEventArgs())
                        .AsTask().Wait(500);
                }
                catch { /* 重定向失败就退出自身，不破坏已有实例 */ }
                Current.Exit();
                return;
            }

            // 已有实例收到重定向激活（toast 点击 / 重复启动）→ 显示主窗口。
            // 注意：Activated 在非 UI 线程（RPC）触发，必须切回 UI 线程才能操作 XAML 窗口
            current.Activated += (s, e) =>
            {
                try
                {
                    var dq = MainWindow?.DispatcherQueue;
                    if (dq is null)
                    {
                        LogDiag("[SingleInstance] DispatcherQueue not ready");
                        return;
                    }
                    var enqueued = dq.TryEnqueue(() =>
                    {
                        try
                        {
                            LogDiag("[SingleInstance] activation redirected in");
                            HandleActivation(e);
                        }
                        catch (Exception ex)
                        {
                            LogDiag($"[SingleInstance] handle activation failed: {ex}");
                        }
                    });
                    if (!enqueued)
                        LogDiag("[SingleInstance] TryEnqueue failed");
                }
                catch (Exception ex)
                {
                    LogDiag($"[SingleInstance] redirect handler failed: {ex}");
                }
            };

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

            // 3.1 注册消息接收（App 实现 IRecipient<DeviceDiscoveredMessage>，当前为空实现）
            WeakReferenceMessenger.Default.Register(this);

            // 4. 启动网络：UDP 监听 + Kestrel + 周期公告全部常驻（官方客户端同款行为）
            StartUdpOnly();
            EnsureKestrelRunning();

            // 4.5/4.6 非关键数据（传输历史/白黑名单）异步加载：
            // 后台读盘 + 回 UI 线程应用，避免阻塞首窗口显示。
            var historySvc = Services.GetRequiredService<TransferHistoryService>();
            var listSvc = Services.GetRequiredService<IDeviceListService>();
            var uiQueue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
            _ = Task.Run(() =>
            {
                var historyItems = historySvc.ReadFromDisk(); // 后台读盘
                listSvc.Load();                               // 名单是内存 List（锁保护），可后台
                uiQueue.TryEnqueue(() => historySvc.ApplyLoaded(historyItems));
            });

            // 5. 创建并显示主窗口
            MainWindow = Services.GetRequiredService<ShellWindow>();
            MainWindow.Closed += OnWindowClosed;
            MainWindow.Activate();
            LogDiag("OnLaunched: window activated");

            // 6. 托盘常驻：创建成功才启用"关窗隐藏"；失败降级为关窗即退出，绝不阻断启动
            try
            {
                _tray = new TrayIconManager("LocalSend PC（后台接收中）");
                _tray.OpenRequested += ShowMainWindow;
                _tray.ExitRequested += ExitApplication;
                _tray.Create();
                LogDiag("[Tray] tray icon created");

                // 关窗 ≠ 退出：拦截标题栏关闭 → 隐藏到托盘，后台继续接收
                MainWindow.AppWindow.Closing += (s, e) =>
                {
                    e.Cancel = true;
                    _windowHiddenToTray = true;
                    s.Hide();
                    LogDiag("[Tray] window closed by user → hidden to tray (still receiving)");
                    // 首次隐藏时引导用户：应用仍在后台，可从托盘恢复/退出
                    ShowTrayGuideToastOnce();
                };
            }
            catch (Exception ex)
            {
                LogDiag($"[Tray] init failed, fallback to close-to-exit: {ex.Message}");
                _tray?.Dispose();
                _tray = null;
            }

            // Toast 通知改用 WinRT 原生 ToastNotificationManager（MSIX 免 manifest COM 声明），
            // 在 ShowTransferToast 内按需调用；此处无需注册
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
        // 若由容器自建实例，DeviceRegistry 发布的消息 App 将收不到
        services.AddSingleton<IMessenger>(_ => WeakReferenceMessenger.Default);
        services.AddSingleton<IDeviceInfoBuilder, DeviceInfoBuilder>();
        services.AddSingleton<IFileSaver, FileSaver>();
        services.AddSingleton<IReceiveSessionManager, ReceiveSessionManager>();
        services.AddSingleton<IDeviceRegistry, DeviceRegistry>();
        services.AddSingleton<ISendSessionManager, SendSessionManager>();
        services.AddSingleton<TransferHistoryService>();
        services.AddSingleton<IDeviceListService, DeviceListService>();

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
        services.AddSingleton<DeviceListViewModel>();
        services.AddSingleton<ShellWindow>();
    }

    /// <summary>网络身份签名：只有这些设置变化才需要重启网络（含 HTTPS 开关 → 换监听协议/端口）。</summary>
    private static string _lastNetSig = string.Empty;

    private static string NetSig(AppSettings s)
        => $"{s.Alias}|{s.Port}|{s.Https}|{s.Fingerprint}|{s.MulticastGroup}";

    /// <summary>启动 UDP 多播被动监听（Kestrel + 周期公告由 EnsureKestrelRunning 常驻启动）。</summary>
    private static void StartUdpOnly()
    {
        try
        {
            _multicast ??= Services.GetRequiredService<MulticastDiscoveryService>();
            if (!_multicast.IsRunning)
            {
                _multicast.Start();
                LogDiag("Multicast UDP listener started (Kestrel always-on)");
            }
            _lastNetSig = NetSig(Services.GetRequiredService<ISettingsService>().Current);
        }
        catch (Exception ex)
        {
            LogDiag($"Multicast start failed: {ex}");
        }
    }

    /// <summary>
    /// 幂等启动 Kestrel HTTP server + 周期 UDP 公告（应用启动时调用，之后常驻）。
    /// 用户手动刷新、设置变更也会调用（幂等，已在运行则快速返回）。
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
                LogDiag($"HTTP server started on port {_http.RunningPort} (always-on)");
            }

            // Kestrel 就绪后才能发公告——否则其他设备收到公告后发 prepare-upload 会连不上
            _multicast ??= Services.GetRequiredService<MulticastDiscoveryService>();
            _ = _multicast.AnnounceOnceAsync();
            _multicast.StartPeriodicAnnounce(TimeSpan.FromSeconds(3));

            _kestrelStarted = true;
            LogDiag("Kestrel + periodic announce activated");
        }
    }

    /// <summary>DeviceDiscoveredMessage 处理（刻意空实现）。
    /// 绝不回播公告：常驻 3s 周期公告已保证对方在一个周期内看到本机；
    /// 回播会形成 公告→对方 register→再公告 的乒乓风暴，打满 UI 线程导致卡死、
    /// 手机被洪流淹没而看不到设备（2026-09-03 定稿删除）。</summary>
    public void Receive(DeviceDiscoveredMessage message)
    {
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
            // 防止无限增长：超过 1MB 直接清空重新开始（诊断日志可丢）
            var info = new System.IO.FileInfo(logPath);
            if (info.Exists && info.Length > 1024 * 1024)
                info.Delete();
            System.IO.File.AppendAllText(logPath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
        }
        catch { /* 诊断日志写盘失败不影响主流程 */ }
    }

    private static async void OnSettingsChanged(object? sender, AppSettings e)
    {
        // 只有网络身份（别名/端口/指纹/多播组）变化才重启网络；
        // 主题/下载目录/开机自启等变更直接跳过，避免无谓的 socket 抖动
        var sig = NetSig(e);
        if (sig == _lastNetSig)
        {
            LogDiag("[Settings] non-network change, skip network restart");
            return;
        }
        LogDiag($"[Settings] network identity changed, restarting network");

        // 设置变更 → 先全停再重启
        var wasRunning = _kestrelStarted;
        try
        {
            _multicast?.Stop();
            if (_http is not null) await _http.StopAsync();
            _kestrelStarted = false;
        }
        catch { /* ignore */ }

        // 重启 UDP 被动监听（端口可能已变）
        StartUdpOnly();

        // 之前 Kestrel 在跑 → 立即拉起并补发公告，
        // 让局域网设备马上用新别名/端口看到我们
        if (wasRunning)
            EnsureKestrelRunning();
    }

    /// <summary>托盘「打开」/左键点击：显示并激活主窗口。</summary>
    private static void ShowMainWindow()
    {
        if (!TryGetMainWindow(out var window)) return;
        _windowHiddenToTray = false;
        window.AppWindow.Show();
        window.Activate();

        // 窗口恢复可见 → 若隐藏到托盘期间有挂起的接收请求决策，补弹请求对话框
        try
        {
            Services.GetRequiredService<ReceiveViewModel>().OnWindowBecameVisible();
        }
        catch (Exception ex)
        {
            LogDiag($"[SingleInstance] OnWindowBecameVisible notify failed: {ex.Message}");
        }
    }

    /// <summary>托盘「退出」：清理资源后真正退出进程（关窗只是隐藏，不走这里）。</summary>
    private static void ExitApplication()
    {
        try
        {
            LogDiag("[Tray] exit requested, cleaning up");
            _tray?.Dispose();
            _tray = null;
            WeakReferenceMessenger.Default.UnregisterAll(CurrentApp);
            _multicast?.Stop();
            _ = _http?.StopAsync();
        }
        catch { /* 退出清理失败不阻断 */ }
        Current.Exit();
    }

    /// <summary>传输完成 Toast（窗口隐藏到托盘时才弹，前台可见时不打扰）。系统提示音随之播放。
    /// 用 WinRT 原生 ToastNotificationManager：MSIX 打包应用免 manifest COM 声明，稳定可靠。</summary>
    internal static void ShowTransferToast(string title, string body)
    {
        try
        {
            // 主窗口可见（用户正盯着界面）时静默跳过，避免干扰
            if (MainWindow?.AppWindow.IsVisible == true) return;
            var xml = ToastNotificationManager.GetTemplateContent(ToastTemplateType.ToastText02);
            var texts = xml.GetElementsByTagName("text");
            texts[0].AppendChild(xml.CreateTextNode(title));
            texts[1].AppendChild(xml.CreateTextNode(body));
            ToastNotificationManager.CreateToastNotifier().Show(new ToastNotification(xml));
        }
        catch (Exception ex)
        {
            LogDiag($"[Toast] failed: {ex.Message}");
        }
    }

    /// <summary>主窗口是否对用户可见：隐藏到托盘(标志) 或最小化(Presenter) 均视为不可见，
    /// 此时接收请求改走托盘 toast 决策而非弹 ContentDialog。尚未创建按可见处理。
    /// 用应用自身标志判断"隐藏"（AppWindow.IsVisible 在 Hide() 后仍可能返回 true）。</summary>
    internal static bool IsMainWindowVisible
    {
        get
        {
            try
            {
                if (MainWindow is null) return true;
                if (_windowHiddenToTray) return false;
                if (MainWindow.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter op
                    && op.State == Microsoft.UI.Windowing.OverlappedPresenterState.Minimized)
                    return false;
                return true;
            }
            catch
            {
                return true;
            }
        }
    }

    /// <summary>接收请求动作 toast：带「打开处理 / 全部接收 / 拒绝」按钮。
    /// arguments 编码为 request|action|sessionId，由激活回调 HandleRequestActivation 解析执行。
    /// 仅由 ReceiveViewModel 在窗口隐藏时调用（隐藏时 ContentDialog 用户看不见）。</summary>
    internal static void ShowTransferRequestToast(string title, string body, string sessionId)
    {
        try
        {
            var t = System.Security.SecurityElement.Escape(title ?? string.Empty);
            var b = System.Security.SecurityElement.Escape(body ?? string.Empty);
            var sid = System.Security.SecurityElement.Escape(sessionId ?? string.Empty);
            var xml = $"""
                <toast launch="request|open|{sid}" activationType="foreground">
                  <visual><binding template="ToastGeneric">
                    <text>{t}</text>
                    <text>{b}</text>
                  </binding></visual>
                  <actions>
                    <action content="打开处理" activationType="foreground" arguments="request|open|{sid}"/>
                    <action content="全部接收" activationType="foreground" arguments="request|accept|{sid}"/>
                    <action content="拒绝" activationType="foreground" arguments="request|decline|{sid}"/>
                  </actions>
                </toast>
                """;
            var doc = new Windows.Data.Xml.Dom.XmlDocument();
            doc.LoadXml(xml);
            ToastNotificationManager.CreateToastNotifier().Show(new ToastNotification(doc));
            var shortSid = string.IsNullOrEmpty(sessionId) ? string.Empty : sessionId[..Math.Min(8, sessionId.Length)];
            LogDiag($"[Toast] request toast shown, sessionId={shortSid}");
        }
        catch (Exception ex)
        {
            LogDiag($"[Toast] request toast failed: {ex.Message}");
        }
    }

    /// <summary>首次关窗到托盘时的引导提示（无"窗口可见则跳过"守卫，确保弹一次）。
    /// 与 ShowTransferToast 不同：后者在前台可见时会静默，本方法用于明确的引导场景。</summary>
    private static void ShowTrayGuideToastOnce()
    {
        if (_trayGuideShown) return;
        _trayGuideShown = true;
        try
        {
            var xml = ToastNotificationManager.GetTemplateContent(ToastTemplateType.ToastText02);
            var texts = xml.GetElementsByTagName("text");
            texts[0].AppendChild(xml.CreateTextNode("已最小化到托盘"));
            texts[1].AppendChild(xml.CreateTextNode("PcDemo 仍在后台接收文件。点右下角托盘图标可重新打开；在托盘图标右键选「退出」才会真正退出。"));
            ToastNotificationManager.CreateToastNotifier().Show(new ToastNotification(xml));
        }
        catch (Exception ex)
        {
            LogDiag($"[Toast] tray guide failed: {ex.Message}");
        }
    }

    /// <summary>App 被激活（toast 点击 / 重复启动图标）：request| 前缀走传输请求动作，否则显示主窗口。</summary>
    private static void HandleActivation(AppActivationArguments e)
    {
        var arg = GetActivationArguments(e);
        if (arg.StartsWith("request|", StringComparison.Ordinal))
        {
            LogDiag($"[Activation] request action args: {arg}");
            HandleRequestActivation(arg);
            return;
        }
        ShowMainWindow();
    }

    /// <summary>从激活事件中尽力提取参数串（兼容多种 IActivatedEventArgs 形态，含 toast arguments）。</summary>
    private static string GetActivationArguments(AppActivationArguments e)
    {
        try
        {
            if (e.Data is null) return string.Empty;
            if (e.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch)
                return launch.Arguments;
            if (e.Data is Windows.ApplicationModel.Activation.ToastNotificationActivatedEventArgs toast)
                return toast.Argument;
            if (e.Data is Microsoft.UI.Xaml.LaunchActivatedEventArgs xl)
                return xl.Arguments;
            var p = e.Data.GetType().GetProperty("Arguments");
            if (p?.GetValue(e.Data) is string s) return s;
        }
        catch (Exception ex)
        {
            LogDiag($"[Activation] args extract failed: {ex.Message}");
        }
        return string.Empty;
    }

    /// <summary>执行 request|action|sessionId 动作（已切回 UI 线程调度中）。
    /// accept/decline 直接作用在会话上；open 显示窗口并由 OnWindowBecameVisible 补弹请求对话框。</summary>
    private static void HandleRequestActivation(string args)
    {
        try
        {
            var parts = args.Split('|');
            if (parts.Length < 3 || parts[0] != "request") return;
            var action = parts[1];
            var sessionId = parts[2];
            LogDiag($"[Activation] request handled: action={action} sessionId={sessionId[..Math.Min(8, sessionId.Length)]}");
            var vm = Services.GetRequiredService<ReceiveViewModel>();
            switch (action)
            {
                case "accept":
                    vm.AcceptFromNotification(sessionId);
                    break;
                case "decline":
                    vm.DeclineFromNotification(sessionId);
                    break;
                case "open":
                default:
                    ShowMainWindow(); // 内含 OnWindowBecameVisible → 补弹请求对话框
                    break;
            }
        }
        catch (Exception ex)
        {
            LogDiag($"[Activation] request handling failed: {ex}");
        }
    }

    private static async void OnWindowClosed(object sender, WindowEventArgs args)
    {
        try
        {
            WeakReferenceMessenger.Default.UnregisterAll(CurrentApp);
            _multicast?.Stop();
            if (_http is not null) await _http.StopAsync();
        }
        catch { /* ignore */ }
    }

    /// <summary>方便 ReceiveViewModel.RefreshDevicesAsync 等调用，从外部访问 App 单例。</summary>
    private static App CurrentApp => (App)Current;
}
