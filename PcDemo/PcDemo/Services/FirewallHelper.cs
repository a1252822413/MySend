// 防火墙辅助：检测并提示用户授权添加 netsh 入站规则 UDP/TCP 53317。
// Unpackaged 模式无 package identity，不会自动获得防火墙规则，必须手动添加。
// 调用 netsh 需要管理员权限；本类封装检测与添加，由 UI 在用户点击"修复防火墙"按钮时调用。
using System.Diagnostics;

namespace PcDemo.Services;

public static class FirewallHelper
{
    private const string UdpRuleName = "PcDemo-UDP-53317";
    private const string TcpRuleName = "PcDemo-TCP-53317";

    public static bool IsRulePresent(string ruleName)
    {
        try
        {
            var psi = new ProcessStartInfo("netsh", $"advfirewall firewall show rule name=\"{ruleName}\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
            };
            using var p = Process.Start(psi);
            if (p is null) return false;
            p.WaitForExit(3000);
            var output = p.StandardOutput.ReadToEnd();
            return !output.Contains("No rules match");
        }
        catch { return false; }
    }

    public static bool AreRulesPresent()
        => IsRulePresent(UdpRuleName) || IsRulePresent(TcpRuleName);

    /// <summary>以管理员权限运行 netsh 添加 UDP/TCP 53317 入站规则。会触发 UAC。</summary>
    public static void AddRules(int port)
    {
        AddRule(UdpRuleName, "UDP", port);
        AddRule(TcpRuleName, "TCP", port);
    }

    private static void AddRule(string ruleName, string protocol, int port)
    {
        var args = $"advfirewall firewall add rule name=\"{ruleName}\" dir=in action=allow protocol={protocol} localport={port}";
        var psi = new ProcessStartInfo("netsh", args)
        {
            Verb = "runas",          // 触发 UAC
            UseShellExecute = true,  // Verb=runas 必须配 UseShellExecute=true
        };
        try { Process.Start(psi); } catch { /* 用户取消 UAC 时忽略 */ }
    }
}
