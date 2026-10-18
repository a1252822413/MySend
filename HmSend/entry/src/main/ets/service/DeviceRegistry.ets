// 设备注册表：维护发现到的设备、在线状态、变更通知。
// 对应 PC 端 Services/DeviceRegistry.cs。
import { DeviceItem, DeviceInfoDto } from '../model/Types';
import { Const } from '../common/Constants';

class DeviceRegistryImpl {
  private devices: Map<string, DeviceItem> = new Map<string, DeviceItem>();
  private listener: (() => void) | null = null;

  /** 订阅变更（界面刷新用），只保留单个订阅者即可满足当前页面结构 */
  setListener(cb: () => void): void {
    this.listener = cb;
  }

  /** 收到公告 / info 响应 / 手工注册时统一走这里 */
  upsert(dto: DeviceInfoDto, ip: string): void {
    if (dto.fingerprint === undefined || dto.fingerprint.length === 0) {
      return;
    }
    const existing = this.devices.get(dto.fingerprint);
    if (existing !== undefined) {
      existing.alias = dto.alias;
      existing.deviceModel = dto.deviceModel;
      existing.deviceType = dto.deviceType;
      existing.port = dto.port;
      existing.protocol = dto.protocol;
      existing.download = dto.download;
      existing.ip = ip;
      existing.lastSeen = Date.now();
    } else {
      const item = new DeviceItem(dto.alias, dto.fingerprint, ip, dto.port);
      item.deviceModel = dto.deviceModel;
      item.deviceType = dto.deviceType;
      item.protocol = dto.protocol;
      item.download = dto.download;
      this.devices.set(dto.fingerprint, item);
    }
    this.notify();
  }

  /** 在线设备列表（按别名排序，便于界面稳定不跳动） */
  list(): DeviceItem[] {
    const all: DeviceItem[] = [];
    this.devices.forEach((v: DeviceItem) => {
      all.push(v);
    });
    const online = all.filter((d: DeviceItem) => d.isOnline(Const.DEVICE_TIMEOUT_MS));
    online.sort((a: DeviceItem, b: DeviceItem) => a.alias.localeCompare(b.alias));
    return online;
  }

  get(fingerprint: string): DeviceItem | undefined {
    return this.devices.get(fingerprint);
  }

  /** 定时清理超时设备（由 DiscoveryService 的心跳调用） */
  purgeOffline(): void {
    let removed = false;
    const stale: string[] = [];
    this.devices.forEach((v: DeviceItem, k: string) => {
      if (!v.isOnline(Const.DEVICE_TIMEOUT_MS)) {
        stale.push(k);
      }
    });
    for (let i = 0; i < stale.length; i++) {
      this.devices.delete(stale[i]);
      removed = true;
    }
    if (removed) {
      this.notify();
    }
  }

  private notify(): void {
    const cb = this.listener;
    if (cb !== null) {
      cb();
    }
  }
}

export const deviceRegistry = new DeviceRegistryImpl();
