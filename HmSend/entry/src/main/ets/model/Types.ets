// 协议数据模型与本地状态模型。
// DTO 字段名必须与 PC 端序列化结果完全一致（System.Text.Json 用的默认 camelCase）。

/** GET /info 的响应体，同时也是组播公告的报文 */
export interface DeviceInfoDto {
  alias: string;
  version: string;
  deviceModel: string;
  deviceType: string;
  fingerprint: string;
  port: number;
  protocol: string;
  download: boolean;
  /** 仅公告报文带这个字段，用于区分"主动公告"与"被探测响应" */
  announcement?: boolean;
}

/** prepare-upload 请求里的单个文件描述 */
export interface FileDto {
  id: string;
  fileName: string;
  size: number;
  fileType?: string;
  sha256?: string;
}

/** POST /prepare-upload 请求体 */
export interface PrepareUploadRequestDto {
  info: DeviceInfoDto;
  files: Record<string, FileDto>;
}

/** POST /prepare-upload 响应体：sessionId + (fileId -> token) */
export interface PrepareUploadResponseDto {
  sessionId: string;
  files: Record<string, string>;
}

/** POST /cancel 请求体 */
export interface CancelRequestDto {
  sessionId: string;
}

/**
 * 界面用的设备条目（不是 DTO）。
 * 由 DeviceRegistry 维护，lastSeen 用于计算在线状态。
 */
export class DeviceItem {
  alias: string = '';
  fingerprint: string = '';
  deviceModel: string = '';
  deviceType: string = '';
  port: number = 53317;
  /** 'https' | 'http' */
  protocol: string = 'https';
  download: boolean = false;
  /** 来源 IP，发送时拼 URL 用 */
  ip: string = '';
  lastSeen: number = 0;

  constructor(alias: string, fingerprint: string, ip: string, port: number) {
    this.alias = alias;
    this.fingerprint = fingerprint;
    this.ip = ip;
    this.port = port;
    this.lastSeen = Date.now();
  }

  isOnline(timeoutMs: number): boolean {
    return Date.now() - this.lastSeen < timeoutMs;
  }

  /** 供界面显示的平台标签 */
  platformLabel(): string {
    if (this.deviceType === 'mobile') {
      return '手机';
    }
    if (this.deviceType === 'desktop') {
      return '电脑';
    }
    if (this.deviceType === 'web') {
      return '网页';
    }
    return this.deviceModel.length > 0 ? this.deviceModel : '未知';
  }
}
