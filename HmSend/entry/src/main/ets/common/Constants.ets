// 全局常量：与 PC 端（LocalSend 协议 v2.2）严格对齐。
// 任何一处改动都要同步检查 PcDemo 的 EndpointConfig / Endpoints/*。

export class Const {
  static readonly APP_NAME: string = '快传';

  /** 协议版本，写入 info 的 version 字段。 */
  static readonly PROTOCOL_VERSION: string = '2.2';

  static readonly DEFAULT_PORT: number = 53317;
  static readonly DEFAULT_MULTICAST_GROUP: string = '224.0.0.167';

  /** 公告周期（PC 端也是 20 秒）。 */
  static readonly ANNOUNCE_INTERVAL_MS: number = 20000;
  /** 设备超时：5 个公告周期没消息即视为离线。 */
  static readonly DEVICE_TIMEOUT_MS: number = 100000;

  static readonly PATH_INFO: string = '/api/localsend/v2/info';
  static readonly PATH_REGISTER: string = '/api/localsend/v2/register';
  static readonly PATH_PREPARE_UPLOAD: string = '/api/localsend/v2/prepare-upload';
  static readonly PATH_UPLOAD: string = '/api/localsend/v2/upload';
  static readonly PATH_CANCEL: string = '/api/localsend/v2/cancel';

  /** 接收文件默认落在应用沙箱的这个子目录。 */
  static readonly RECEIVED_DIR_NAME: string = 'received';
}
