// 后台常驻：进入后台时申请 dataTransfer 类型的长时任务，保证锁屏/切走后仍能接收文件。
//
// 合规要点（华为 Background Tasks Kit 规范）：
//   · 通知栏必须始终可见，文案不能改
//   · 业务结束必须 stopBackgroundRunning，不能为了保活而常驻
//   · 因此这里只在 onBackground 时启动、onForeground 时停止
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';

class BackgroundKeeperImpl {
  private running: boolean = false;

  isRunning(): boolean {
    return this.running;
  }

  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.running) {
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent
      );
      this.running = true;
      Log.i('已进入后台长时任务（dataTransfer）');
    } catch (e) {
      const err = e as BusinessError;
      Log.e(`申请长时任务失败: code=${err.code} msg=${err.message}`);
    }
  }

  async stop(context: common.UIAbilityContext): Promise<void> {
    if (!this.running) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      Log.i('已退出后台长时任务');
    } catch (e) {
      const err = e as BusinessError;
      Log.w(`退出长时任务失败: code=${err.code} msg=${err.message}`);
    }
    this.running = false;
  }
}

export const backgroundKeeper = new BackgroundKeeperImpl();
