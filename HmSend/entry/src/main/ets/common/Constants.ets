// 全局常量：与 PC 端（LocalSend 协议 v2.2）严格对齐。
// 任何一处改动都要同步检查 PcDemo 的 EndpointConfig / Endpoints/*。

export class Const {
  static readonly APP_NAME: string = '快传';

  /** 协议版本，写入 info 的 version 字段。 */
  static readonly PROTOCOL_VERSION: string = '2.2';

  static readonly DEFAULT_PORT: number = 53317;
  static readonly DEFAULT_MULTICAST_GROUP: string = '224.0.0.167';

  /**
   * 公告周期：5 秒。
   * 原值 20 秒太长——对方关掉 App 后要等 5 个周期（100 秒）才发现，
   * 这期间界面上一直是个假的绿点。5 秒是功耗与灵敏度的平衡点。
   */
  static readonly ANNOUNCE_INTERVAL_MS: number = 5000;
  /** 在线阈值：3 个公告周期没消息 → 转「离开」（容忍丢 2 个包） */
  static readonly DEVICE_ONLINE_MS: number = 15000;
  /** 「离开」状态保留 45 秒，总计 60 秒后从列表移除 */
  static readonly DEVICE_REMOVE_MS: number = 60000;
  /** 状态机 tick：只做状态迁移，变了才通知 UI */
  static readonly PRESENCE_TICK_MS: number = 1000;
  /** 兼容旧引用，等同在线阈值 */
  static readonly DEVICE_TIMEOUT_MS: number = 15000;

  static readonly PATH_INFO: string = '/api/localsend/v2/info';
  static readonly PATH_REGISTER: string = '/api/localsend/v2/register';
  static readonly PATH_PREPARE_UPLOAD: string = '/api/localsend/v2/prepare-upload';
  static readonly PATH_UPLOAD: string = '/api/localsend/v2/upload';
  static readonly PATH_CANCEL: string = '/api/localsend/v2/cancel';

  /** 接收文件默认落在应用沙箱的这个子目录。 */
  static readonly RECEIVED_DIR_NAME: string = 'received';
  /** 系统「下载」下的子目录名（能写公共目录时优先用它） */
  static readonly PUBLIC_DIR_NAME: string = '快传';
}
