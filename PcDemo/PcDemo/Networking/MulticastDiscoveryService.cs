// UDP 多播发现服务：对应 packages/core/src/multicast/mod.rs
// - 绑定 UdpClient 到 0.0.0.0:53317，JoinMulticastGroup(224.0.0.167)，TTL=1
// - 接收循环解析 MulticastMessageV2，过滤自身 fingerprint，发 DeviceDiscoveredMessage
// - AnnounceOnce 重复 3 次：100ms / 500ms / 2000ms 后
using System.Net;
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
    private CancellationTokenSource? _cts;
    private Task? _receiveTask;
    private PeriodicTimer? _periodicAnnounceTimer;
    private Task? _periodicAnnounceTask;

    /// <summary>是否正在刷新（发 UDP 公告让其他设备回播）。两个 VM 订阅这个属性镜像到 UI。</summary>
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
        _udp.JoinMulticastGroup(group);
        // TTL=1：仅本地子网
        _udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 1);

        _cts = new CancellationTokenSource();
        _receiveTask = Task.Run(() => ReceiveLoopAsync(_cts.Token));
    }

    public void Stop()
    {
        StopPeriodicAnnounce();
        try { _cts?.Cancel(); } catch { }
        try { _udp?.Dispose(); } catch { }
        _udp = null;
        _cts?.Dispose();
        _cts = null;
        _receiveTask = null;
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
                    try { await AnnounceOnceAsync(); }
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
        var buffer = new byte[ReceiveBufferSize];
        var udp = _udp!;
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
            catch { continue; }
            if (msg is null) continue;

            // 过滤自身回环（loopback 启用，自己发的也会收到）
            if (string.Equals(msg.Fingerprint, _settings.Current.Fingerprint, StringComparison.Ordinal))
                continue;

            // 统一入口：UDP 被动发现 → DeviceRegistry.Upsert → 内部发 DeviceDiscoveredMessage
            // 这样 DeviceRegistry 始终是设备真源，RemoveStaleSince 等才能正确工作
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
    }

    /// <summary>发送一轮公告：重复 3 次（100/500/2000ms 后），每次发一个数据报到组:port。</summary>
    public async Task AnnounceOnceAsync(CancellationToken ct = default)
    {
        var s = _settings.Current;
        var group = IPAddress.Parse(s.MulticastGroup);
        var target = new IPEndPoint(group, s.Port);
        var payload = JsonSerializer.SerializeToUtf8Bytes(_info.BuildAnnouncedMessage(), JsonOptions.Default);
        var udp = _udp;

        foreach (var delay in AnnounceDelays)
        {
            if (ct.IsCancellationRequested) return;
            try { await Task.Delay(delay, ct); }
            catch (OperationCanceledException) { return; }
            if (udp is null) return;
            try { await udp.SendAsync(payload, target); }
            catch { /* 单个接口失败不影响其余 */ }
        }
    }

    /// <summary>
    /// 公共刷新入口：
    /// 1. 记录 cutoff 时间
    /// 2. EnsureKestrelRunning（接收端才能处理后续 register/prepare-upload）
    ///    + AnnounceOnce（三次 UDP 公告让局域网其他设备回播）
    /// 3. 等 3 秒让在线设备回播更新 LastSeenUtcTicks
    /// 4. 清理：LastSeen 早于 cutoff 的设备 → Remove + DeviceTimedOutMessage
    ///    在线设备因回播了 → LastSeen 新于 cutoff → 保留
    ///    离线设备没回播 → LastSeen 旧于 cutoff → 移除
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

            // 等 3 秒让在线设备回播（三次公告最晚在 2.0s 发完，留 1s 给网络传输）
            try { await Task.Delay(3000, ct); } catch (OperationCanceledException) { /* 刷新被取消也继续清理 */ }

            // 主动清除没回播的设备——在线设备因回播了 LastSeen 新于 cutoff，离线设备 LastSeen 旧于 cutoff
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
