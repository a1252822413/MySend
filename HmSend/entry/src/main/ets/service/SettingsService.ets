// 设置持久化：字段与 PC 端 AppSettings 一一对应（命名差异只在本层处理）。
// 默认值与 PC 端保持一致——尤其是 https 默认 true。
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';
import { Const } from '../common/Constants';
import { TlsCerts } from '../common/TlsCerts';
import { DeviceInfoDto } from '../model/Types';

const STORE_NAME: string = 'kuai_settings';

/** 持久化的设置实体（与 PC 端 AppSettings 对齐） */
export class Settings {
  alias: string = '';
  port: number = Const.DEFAULT_PORT;
  multicastGroup: string = Const.DEFAULT_MULTICAST_GROUP;
  /**
   * 使用 HTTPS。
   * 注意：鸿蒙 TLSSocketServer 接收多记录大 body 时会把最后一块压在原生缓冲里不投递
   * （实测 5MB 永远差 8192 字节），因此**默认关闭**，用明文 HTTP 保证大文件可收。
   * 详见 docs/harmonyos-app-design.md「已知平台限制」。
   */
  https: boolean = false;
  pin: string = '';
  /** 自动接收（收到 prepare-upload 直接同意，对应协议里的 download 字段） */
  autoAccept: boolean = false;
  whitelistOnly: boolean = false;
  /** 'system' | 'light' | 'dark' */
  theme: string = 'system';
  deviceModel: string = 'HarmonyOS';
  deviceType: string = 'mobile';
  /** 明文模式下的随机指纹（https 模式下用证书指纹） */
  httpFingerprint: string = '';
}

class SettingsServiceImpl {
  private store: preferences.Preferences | null = null;
  private current: Settings = new Settings();

  get value(): Settings {
    return this.current;
  }

  init(context: common.Context): void {
    try {
      this.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    } catch (e) {
      Log.e(`设置存储打开失败: ${JSON.stringify(e)}`);
      this.store = null;
    }

    const s = this.current;
    s.alias = this.readString('alias', SettingsServiceImpl.defaultAlias());
    s.port = this.readNumber('port', Const.DEFAULT_PORT);
    s.multicastGroup = this.readString('multicastGroup', Const.DEFAULT_MULTICAST_GROUP);
    s.https = this.readBoolean('https', false);
    s.pin = this.readString('pin', '');
    s.autoAccept = this.readBoolean('autoAccept', false);
    s.whitelistOnly = this.readBoolean('whitelistOnly', false);
    s.theme = this.readString('theme', 'system');
    s.deviceModel = this.readString('deviceModel', SettingsServiceImpl.defaultModel());
    s.deviceType = this.readString('deviceType', 'mobile');
    s.httpFingerprint = this.readString('httpFingerprint', SettingsServiceImpl.randomFingerprint());

    // 首次启动时把默认值落盘，避免每次都重新生成随机指纹
    this.persistAll();
    Log.i(`设置已加载: alias=${s.alias}, port=${s.port}, https=${s.https}`);
  }

  /** HTTPS 下指纹 = 证书 SHA-256；明文模式下用持久化的随机串（与 PC 端语义一致） */
  effectiveFingerprint(): string {
    return this.current.https ? TlsCerts.CERT_FINGERPRINT : this.current.httpFingerprint;
  }

  /** 组装 info 报文（公告与 /info 响应共用） */
  toDeviceInfo(announcement: boolean): DeviceInfoDto {
    const s = this.current;
    const dto: DeviceInfoDto = {
      alias: s.alias,
      version: Const.PROTOCOL_VERSION,
      deviceModel: s.deviceModel,
      deviceType: s.deviceType,
      fingerprint: this.effectiveFingerprint(),
      port: s.port,
      protocol: s.https ? 'https' : 'http',
      download: s.autoAccept,
      announcement: announcement
    };
    return dto;
  }

  save(mutator: (s: Settings) => void): void {
    mutator(this.current);
    this.persistAll();
    Log.i('设置已保存');
  }

  private persistAll(): void {
    const s = this.current;
    this.write('alias', s.alias);
    this.write('port', s.port);
    this.write('multicastGroup', s.multicastGroup);
    this.write('https', s.https);
    this.write('pin', s.pin);
    this.write('autoAccept', s.autoAccept);
    this.write('whitelistOnly', s.whitelistOnly);
    this.write('theme', s.theme);
    this.write('deviceModel', s.deviceModel);
    this.write('deviceType', s.deviceType);
    this.write('httpFingerprint', s.httpFingerprint);
  }

  private write(key: string, value: string | number | boolean): void {
    const store = this.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, value);
      store.flush();
    } catch (e) {
      Log.e(`设置写入失败 ${key}: ${JSON.stringify(e)}`);
    }
  }

  private readString(key: string, def: string): string {
    const store = this.store;
    if (store === null) {
      return def;
    }
    try {
      return store.getSync(key, def) as string;
    } catch (e) {
      return def;
    }
  }

  private readNumber(key: string, def: number): number {
    const store = this.store;
    if (store === null) {
      return def;
    }
    try {
      return store.getSync(key, def) as number;
    } catch (e) {
      return def;
    }
  }

  private readBoolean(key: string, def: boolean): boolean {
    const store = this.store;
    if (store === null) {
      return def;
    }
    try {
      return store.getSync(key, def) as boolean;
    } catch (e) {
      return def;
    }
  }

  private static defaultAlias(): string {
    try {
      const name = deviceInfo.marketName;
      return name !== undefined && name.length > 0 ? name : '快传手机';
    } catch (e) {
      return '快传手机';
    }
  }

  private static defaultModel(): string {
    try {
      const name = deviceInfo.productModel;
      return name !== undefined && name.length > 0 ? name : 'HarmonyOS';
    } catch (e) {
      return 'HarmonyOS';
    }
  }

  private static randomFingerprint(): string {
    let out = '';
    const chars = '0123456789ABCDEF';
    for (let i = 0; i < 32; i++) {
      out += chars.charAt(Math.floor(Math.random() * 16));
    }
    return out;
  }
}

export const settingsService = new SettingsServiceImpl();
