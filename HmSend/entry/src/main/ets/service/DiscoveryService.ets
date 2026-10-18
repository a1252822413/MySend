// 组播发现：UDP 224.0.0.167:53317 收发公告。
// 对应 PC 端 Networking/MulticastDiscoveryService.cs。
//
// 说明：鸿蒙的 MulticastSocket 对 bind 参数很挑剔，不同版本对 family / address 的组合
// 接受度不一样（实测 bind({0.0.0.0, family:1}) 返回 2301022 Invalid argument）。
// 这里按「0.0.0.0+family → 0.0.0.0 → 本机 WLAN IP」三级回退，并逐步骤打日志，
// 方便在真机上直接看出是哪一步不被接受。
import { socket, connection } from '@kit.NetworkKit';
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

  isRunning(): boolean {
    return this.running;
  }

  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    const port = settingsService.value.port;
    const group = settingsService.value.multicastGroup;
    Log.i(`组播启动: group=${group} port=${port}`);

    const s = socket.constructMulticastSocketInstance();

    const bound = await this.tryBind(s, port);
    if (!bound) {
      Log.e('组播: 所有 bind 方式均失败，设备发现不可用');
      return;
    }

    // 回环：LocalSend 依赖"能收到自己公告"确认链路健康，失败不致命
    try {
      await s.setLoopbackMode(true);
      Log.i('组播: setLoopbackMode(true) 成功');
    } catch (e) {
      const err = e as BusinessError;
      Log.w(`组播: setLoopbackMode 失败 ${err.code} ${err.message}（继续）`);
    }

    try {
      await s.addMembership({ address: group, port: port, family: 1 });
      Log.i(`组播: addMembership ${group} 成功`);
    } catch (e) {
      const err = e as BusinessError;
      Log.e(`组播: addMembership 失败 ${err.code} ${err.message}`);
      return;
    }

    s.on('message', (info: socket.SocketMessageInfo) => {
      this.onPacket(info);
    });

    this.sock = s;
    this.running = true;
    Log.i('组播: 就绪，开始收发公告');

    await this.announce();
    this.announceTimer = setInterval(() => {
      this.announce();
      deviceRegistry.purgeOffline();
    }, Const.ANNOUNCE_INTERVAL_MS);
  }

  /** 三级回退绑定，返回是否成功 */
  private async tryBind(s: socket.MulticastSocket, port: number): Promise<boolean> {
    try {
      await s.bind({ address: '0.0.0.0', port: port, family: 1 });
      Log.i('组播: bind(0.0.0.0, family=1) 成功');
      return true;
    } catch (e) {
      const err = e as BusinessError;
      Log.w(`组播: bind(0.0.0.0, family=1) 失败 ${err.code} ${err.message}`);
    }

    try {
      await s.bind({ address: '0.0.0.0', port: port });
      Log.i('组播: bind(0.0.0.0) 成功');
      return true;
    } catch (e) {
      const err = e as BusinessError;
      Log.w(`组播: bind(0.0.0.0) 失败 ${err.code} ${err.message}`);
    }

    const ip = await this.localIpv4();
    if (ip.length > 0) {
      try {
        await s.bind({ address: ip, port: port, family: 1 });
        Log.i(`组播: bind(${ip}) 成功`);
        return true;
      } catch (e) {
        const err = e as BusinessError;
        Log.w(`组播: bind(${ip}) 失败 ${err.code} ${err.message}`);
      }
    } else {
      Log.w('组播: 未取到本机 WLAN IPv4 地址');
    }
    return false;
  }

  /** 取默认网络（通常 WLAN）的 IPv4 地址 */
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
      Log.w(`获取本机 IP 失败: ${JSON.stringify(e)}`);
    }
    return '';
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
      Log.i(`组播: 已发送公告 (${payload.length}B)`);
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
      if (dto.fingerprint === settingsService.effectiveFingerprint()) {
        return;
      }
      const ip = info.remoteInfo.address;
      Log.i(`组播: 收到公告 ${dto.alias} @ ${ip} (${dto.protocol})`);
      deviceRegistry.upsert(dto, ip);
    } catch (e) {
      Log.w(`公告解析失败: ${JSON.stringify(e)}`);
    }
  }
}

export const discoveryService = new DiscoveryServiceImpl();
