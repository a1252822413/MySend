// 设备注册表：唯一的数据源 + 唯一的状态机。
//
// 设计要点（三态）：
//   online  最近一次公告 < 15s      → 可发送
//   away    15s ~ 60s 没消息        → 灰显、不可发送，但保留在列表里
//   移除    > 60s                   → 从列表删除
//
// 为什么不是「一超时就删」：多播丢包在 Wi-Fi 上很常见，一删列表就跳；
// 留 45 秒灰显，用户能看到「它刚离开」，也不会因为丢一个包就消失。
//
// 刷新模型：
//   - 公告驱动（有数据就更新 lastSeen、可能从 away 升回 online）
//   - 时间驱动（每 1s 跑一次 tick，只做状态迁移）
//   两者都只调 notify()，UI 通过 AppStorage 的 deviceRev 统一刷新，
//   页面自己不再开定时器、也不再各自过滤。

import { DeviceItem, DeviceInfoDto } from '../model/Types';
import { Const } from '../common/Constants';
import { Log } from '../common/Logger';

export const PRESENCE_ONLINE: string = 'online';
export const PRESENCE_AWAY: string = 'away';

class DeviceRegistryImpl {
  private devices: Map<string, DeviceItem> = new Map<string, DeviceItem>();
  private listeners: Array<() => void> = [];
  private tickId: number = -1;
  private rev: number = 0;

  /** 支持多个订阅者（接收页、发送页、通知逻辑各订各的，互不覆盖） */
  subscribe(cb: () => void): void {
    if (this.listeners.indexOf(cb) < 0) {
      this.listeners.push(cb);
    }
  }

  unsubscribe(cb: () => void): void {
    const i = this.listeners.indexOf(cb);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  /** 兼容旧调用：只保留一个订阅者 */
  setListener(cb: () => void): void {
    this.listeners = [cb];
  }

  private notify(): void {
    this.rev++;
    // 页面用 @StorageProp('deviceRev') + @Watch 刷新，避免各自轮询
    AppStorage.setOrCreate<number>('deviceRev', this.rev);
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }

  /** 收到公告 / info 响应 / 手工注册时统一走这里 */
  upsert(dto: DeviceInfoDto, ip: string): void {
    if (dto.fingerprint === undefined || dto.fingerprint.length === 0) {
      return;
    }
    const hasIp = ip.length > 0;
    const existing = this.devices.get(dto.fingerprint);
    if (existing !== undefined) {
      existing.alias = dto.alias;
      existing.deviceModel = dto.deviceModel;
      existing.deviceType = dto.deviceType;
      existing.port = dto.port;
      existing.protocol = dto.protocol;
      existing.download = dto.download;
      // 只有拿到真实 IP 时才覆盖：prepare-upload 注册进来时没有 IP，
      // 若直接写空串会把组播发现到的好 IP 抹掉，导致列表里出现"不能发送的设备"。
      if (hasIp) {
        existing.ip = ip;
      }
      existing.lastSeen = Date.now();
      if (existing.presence === PRESENCE_AWAY) {
        existing.presence = PRESENCE_ONLINE;
        Log.i(`设备回到在线：${existing.alias}`);
      }
    } else if (!hasIp) {
      // 没有 IP 的设备无法发送，也不该出现在"附近设备"里，直接忽略
      return;
    } else {
      const item = new DeviceItem(dto.alias, dto.fingerprint, ip, dto.port);
      item.deviceModel = dto.deviceModel;
      item.deviceType = dto.deviceType;
      item.protocol = dto.protocol;
      item.download = dto.download;
      item.presence = PRESENCE_ONLINE;
      this.devices.set(dto.fingerprint, item);
      Log.i(`发现新设备：${item.alias} @ ${ip}`);
    }
    this.notify();
  }

  /** 全部设备（含 away），在线排前面，同状态按别名，保证列表不跳 */
  list(): DeviceItem[] {
    const all: DeviceItem[] = [];
    this.devices.forEach((v: DeviceItem) => {
      all.push(v);
    });
    all.sort((a: DeviceItem, b: DeviceItem) => {
      if (a.presence !== b.presence) {
        return a.presence === PRESENCE_ONLINE ? -1 : 1;
      }
      return a.alias.localeCompare(b.alias);
    });
    return all;
  }

  /** 只给发送用：away 的设备不能作为目标 */
  listOnline(): DeviceItem[] {
    const out: DeviceItem[] = [];
    const all = this.list();
    for (let i = 0; i < all.length; i++) {
      if (all[i].presence === PRESENCE_ONLINE) {
        out.push(all[i]);
      }
    }
    return out;
  }

  get(fingerprint: string): DeviceItem | undefined {
    return this.devices.get(fingerprint);
  }

  /** 每 1 秒推进状态机；只有状态真的变化才通知，避免每秒重建列表 */
  private tick(): void {
    const now = Date.now();
    let changed = false;
    const remove: string[] = [];

    this.devices.forEach((d: DeviceItem, fp: string) => {
      const age = now - d.lastSeen;
      if (age >= Const.DEVICE_REMOVE_MS) {
        remove.push(fp);
        changed = true;
        return;
      }
      const next = age < Const.DEVICE_ONLINE_MS ? PRESENCE_ONLINE : PRESENCE_AWAY;
      if (d.presence !== next) {
        d.presence = next;
        changed = true;
        Log.i(`设备状态变化：${d.alias} → ${next}（${Math.round(age / 1000)}s 未响应）`);
      }
    });

    for (let i = 0; i < remove.length; i++) {
      const d = this.devices.get(remove[i]);
      if (d !== undefined) {
        Log.i(`设备移除：${d.alias}（超过 ${Math.round(Const.DEVICE_REMOVE_MS / 1000)}s 未响应）`);
      }
      this.devices.delete(remove[i]);
    }

    if (changed) {
      this.notify();
    }
  }

  /** 应用启动时开一次，负责状态迁移与超时移除 */
  startPresence(): void {
    if (this.tickId !== -1) {
      return;
    }
    this.tickId = setInterval(() => {
      this.tick();
    }, Const.PRESENCE_TICK_MS);
    Log.i('设备状态机已启动');
  }

  stopPresence(): void {
    if (this.tickId !== -1) {
      clearInterval(this.tickId);
      this.tickId = -1;
    }
  }
}

export const deviceRegistry = new DeviceRegistryImpl();
