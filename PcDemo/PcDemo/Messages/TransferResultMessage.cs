// 传输结果消息：驱动顶部悬浮提醒的 4 个标准态。
// 设计稿 design/unified v1.2 §2：接收/发送 × 成功/失败，全部走同一个顶部悬浮层，
// 不再在页面里塞「已接收」卡片，也不再用页面居中的通用 Toast 表达传输结果。
namespace PcDemo.Messages;

public enum TransferResultKind
{
    ReceiveSuccess,
    ReceiveFailure,
    SendSuccess,
    SendFailure,
}

public sealed class TransferResultMessage
{
    public TransferResultKind Kind { get; init; }

    /// <summary>主标题，例如「已接收 3 个文件」。</summary>
    public string Title { get; init; } = string.Empty;

    /// <summary>副文本，例如「18.6 MB · 保存到 下载\快传」。</summary>
    public string Detail { get; init; } = string.Empty;

    public string PrimaryActionText { get; init; } = string.Empty;
    public string SecondaryActionText { get; init; } = string.Empty;

    /// <summary>点击主动作时执行；为空则只收起提醒。</summary>
    public Action? PrimaryAction { get; init; }
    public Action? SecondaryAction { get; init; }

    /// <summary>停留时长（毫秒）。默认：成功 4000 / 失败 8000，悬停暂停。</summary>
    public int DurationMs { get; init; }
}
