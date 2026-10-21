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
   * 使用 HTTPS（默认开启）。
   * 服务端不用鸿蒙的 TLSSocketServer（大文件会丢最后 8KB），而是走 NAPI 原生 TLS 层
   * （OpenSSL），详见 docs/harmonyos-app-design.md §11.2 / §11.4。
   */
  https: boolean = true;
  pin: string = '';
  /**
   * 全局自动接收（旧字段，已废弃）。
   * 现在自动接收按设备授权，落在 autoAcceptList 里；这个字段只保留读写兼容，
   * 界面不再提供开关，对外公告的 download 恒为 false。
   */
  autoAccept: boolean = false;
  /**
   * 自动接收名单：白名单的子集（fingerprint，逗号分隔）。
   * 命中这里 + 在白名单里 → prepare-upload 直接 200，不弹确认。
   */
  autoAcceptList: string = '';
  /** 接收到的图片/视频自动提示存入相册（相册是手机上唯一用户可见、免受限权限的位置） */
  albumAuto: boolean = true;
  /**
   * 用户通过系统目录选择器授权的接收目录（真实路径，如
   * /storage/Users/currentUser/Download/快传）。
   * 空串 = 没授权过，接收目录回退到应用沙箱。
   */
  receiveDir: string = '';
  /** 同一个目录的 uri（activatePermission 恢复授权时要用 uri，不能用路径） */
  receiveDirUri: string = '';
  whitelistOnly: boolean = false;
  /** 'system' | 'light' | 'dark'（旧字段，保留兼容） */
  theme: string = 'system';
  /** 界面主题：'dark' | 'light'，默认暗色（与设计稿一致） */
  themeMode: string = 'dark';
  /** 访问控制模式：'blacklist' | 'whitelist'（空黑名单 = 全部放行） */
  accessMode: string = 'blacklist';
  /** 黑名单：设备 fingerprint，逗号分隔 */
  blackList: string = '';
  /** 白名单：设备 fingerprint，逗号分隔 */
  whiteList: string = '';
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
    s.https = this.readBoolean('https', true);
    s.pin = this.readString('pin', '');
    // 全局自动接收已废弃（改为白名单逐台授权），老库里的 true 一律收敛为 false
    s.autoAccept = false;
    s.autoAcceptList = this.readString('autoAcceptList', '');
    s.albumAuto = this.readBoolean('albumAuto', true);
    s.receiveDir = this.readString('receiveDir', '');
    s.receiveDirUri = this.readString('receiveDirUri', '');
    s.whitelistOnly = this.readBoolean('whitelistOnly', false);
    s.theme = this.readString('theme', 'system');
    s.themeMode = this.readString('themeMode', 'dark');
    s.accessMode = this.readString('accessMode', 'blacklist');
    if (s.accessMode === 'off') {
      // 旧版的「关闭」档已废弃，迁移成空黑名单（语义一致）
      s.accessMode = 'blacklist';
    }
    s.blackList = this.readString('blackList', '');
    s.whiteList = this.readString('whiteList', '');
    // 自动接收名单必须是白名单子集：老数据或外部改动导致越界时收敛掉
    s.autoAcceptList = SettingsServiceImpl.intersect(s.autoAcceptList, s.whiteList);
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
      // 不再公告「我可自动接收」：自动接收是逐设备白名单授权，
      // 对外一律保守声明 false，真实放行由服务端按名单判定
      download: false,
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
    this.write('autoAcceptList', s.autoAcceptList);
    this.write('albumAuto', s.albumAuto);
    this.write('receiveDir', s.receiveDir);
    this.write('receiveDirUri', s.receiveDirUri);
    this.write('whitelistOnly', s.whitelistOnly);
    this.write('theme', s.theme);
    this.write('themeMode', s.themeMode);
    this.write('accessMode', s.accessMode);
    this.write('blackList', s.blackList);
    this.write('whiteList', s.whiteList);
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

  /** 取交集（保留 a 中同时也出现在 b 里的指纹），顺带去重 */
  private static intersect(a: string, b: string): string {
    if (a.length === 0 || b.length === 0) {
      return '';
    }
    const allow: string[] = b.split(',');
    const out: string[] = [];
    const parts: string[] = a.split(',');
    for (let i = 0; i < parts.length; i++) {
      const fp = parts[i];
      if (fp.length > 0 && allow.indexOf(fp) >= 0 && out.indexOf(fp) < 0) {
        out.push(fp);
      }
    }
    return out.join(',');
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
