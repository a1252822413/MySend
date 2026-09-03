// 轻量页面内居中 Toast 消息：任何地方调用 _messenger.Send 后，
// 拥有焦点的 Page（通常是接收/发送页）会弹出一个居中的小尺寸卡片，
// 淡入 → 显示 ~1.7s → 淡出，全程不阻塞鼠标操作。
namespace PcDemo.Messages;

public enum ToastKind
{
    Success, // 绿色✓
    Error,   // 红色✗
    Info,    // 蓝色ℹ
    Warning, // 黄色⚠
}

public sealed class ShowToastMessage
{
    public string Message { get; init; } = string.Empty;
    public ToastKind Kind { get; init; } = ToastKind.Success;
    /// <summary>显示时长（毫秒），默认 1700（不含淡入淡出过渡）。</summary>
    public int DurationMs { get; init; } = 1700;
}
