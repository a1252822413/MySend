// UDP 多播发现服务：对应 packages/core/src/multicast/mod.rs
// - 接收：绑定 0.0.0.0:53317，JoinMulticastGroup(224.0.0.167)
// - 发送：为每个可多播的 IPv4 接口建独立 socket 逐接口发送
//   （Windows 多网卡下单 socket 多播可能走错默认接口，导致手机收不到公告）
// - AnnounceOnce 重复 3 次：100ms / 500ms / 2000ms 后（启动/手动刷新）；周期公告为单发
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using CommunityToolkit.Mvvm.Messaging;
using PcDemo.Helpers;
using PcDemo.Messages;
using PcDemo.Models.Dto;
using PcDemo.Services;

namespace PcDemo.Networking;

public sealed class MulticastDiscoveryService : IDisposable
{
    // 公告三次延迟（毫秒），与 localsend ANNOUNCE_DELAYS 一致
    private static readonly int[] AnnounceDelays = { 100, 500, 2000 };
    private const int ReceiveBufferSize = 65536;

    private readonly ISettingsService _settings;
    private readonly IDeviceInfoBuilder _info;
    private readonly IMessenger _messenger;
    private readonly IDeviceRegistry _registry;
    private readonly object _refreshGate = new();

    private UdpClient? _udp;
    private readonly List<UdpClient> _sendSockets = new();
    private CancellationTokenSource? _cts;
    private Task? _receiveTask;
    private PeriodicTimer? _periodicAnnounceTimer;
    private Task? _periodicAnnounceTask;

    // ReceiveLoop 限频日志：自身回环每包多次，per-packet 记录会刷爆 1MB 日志
    private DateTime _lastSelfLoopLog = DateTime.MinValue;
    private DateTime _lastParseFailLog = DateTime.MinValue;
    // 设备公告日志同样限频：手机周期 3s/台 × 多台设备会持续冲掉 diag.log 里的错误证据
    private DateTime _lastDeviceAnnounceLog = DateTime.MinValue;

    /// <summary>是否正在刷新。两个 VM 订阅这个属性镜像到 UI。</summary>
    public bool IsRefreshing { get; private set; }

    /// <summary>IsRefreshing 变化时通知订阅者（两个 VM 镜像到自己的可绑定属性）。</summary>
    public event EventHandler<bool>? IsRefreshingChanged;

    public MulticastDiscoveryService(ISettingsService settings, IDeviceInfoBuilder info, IMessenger messenger, IDeviceRegistry registry)
    {
        _settings = settings;
        _info = info;
        _messenger = messenger;
        _registry = registry;
    }

    public bool IsRunning => _udp is not null && _cts is not null && _receiveTask is not null;

    public void Start()
    {
        if (IsRunning) return;
        var s = _settings.Current;
        var group = IPAddress.Parse(s.MulticastGroup);
        var port = s.Port;

        _udp = new UdpClient();
        _udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _udp.Client.Bind(new IPEndPoint(IPAddress.Any, port));

        // 接收侧也必须按接口加入多播组：Windows 多网卡（WLAN + Hyper-V/WSL 虚拟网卡）下，
        // 不指定接口的 JoinMulticastGroup 会绑定到默认路由接口（很可能是虚拟网卡），
        // 导致手机发的公告 PC 收不到。官方 LocalSend 同样逐接口加入。
        var joinedIfaces = 0;
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            if (!ni.SupportsMulticast) continue;

            var props = ni.GetIPProperties();
            var ipv4 = props.UnicastAddresses
                .FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork)?.Address;
            if (ipv4 is null) continue;

            try
            {
                _udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, ipv4);
                _udp.JoinMulticastGroup(group, ipv4);
                joinedIfaces++;
                App.LogDiag($"[Multicast] 接收组加入 {ipv4} ({ni.Name})");
            }
            catch (Exception ex)
            {
                App.LogDiag($"[Multicast] 接收组加入 {ipv4} 失败: {ex.Message}");
            }
        }
        if (joinedIfaces == 0)
        {
            _udp.JoinMulticastGroup(group);
            App.LogDiag("[Multicast] 无可用接口逐个加入，回退默认接口（可能收不到公告）");
        }

        // TTL=1：仅本地子网
        _udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 1);

        _cts = new CancellationTokenSource();
        _receiveTask = Task.Run(() => ReceiveLoopAsync(_cts.Token));
        CreateSendSockets();
    }

    public void Stop()
    {
        StopPeriodicAnnounce();
        try { _cts?.Cancel(); } catch { }
        try { _udp?.Dispose(); } catch { }
        _udp = null;
        DisposeSendSockets();
        _cts?.Dispose();
        _cts = null;
        _receiveTask = null;
    }

    /// <summary>
    /// 多网卡支持：为每个可多播的 IPv4 接口建一个发送 socket（绑定接口地址 + MulticastInterface）。
    /// Windows 多网卡（WiFi + 以太网 + Hyper-V/WSL 虚拟网卡）下，单 socket 多播可能走错默认接口，
    /// 导致手机收不到本机公告。官方 LocalSend 同样按接口逐个发送。
    /// </summary>
    private void CreateSendSockets()
    {
        DisposeSendSockets();
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                if (!ni.SupportsMulticast) continue;

                var props = ni.GetIPProperties();
                var ipv4 = props.UnicastAddresses
                    .FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork)?.Address;
                var index = props.GetIPv4Properties()?.Index;
                if (ipv4 is null || index is null) continue;

                try
                {
                    var send = new UdpClient();
                    send.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                    send.Client.Bind(new IPEndPoint(ipv4, 0));
                    // MulticastInterface 需要 network byte order 的接口索引
                    send.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface,
                        IPAddress.HostToNetworkOrder(index.Value));
                    send.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 1);
                    _sendSockets.Add(send);
                    App.LogDiag($"[Multicast] send socket bound to {ipv4} ({ni.Name})");
                }
                catch (Exception ex)
                {
                    App.LogDiag($"[Multicast] bind {ipv4} failed: {ex.Message}");
                }
            }
        }
        catch (Exception ex)
        {
            App.LogDiag($"[Multicast] CreateSendSockets failed: {ex.Message}");
        }

        if (_sendSockets.Count == 0)
            App.LogDiag("[Multicast] no per-interface socket, fallback to default routing socket");
    }

    private void DisposeSendSockets()
    {
        foreach (var s in _sendSockets)
        {
            try { s.Dispose(); } catch { }
        }
        _sendSockets.Clear();
    }

    /// <summary>向所有多播接口各发一条公告；全部失败时重建发送 socket（应对 WiFi 切换等接口变化）。</summary>
    private async Task SendAnnounceToAllAsync()
    {
        var s = _settings.Current;
        var target = new IPEndPoint(IPAddress.Parse(s.MulticastGroup), s.Port);
        var payload = JsonSerializer.SerializeToUtf8Bytes(_info.BuildAnnouncedMessage(), JsonOptions.Default);

        var sent = false;
        foreach (var socket in _sendSockets)
        {
            try { await socket.SendAsync(payload, target); sent = true; }
            catch { /* 单个接口失败不影响其余 */ }
        }

        // 无逐接口 socket → 回退默认路由 socket（接收用）
        if (!sent && _sendSockets.Count == 0)
        {
            var udp = _udp;
            if (udp is not null)
            {
                try { await udp.SendAsync(payload, target); sent = true; }
                catch { }
            }
        }

        // 有接口 socket 但全部失败 → 接口列表可能过期（WiFi 切换/断开重连），重建后由下一轮公告生效
        if (!sent && _sendSockets.Count > 0)
            CreateSendSockets();
    }

    /// <summary>
    /// 启动周期自动广播（消除 ReceiveVM/SendVM 各自重复的 DispatcherQueueTimer）。
    /// 内部用 PeriodicTimer 后台线程跑，不占 UI 线程。
    /// </summary>
    public void StartPeriodicAnnounce(TimeSpan interval)
    {
        if (_periodicAnnounceTimer is not null) return;
        _periodicAnnounceTimer = new PeriodicTimer(interval);
        _periodicAnnounceTask = Task.Run(async () =>
        {
            try
            {
                while (await _periodicAnnounceTimer.WaitForNextTickAsync())
                {
                    try { await AnnounceSingleAsync(); }
                    catch { /* 网络抖动忽略 */ }
                }
            }
            catch { /* 定时器被 Dispose */ }
        });
    }

    public void StopPeriodicAnnounce()
    {
        try { _periodicAnnounceTimer?.Dispose(); } catch { }
        _periodicAnnounceTimer = null;
        _periodicAnnounceTask = null;
    }

    private async Task ReceiveLoopAsync(CancellationToken ct)
    {
        var udp = _udp!;
        var myFp = _settings.Current.Fingerprint;
        App.LogDiag("[Multicast] ReceiveLoop 启动");
        while (!ct.IsCancellationRequested && _udp is not null)
        {
            UdpReceiveResult result;
            try
            {
                result = await udp.ReceiveAsync(ct);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch { continue; }

            MulticastMessageV2? msg = null;
            try
            {
                msg = JsonSerializer.Deserialize<MulticastMessageV2>(result.Buffer, JsonOptions.Default);
            }
            catch
            {
                // 收到包但解析失败：诊断用，限频 10s 一次
                if ((DateTime.UtcNow - _lastParseFailLog).TotalSeconds > 10)
                {
                    _lastParseFailLog = DateTime.UtcNow;
                    App.LogDiag($"[Multicast] 收到无法解析的包 from {result.RemoteEndPoint} len={result.Buffer.Length}");
                }
                continue;
            }
            if (msg is null) continue;

            // 过滤自身回环（loopback 启用，自己发的也会收到）
            if (string.Equals(msg.Fingerprint, myFp, StringComparison.Ordinal))
            {
                // 自身回环每周期都会触发，per-packet 记录会刷爆日志，限频 30s 一次（仅作健康检查）
                if ((DateTime.UtcNow - _lastSelfLoopLog).TotalSeconds > 30)
                {
                    _lastSelfLoopLog = DateTime.UtcNow;
                    App.LogDiag($"[Multicast] 收到自身公告回环 fp={(msg.Fingerprint.Length >= 8 ? msg.Fingerprint[..8] : msg.Fingerprint)}（接收链路健康）");
                }
                continue;
            }

            // 非自身公告：限频 30s 记录（接收线程同步写盘 + 防止冲掉错误证据），新设备发现仍由 DeviceDiscoveredMessage 可观测
            if ((DateTime.UtcNow - _lastDeviceAnnounceLog).TotalSeconds > 30)
            {
                _lastDeviceAnnounceLog = DateTime.UtcNow;
                App.LogDiag($"[Multicast] 收到设备公告 alias={msg.Alias} fp={(msg.Fingerprint.Length >= 8 ? msg.Fingerprint[..8] : msg.Fingerprint)} ip={result.RemoteEndPoint.Address} port={msg.Port}");
            }

            // 统一入口：UDP 被动发现 → DeviceRegistry.Upsert → 内部发 DeviceDiscoveredMessage
            _registry.Upsert(
                ip: result.RemoteEndPoint.Address.ToString(),
                alias: msg.Alias,
                deviceModel: msg.DeviceModel,
                deviceType: msg.DeviceType,
                fingerprint: msg.Fingerprint,
                port: msg.Port,
                protocol: msg.Protocol,
                version: msg.Version,
                download: msg.Download);
        }
        App.LogDiag("[Multicast] ReceiveLoop 退出");
    }

    /// <summary>发送一轮公告：重复 3 次（100/500/2000ms 后），每次向所有多播接口各发一个数据报。用于启动/手动刷新。</summary>
    public async Task AnnounceOnceAsync(CancellationToken ct = default)
    {
        foreach (var delay in AnnounceDelays)
        {
            if (ct.IsCancellationRequested) return;
            try { await Task.Delay(delay, ct); }
            catch (OperationCanceledException) { return; }
            if (_udp is null) return;
            await SendAnnounceToAllAsync();
        }
    }

    /// <summary>立即单发一轮公告（周期公告专用），避免 3 连发与 3s 周期重叠放大流量。</summary>
    public async Task AnnounceSingleAsync()
    {
        if (_udp is null) return;
        await SendAnnounceToAllAsync();
    }

    /// <summary>
    /// 公共刷新入口：
    /// 1. 记录 cutoff 时间
    /// 2. EnsureKestrelRunning + AnnounceOnce（发 3 轮 UDP 公告，让局域网设备发现本机）
    /// 3. 等 3 秒让在线设备通过公告/register 更新 LastSeenUtcTicks
    /// 4. 清理：LastSeen 早于 cutoff 的设备移除（离线设备没回公告 → 被清理）
    /// </summary>
    public async Task RefreshAsync(CancellationToken ct = default)
    {
        lock (_refreshGate)
        {
            if (IsRefreshing) return; // 正在刷新中，忽略重复点击
            SetRefreshing(true);
        }
        try
        {
            var cutoff = DateTime.UtcNow;
            App.EnsureKestrelRunning();
            await AnnounceOnceAsync(ct);

            // 等 3 秒让在线设备公告到达（三轮公告最晚 2.0s 发完，留 1s 给网络传输）
            try { await Task.Delay(3000, ct); } catch (OperationCanceledException) { }

            // 清理没回公告的设备
            _registry.RemoveStaleSince(cutoff);
        }
        catch (Exception ex)
        {
            App.LogDiag($"[MulticastDiscovery] Refresh 失败：{ex.Message}");
        }
        finally
        {
            SetRefreshing(false);
        }
    }

    private void SetRefreshing(bool value)
    {
        if (IsRefreshing == value) return;
        IsRefreshing = value;
        IsRefreshingChanged?.Invoke(this, value);
    }

    public void Dispose() => Stop();
}
