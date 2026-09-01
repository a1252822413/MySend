// SendSessionFinishedMessage：发送端会话结束通知（ViewModel 用它刷新 UI 状态 + 显示结果提示）。
using PcDemo.Models;

namespace PcDemo.Messages;

public record SendSessionFinishedMessage(SendSession Session);
