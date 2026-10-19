// 子网扫描兜底。
//
// 组播在部分网络（企业 WiFi、AP 隔离、多网段）下会被拦，表现为"一台设备都发现不了"。
// 这时用 GET /info 逐个探测本网段 IP，命中即入表。参考 HandySend 的做法。
//
// 只在用户主动点击时触发（不做定时扫描，避免耗电与骚扰）。
import { connection } from '@kit.NetworkKit';
import { Log } from '../common/Logger';
import { Const } from '../common/Constants';
import { deviceRegistry } from './DeviceRegistry';
import { sendClient } from './SendClient';
import { settingsService } from './SettingsService';
import { DeviceItem, DeviceInfoDto } from '../model/Types';

class SubnetScannerImpl {
  private scanning: boolean = false;

  isScanning(): boolean {
    return this.scanning;
  }

  /** 返回本次新发现的设备数 */
  async scan(onTick?: (done: number, total: number) => void): Promise<number> {
    if (this.scanning) {
      return 0;
    }
    this.scanning = true;
    let found = 0;
    try {
      const localIp = await this.localIpv4();
      if (localIp.length === 0) {
        Log.w('子网扫描：取不到本机 IP');
        return 0;
      }
      const prefix = localIp.substring(0, localIp.lastIndexOf('.'));
      Log.i(`子网扫描开始：${prefix}.1-254`);

      const port = settingsService.value.port;
      const secure = settingsService.value.https;
      const total = 254;
      let done = 0;

      // 每批 16 个并发，兼顾速度与系统 socket 数量限制
      const batchSize = 16;
      for (let start = 1; start <= total; start += batchSize) {
        const tasks: Promise<number>[] = [];
        for (let i = start; i < start + batchSize && i <= total; i++) {
          tasks.push(this.probeOne(`${prefix}.${i}`, port, secure));
        }
        const results = await Promise.all(tasks);
        for (let i = 0; i < results.length; i++) {
          found += results[i];
        }
        done += tasks.length;
        if (onTick !== undefined) {
          onTick(done, total);
        }
        // 给系统一点时间回收上一批的 socket：鸿蒙对并发 fd 数量敏感，
        // 连续高并发探测会导致后续 connect 直接失败（表现为"扫不到设备"）。
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 30);
        });
      }
      Log.i(`子网扫描完成：新发现 ${found} 台`);
    } catch (e) {
      Log.e(`子网扫描异常: ${String(e)}`);
    } finally {
      this.scanning = false;
    }
    return found;
  }

  /** 探测单个 IP，命中返回 1 */
  private async probeOne(ip: string, port: number, secure: boolean): Promise<number> {
    const probe = new DeviceItem('', '', ip, port);
    probe.protocol = secure ? 'https' : 'http';
    try {
      const body = await sendClient.fetchInfo(probe, 1000);
      if (body.length === 0) {
        return 0;
      }
      const dto = JSON.parse(body) as DeviceInfoDto;
      if (dto.fingerprint === undefined || dto.fingerprint.length === 0) {
        return 0;
      }
      // 跳过自己
      if (dto.fingerprint === settingsService.effectiveFingerprint()) {
        return 0;
      }
      deviceRegistry.upsert(dto, ip);
      Log.i(`子网扫描命中：${dto.alias} @ ${ip}`);
      return 1;
    } catch (e) {
      return 0; // 连不上是常态，不记日志
    }
  }

  private async localIpv4(): Promise<string> {
    try {
      const net = await connection.getDefaultNet();
      const props = await connection.getConnectionProperties(net);
      const addrs = props.linkAddresses;
      for (let i = 0; i < addrs.length; i++) {
        const item = addrs[i].address;
        if (item.family === 1 && item.address.length > 0) {
          return item.address;
        }
      }
    } catch (e) {
      Log.w(`子网扫描取 IP 失败: ${String(e)}`);
    }
    return '';
  }
}

export const subnetScanner = new SubnetScannerImpl();
