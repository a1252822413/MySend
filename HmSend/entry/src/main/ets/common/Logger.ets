// 统一日志出口：方便真机上用 hdc hilog 过滤 tag=KuaiChuan 排查。
import { hilog } from '@kit.PerformanceAnalysisKit';

export class Log {
  private static readonly DOMAIN: number = 0x0A11;
  private static readonly TAG: string = 'KuaiChuan';

  static i(msg: string): void {
    hilog.info(Log.DOMAIN, Log.TAG, '%{public}s', msg);
  }

  static w(msg: string): void {
    hilog.warn(Log.DOMAIN, Log.TAG, '%{public}s', msg);
  }

  static e(msg: string): void {
    hilog.error(Log.DOMAIN, Log.TAG, '%{public}s', msg);
  }
}
