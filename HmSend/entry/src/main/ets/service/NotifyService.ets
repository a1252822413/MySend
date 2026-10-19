// 本地通知：接收完成时提醒用户（应用在后台/锁屏时尤其需要）。
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';

class NotifyServiceImpl {
  private ctx: common.UIAbilityContext | null = null;
  private askedEnable: boolean = false;

  init(ctx: common.UIAbilityContext): void {
    this.ctx = ctx;
  }

  /** 发一条普通文本通知；失败只告警，不影响主流程 */
  async notify(id: number, title: string, text: string): Promise<void> {
    const request: notificationManager.NotificationRequest = {
      id: id,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text
        }
      }
    };
    try {
      await notificationManager.publish(request);
      Log.i(`通知已发送：${title}`);
    } catch (e) {
      const err = e as BusinessError;
      Log.w(`通知发送失败 ${err.code} ${err.message}`);
      // 1600004 = 用户未授权通知；只请求一次，避免反复弹窗
      if (err.code === 1600004 && !this.askedEnable) {
        this.askedEnable = true;
        await this.requestEnable();
      }
    }
  }

  private async requestEnable(): Promise<void> {
    const ctx = this.ctx;
    if (ctx === null) {
      return;
    }
    try {
      await notificationManager.requestEnableNotification(ctx);
      Log.i('已请求通知授权');
    } catch (e) {
      Log.w(`请求通知授权失败: ${String(e)}`);
    }
  }
}

export const notifyService = new NotifyServiceImpl();
