// 防火墙辅助：检测并添加 netsh 入站放行规则（UDP/TCP 监听端口）。
// Unpackaged 模式无 package identity，不会自动获得防火墙规则，必须手动添加；
// MSIX（runFullTrust）下 Windows 防火墙也可能拦截入站 —— 手机收不到公告/连不上本机的最常见首因。
// 规则名按端口动态生成：PcDemo-UDP-&lt;port&gt; / PcDemo-TCP-&lt;port&gt;（默认 53317，与旧命名一致）。
// 添加规则调用 netsh 需要管理员权限（触发 UAC），由 UI 在用户点击「添加放行规则」时调用。
using System.Diagnostics;

namespace PcDemo.Services;

/// <summary>防火墙入站状态检测结果。</summary>
public enum FirewallState
{
    /// <summary>存在放行规则（UDP 或 TCP 任一）。</summary>
    Allowed,

    /// <summary>明确没有匹配规则。</summary>
    NotAllowed,

    /// <summary>无法判定（netsh 输出异常/需要权限等）。</summary>
    Unknown,
}

public static class FirewallHelper
{
    private static string UdpRuleName(int port) => $"PcDemo-UDP-{port}";
    private static string TcpRuleName(int port) => $"PcDemo-TCP-{port}";

    /// <summary>检测入站放行状态：UDP 多播端口（53317）与 TCP 服务端口
    /// （HTTP=端口；HTTPS-only=端口+1）任一放行即视为可用。</summary>
    public static FirewallState CheckState(int udpPort, int tcpPort)
    {
        var udp = CheckRule(UdpRuleName(udpPort));
        var tcp = CheckRule(TcpRuleName(tcpPort));
        if (udp == FirewallState.Allowed || tcp == FirewallState.Allowed) return FirewallState.Allowed;
        if (udp == FirewallState.NotAllowed && tcp == FirewallState.NotAllowed) return FirewallState.NotAllowed;
        return FirewallState.Unknown;
    }

    private static FirewallState CheckRule(string ruleName)
    {
        try
        {
            var psi = new ProcessStartInfo("netsh", $"advfirewall firewall show rule name=\"{ruleName}\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            using var p = Process.Start(psi);
            if (p is null) return FirewallState.Unknown;
            if (!p.WaitForExit(3000))
            {
                try { p.Kill(); } catch { }
                return FirewallState.Unknown;
            }
            // 用退出码判断（不解析本地化文本）：有匹配规则 exit=0，无匹配 exit≠0。
            // 查询规则普通权限即可运行（仅添加才需管理员），故非 0 基本可判定"未放行"。
            return p.ExitCode == 0 ? FirewallState.Allowed : FirewallState.NotAllowed;
        }
        catch
        {
            return FirewallState.Unknown;
        }
    }

    /// <summary>添加入站放行规则：UDP(多播端口) + TCP(实际服务端口，HTTPS 时=端口+1)。
    /// 触发 UAC；返回是否已授权执行（用户点了"是"）。</summary>
    public static bool AddRules(int udpPort, int tcpPort)
    {
        var udp = RunAdd(UdpRuleName(udpPort), "UDP", udpPort);
        var tcp = RunAdd(TcpRuleName(tcpPort), "TCP", tcpPort);
        return udp || tcp;
    }

    private static bool RunAdd(string ruleName, string protocol, int port)
    {
        var args = $"advfirewall firewall add rule name=\"{ruleName}\" dir=in action=allow protocol={protocol} localport={port}";
        var psi = new ProcessStartInfo("netsh", args)
        {
            Verb = "runas",          // 触发 UAC
            UseShellExecute = true,  // Verb=runas 必须配 UseShellExecute=true
        };
        try
        {
            // Start 在用户对 UAC 做决定前阻塞；拒绝时抛异常 → 返回 false
            using var p = Process.Start(psi);
            if (p is null) return false;
            if (!p.WaitForExit(5000))
            {
                try { p.Kill(); } catch { }
            }
            return true;
        }
        catch
        {
            return false; // 用户取消 UAC / 无管理员账户
        }
    }
}
