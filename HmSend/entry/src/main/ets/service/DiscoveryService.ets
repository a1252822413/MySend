// 组播发现：UDP 224.0.0.167:53317 收发公告。
// 对应 PC 端 Networking/MulticastDiscoveryService.cs。
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Log } from '../common/Logger';
import { Const } from '../common/Constants';
import { settingsService } from './SettingsService';
import { deviceRegistry } from './DeviceRegistry';
import { DeviceInfoDto } from '../model/Types';

class DiscoveryServiceImpl {
  private sock: socket.MulticastSocket | null = null;
  private announceTimer: number = -1;
  private running: boolean = false;

  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    const port = settingsService.value.port;
    const group = settingsService.value.multicastGroup;

    try {
      const s = socket.constructMulticastSocketInstance();
      // 绑 0.0.0.0:port 收全部网卡的组播；再单独加入组播组
      await s.bind({ address: '0.0.0.0', port: port, family: 1 });
      // 回环打开：LocalSend 的发现依赖"能收到自己发的公告"来确认链路可用
      await s.setLoopbackMode(true);
      await s.addMembership({ address: group, port: port, family: 1 });

      s.on('message', (info: socket.SocketMessageInfo) => {
        this.onPacket(info);
      });

      this.sock = s;
      this.running = true;
      Log.i(`组播已启动: ${group}:${port}`);
    } catch (e) {
      const err = e as BusinessError;
      Log.e(`组播启动失败: ${err.code} ${err.message}`);
      return;
    }

    // 立即公告一次，让对方尽快看到自己
    await this.announce();
    this.announceTimer = setInterval(() => {
      this.announce();
      deviceRegistry.purgeOffline();
    }, Const.ANNOUNCE_INTERVAL_MS);
  }

  async stop(): Promise<void> {
    if (this.announceTimer !== -1) {
      clearInterval(this.announceTimer);
      this.announceTimer = -1;
    }
    const s = this.sock;
    if (s !== null) {
      try {
        await s.close();
      } catch (e) {
        Log.w(`组播关闭异常: ${JSON.stringify(e)}`);
      }
      this.sock = null;
    }
    this.running = false;
    Log.i('组播已停止');
  }

  /** 主动发一次公告 */
  async announce(): Promise<void> {
    const s = this.sock;
    if (s === null) {
      return;
    }
    const payload = JSON.stringify(settingsService.toDeviceInfo(true));
    try {
      await s.send({
        data: payload,
        address: {
          address: settingsService.value.multicastGroup,
          port: settingsService.value.port,
          family: 1
        }
      });
    } catch (e) {
      const err = e as BusinessError;
      Log.w(`公告发送失败: ${err.code} ${err.message}`);
    }
  }

  private onPacket(info: socket.SocketMessageInfo): void {
    try {
      const decoder = util.TextDecoder.create('utf-8');
      const text = decoder.decodeToString(new Uint8Array(info.message));
      const dto = JSON.parse(text) as DeviceInfoDto;

      if (dto.fingerprint === undefined || dto.fingerprint.length === 0) {
        return;
      }
      // 丢掉自己的公告（回环模式下会收到）
      if (dto.fingerprint === settingsService.effectiveFingerprint()) {
        return;
      }
      const ip = info.remoteInfo.address;
      deviceRegistry.upsert(dto, ip);
    } catch (e) {
      Log.w(`公告解析失败: ${JSON.stringify(e)}`);
    }
  }
}

export const discoveryService = new DiscoveryServiceImpl();
