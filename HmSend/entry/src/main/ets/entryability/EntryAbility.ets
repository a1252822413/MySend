import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { settingsService } from '../service/SettingsService';
import { historyService } from '../service/HistoryService';
import { fileReceiver } from '../service/FileReceiver';
import { httpServer } from '../service/HttpServer';
import { discoveryService } from '../service/DiscoveryService';
import { Log } from '../common/Logger';
import { initTheme } from '../common/Theme';
import { backgroundKeeper } from '../service/BackgroundKeeper';
import { shareInbox } from '../service/ShareInbox';
import { notifyService } from '../service/NotifyService';
import { AppState } from '../common/AppState';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');

    // 服务初始化顺序：设置 -> 文件接收器 -> HTTP(S) 服务 -> 组播发现
    // 注意：这一步必须在 UI 之前，否则首页读不到本机信息。
    settingsService.init(this.context);
    // 主题先灌进 AppStorage，UI 起来时直接读得到（避免首帧闪烁）
    initTheme(settingsService.value.themeMode);
    fileReceiver.init(this.context);
    // 异步恢复上次授权的接收目录（持久化授权必须每次启动激活）
    fileReceiver.restoreAuthorizedDir();
    historyService.init(this.context);
    notifyService.init(this.context);

    httpServer.start().then(() => {
      Log.i('接收服务启动完成');
    });
    discoveryService.start().then(() => {
      Log.i('设备发现启动完成');
    });

    // 若本次是从系统分享面板拉起的，把文件导入后交给发送页
    shareInbox.intake(want, this.context);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    // 应用已在运行时从别的应用分享进来
    shareInbox.intake(want, this.context);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    discoveryService.stop();
    httpServer.stop();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    AppState.foreground = true;
    // 回到前台就不再需要长时任务，及时释放（合规要求）
    backgroundKeeper.stop(this.context);
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    AppState.foreground = false;
    // 切到后台申请长时任务，保证仍能接收文件
    backgroundKeeper.start(this.context);
  }
}
