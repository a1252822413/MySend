// SpeedCalculator：基于 EMA 的传输速度采样（发送/接收两端共用逻辑）。
// 每 ≥0.5s 采一个样：瞬时速度 = Δbytes/Δt（回退 clamp 0），平滑 = 0.7 旧 + 0.3 新。
using System.Diagnostics;

namespace PcDemo.Services;

internal sealed class SpeedCalculator
{
    private long _lastTicks;
    private long _lastBytes;
    private double _ema;

    /// <summary>输入当前累计字节与总大小，返回 (速度 bytes/s, 剩余秒)。</summary>
    public (long Speed, double Eta) Sample(long currentBytes, long totalBytes)
    {
        var now = Stopwatch.GetTimestamp();
        var elapsed = _lastTicks == 0 ? 0 : (now - _lastTicks) / (double)Stopwatch.Frequency;

        if (elapsed >= 0.5)
        {
            var inst = Math.Max(0, (currentBytes - _lastBytes) / elapsed);
            _ema = _ema == 0 ? inst : _ema * 0.7 + inst * 0.3;
            _lastBytes = currentBytes;
            _lastTicks = now;
        }
        else if (_lastTicks == 0)
        {
            _lastBytes = currentBytes;
            _lastTicks = now;
        }

        var remaining = Math.Max(0, totalBytes - currentBytes);
        return ((long)_ema, _ema > 1024 ? remaining / _ema : 0);
    }
}
