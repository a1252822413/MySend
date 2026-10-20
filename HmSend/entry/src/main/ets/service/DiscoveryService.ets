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
  /** 组播诊断矩阵开关（排查收不到公告时打开） */
  private static readonly DIAG_PROBES: boolean = false;

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

    // 诊断开关：需要复验组播配置时置 true，正常启动不要开（会多花约 5 秒）
    if (DiscoveryServiceImpl.DIAG_PROBES) {
      await this.probeRxMatrix(group);
    }

    const s = socket.constructMulticastSocketInstance();

    // 关键（真机 RX 矩阵实测得出，见 probeRxMatrix）：
    //   1) 必须先 addMembership 再 bind —— 先 bind 再 join 一律 2301022
    //   2) addMembership 的 port 必须传 0 —— 传实际端口不报错，但 membership 静默失效，
    //      表现为"能发公告、收不到任何包"（连自己回环都收不到）
    try {
      await s.addMembership({ address: group, port: 0, family: 1 });
      Log.i(`组播: addMembership ${group} 成功`);
    } catch (e) {
      const err = e as BusinessError;
      Log.e(`组播: addMembership 失败 ${err.code} ${err.message}`);
      return;
    }

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

    s.on('message', (info: socket.SocketMessageInfo) => {
      this.onPacket(info);
    });

    this.sock = s;
    this.running = true;
    Log.i('组播: 就绪，开始收发公告');

    await this.announce();
    // 状态迁移与超时移除统一交给 DeviceRegistry.startPresence()，
    // 这里只负责发公告，不再重复 purge
    this.announceTimer = setInterval(() => {
      this.announce();
    }, Const.ANNOUNCE_INTERVAL_MS);
  }

  /**
   * 收包矩阵实验：每次用独立端口，真实发一个 UDP 包，看 on('message') 是否触发。
   * 目的：确定「join 与 bind 的先后 + membership 参数形态 + reuseAddress」哪种组合能真正收到组播。
   */
  private async probeRxMatrix(group: string): Promise<void> {
    await this.rxCase('A join→bind(port=实际端口,family)', 53411, async (s: socket.MulticastSocket, port: number) => {
      await s.addMembership({ address: group, port: port, family: 1 });
      await s.bind({ address: '0.0.0.0', port: port, family: 1 });
    });

    await this.rxCase('B join→bind(port=0)', 53412, async (s: socket.MulticastSocket, port: number) => {
      await s.addMembership({ address: group, port: 0, family: 1 });
      await s.bind({ address: '0.0.0.0', port: port, family: 1 });
    });

    await this.rxCase('C join→bind(bind后补join)', 53413, async (s: socket.MulticastSocket, port: number) => {
      await s.addMembership({ address: group, port: port, family: 1 });
      await s.bind({ address: '0.0.0.0', port: port, family: 1 });
      await s.addMembership({ address: group, port: port, family: 1 });
    });

    await this.rxCase('D bind→join(port=0)', 53414, async (s: socket.MulticastSocket, port: number) => {
      await s.bind({ address: '0.0.0.0', port: port, family: 1 });
      await s.addMembership({ address: group, port: 0, family: 1 });
    });

    await this.rxCase('E bind→join(只给address)', 53415, async (s: socket.MulticastSocket, port: number) => {
      await s.bind({ address: '0.0.0.0', port: port, family: 1 });
      await s.addMembership({ address: group });
    });
  }

  private async rxCase(label: string, port: number, setup: (s: socket.MulticastSocket, p: number) => Promise<void>): Promise<void> {
    const group: string = settingsService.value.multicastGroup;
    const rx = socket.constructMulticastSocketInstance();
    let got = false;
    rx.on('message', (info: socket.SocketMessageInfo) => {
      got = true;
    });

    const tx = socket.constructMulticastSocketInstance();
    try {
      await setup(rx, port);
      await tx.bind({ address: '0.0.0.0', port: port + 100, family: 1 });
      await tx.send({ data: 'PING', address: { address: group, port: port, family: 1 } });
      await DiscoveryServiceImpl.sleep(1500);
      Log.i(`RX[${label}] = ${got ? '收到' : '没收到'}`);
    } catch (e) {
      const err = e as BusinessError;
      Log.w(`RX[${label}] 异常 ${err.code} ${err.message}`);
    } finally {
      try {
        await rx.close();
      } catch (e) {
      }
      try {
        await tx.close();
      } catch (e) {
      }
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
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
      const ip = info.remoteInfo.address;
      // 诊断用：先记"收到了什么"，再判断是自身还是别人（自身公告也会被回环收到）
      Log.i(`组播: 收到报文 ${text.length}B from ${ip}`);

      const dto = JSON.parse(text) as DeviceInfoDto;

      if (dto.fingerprint === undefined || dto.fingerprint.length === 0) {
        return;
      }
      if (dto.fingerprint === settingsService.effectiveFingerprint()) {
        return;
      }
      Log.i(`组播: 收到设备公告 ${dto.alias} @ ${ip} (${dto.protocol})`);
      deviceRegistry.upsert(dto, ip);
    } catch (e) {
      Log.w(`公告解析失败: ${JSON.stringify(e)}`);
    }
  }
}

export const discoveryService = new DiscoveryServiceImpl();
