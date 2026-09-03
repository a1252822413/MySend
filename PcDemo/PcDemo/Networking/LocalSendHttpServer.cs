// Kestrel 自宿主 HTTP 服务器：注册 5 个 v2 端点，监听 0.0.0.0:port。
// 通过把主 DI 容器中的 singleton 服务实例转发到 WebApplication 的容器，
// 确保 endpoints 与 UI 共享同一份 SettingsService / SessionManager / DeviceRegistry。
using System.Net;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using PcDemo.Networking.Endpoints;
using PcDemo.Services;

namespace PcDemo.Networking;

public sealed class LocalSendHttpServer : IAsyncDisposable
{
    private readonly IServiceProvider _rootProvider;
    private readonly ISettingsService _settings;
    private readonly object _lock = new();

    private WebApplication? _app;
    private int _runningPort;

    public LocalSendHttpServer(IServiceProvider rootProvider, ISettingsService settings)
    {
        _rootProvider = rootProvider;
        _settings = settings;
    }

    public bool IsRunning { get { lock (_lock) return _app is not null; } }
    public int RunningPort => _runningPort;

    public void Start()
    {
        lock (_lock)
        {
            if (_app is not null) return;

            var port = _settings.Current.Port;
            _runningPort = port;

            var builder = WebApplication.CreateBuilder();
            builder.WebHost.ConfigureKestrel(o =>
            {
                o.Listen(IPAddress.Any, port);
                // LocalSend 协议不限文件大小，解除 Kestrel 默认 30MB 请求体限制
                o.Limits.MaxRequestBodySize = null;
                // 大文件低速传输不应被 Kestrel 断连（默认 240 bytes/sec 触发断开）
                o.Limits.MinRequestBodyDataRate = null;
            });

            // 把主容器中的 singleton 实例转发给 Kestrel 的 DI 容器
            ForwardSingleton<ISettingsService>(builder);
            ForwardSingleton<IDeviceInfoBuilder>(builder);
            ForwardSingleton<IReceiveSessionManager>(builder);
            ForwardSingleton<IDeviceRegistry>(builder);
            ForwardSingleton<IFileSaver>(builder);
            ForwardSingleton<IDeviceListService>(builder);

            var app = builder.Build();

            app.MapGet(InfoEndpoint.Path,
                (IDeviceInfoBuilder info) => InfoEndpoint.Handle(info));
            app.MapPost(RegisterEndpoint.Path,
                (HttpContext ctx, IDeviceInfoBuilder info, IDeviceRegistry devices) => RegisterEndpoint.Handle(ctx, info, devices));
            app.MapPost(PrepareUploadEndpoint.Path,
                (HttpContext ctx, IReceiveSessionManager sessions, ISettingsService settings, IDeviceListService deviceLists) =>
                    PrepareUploadEndpoint.Handle(ctx, sessions, settings, deviceLists));
            app.MapPost(UploadEndpoint.Path,
                (HttpContext ctx, IReceiveSessionManager sessions) => UploadEndpoint.Handle(ctx, sessions));
            app.MapPost(CancelEndpoint.Path,
                (HttpContext ctx, IReceiveSessionManager sessions) => CancelEndpoint.Handle(ctx, sessions));

            _app = app;
            _ = app.RunAsync(); // 后台运行；停止用 StopAsync
        }
    }

    public async Task StopAsync()
    {
        WebApplication? app;
        lock (_lock)
        {
            if (_app is null) return;
            app = _app;
            _app = null;
        }
        try
        {
            await app.StopAsync();
        }
        finally
        {
            await app.DisposeAsync();
        }
    }

    private void ForwardSingleton<T>(WebApplicationBuilder builder) where T : class
    {
        var instance = _rootProvider.GetService(typeof(T));
        if (instance is T t)
        {
            builder.Services.AddSingleton(t);
        }
    }

    public async ValueTask DisposeAsync() => await StopAsync();
}
