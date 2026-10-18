// 发送端：prepare-upload + 分块上传，支持 HTTP / HTTPS。
// 对应 PC 端 Networking/SendClient.cs。
//
// 为什么不用 @ohos.net.http：它要求把 body 放进内存（ArrayBuffer），
// 传 GB 级文件会直接 OOM。这里用 TCPSocket / TLSSocket 手写 HTTP，
// 边读文件边发，天然带背压（每块 await send）。
import { socket } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';
import { Const } from '../common/Constants';
import { TlsCerts } from '../common/TlsCerts';
import { settingsService } from './SettingsService';
import { DeviceItem, DeviceInfoDto, FileDto, PrepareUploadResponseDto } from '../model/Types';

/** 待发送的一个文件（来自文件选择器） */
export class SendFileItem {
  /** 文件 URI 或沙箱路径 */
  path: string = '';
  name: string = '';
  size: number = 0;
  mime: string = 'application/octet-stream';
}

export enum SendResult {
  Success = 0,
  PinRequired = 1,
  Declined = 2,
  Failed = 3
}

class HttpConn {
  private tcp: socket.TCPSocket | null = null;
  private tls: socket.TLSSocket | null = null;
  private buffer: Uint8Array = new Uint8Array(0);
  private onData: (() => void) | null = null;

  async connect(secure: boolean, host: string, port: number): Promise<void> {
    if (secure) {
      const t = socket.constructTLSSocketInstance();
      t.on('message', (info: socket.SocketMessageInfo) => {
        this.append(new Uint8Array(info.message));
      });
      t.on('error', () => {
        // 连接错误由超时/读取失败兜底
      });
      await t.connect({
        address: { address: host, port: port, family: 1 },
        // 对端是自签名证书（PC/手机各自生成），跳过校验以避免信任链问题
        secureOptions: { ca: [TlsCerts.CERT_PEM] },
        skipRemoteValidation: true,
        timeout: 10000
      });
      this.tls = t;
    } else {
      const t = socket.constructTCPSocketInstance();
      t.on('message', (info: socket.SocketMessageInfo) => {
        this.append(new Uint8Array(info.message));
      });
      t.on('error', () => {
      });
      await t.connect({ address: { address: host, port: port, family: 1 }, timeout: 10000 });
      this.tcp = t;
    }
  }

  async send(data: string | ArrayBuffer): Promise<void> {
    if (this.tls !== null) {
      await this.tls.send(data);
    } else if (this.tcp !== null) {
      await this.tcp.send({ data: data });
    }
  }

  async close(): Promise<void> {
    try {
      if (this.tls !== null) {
        await this.tls.close();
      } else if (this.tcp !== null) {
        await this.tcp.close();
      }
    } catch (e) {
      // 忽略关闭异常
    }
    this.tls = null;
    this.tcp = null;
  }

  private append(bytes: Uint8Array): void {
    const merged = new Uint8Array(this.buffer.length + bytes.length);
    merged.set(this.buffer, 0);
    merged.set(bytes, this.buffer.length);
    this.buffer = merged;
    const cb = this.onData;
    if (cb !== null) {
      cb();
    }
  }

  /** 等到响应头完整（\r\n\r\n），返回解析出的状态码与 body */
  async readResponse(timeoutMs: number): Promise<HttpResponse> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const idx = HttpConn.findHeaderEnd(this.buffer);
      if (idx >= 0) {
        const headText = HttpConn.decode(HttpConn.slice(this.buffer, 0, idx));
        const bodyBytes = HttpConn.slice(this.buffer, idx + 4, this.buffer.length);
        const resp = new HttpResponse();
        resp.parse(headText, HttpConn.decode(bodyBytes));
        return resp;
      }
      await HttpConn.sleep(20);
    }
    throw new Error('等待响应超时');
  }

  static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  static findHeaderEnd(b: Uint8Array): number {
    for (let i = 0; i + 3 < b.length; i++) {
      if (b[i] === 13 && b[i + 1] === 10 && b[i + 2] === 13 && b[i + 3] === 10) {
        return i;
      }
    }
    return -1;
  }

  static slice(src: Uint8Array, from: number, to: number): Uint8Array {
    const len = to - from;
    const out = new Uint8Array(len > 0 ? len : 0);
    for (let i = 0; i < len; i++) {
      out[i] = src[from + i];
    }
    return out;
  }

  static decode(bytes: Uint8Array): string {
    try {
      const d = util.TextDecoder.create('utf-8');
      return d.decodeToString(bytes);
    } catch (e) {
      return '';
    }
  }
}

export class HttpResponse {
  status: number = 0;
  body: string = '';

  parse(head: string, body: string): void {
    this.body = body;
    const line = head.split('\r\n')[0];
    const parts = line.split(' ');
    if (parts.length >= 2) {
      const code = parseInt(parts[1], 10);
      this.status = isNaN(code) ? 0 : code;
    }
  }
}

class SendClientImpl {
  /**
   * 发送一批文件到指定设备。
   * @param onProgress (已发送总字节, 总字节, 当前文件名)
   */
  async sendFiles(
    device: DeviceItem,
    files: SendFileItem[],
    pin: string,
    onProgress: (sent: number, total: number, current: string) => void
  ): Promise<SendResult> {
    if (files.length === 0) {
      return SendResult.Failed;
    }
    const secure = device.protocol === 'https';
    const host = device.ip;
    const port = device.port;

    let totalBytes = 0;
    for (let i = 0; i < files.length; i++) {
      totalBytes += files[i].size;
    }

    // 1) prepare-upload
    const dto: Record<string, FileDto> = {};
    const idOf: string[] = [];
    for (let i = 0; i < files.length; i++) {
      const id = `f${i}`;
      idOf.push(id);
      const f: FileDto = {
        id: id,
        fileName: files[i].name,
        size: files[i].size,
        fileType: files[i].mime
      };
      dto[id] = f;
    }
    const bodyObj: PrepareUploadBody = {
      info: settingsService.toDeviceInfo(false),
      files: dto
    };
    const bodyText = JSON.stringify(bodyObj);

    let pinQuery = '';
    if (pin.length > 0) {
      pinQuery = `?pin=${encodeURIComponent(pin)}`;
    }

    const conn = new HttpConn();
    let sessionId = '';
    let tokens: Record<string, string> = {};
    try {
      await conn.connect(secure, host, port);
      const head = `POST ${Const.PATH_PREPARE_UPLOAD}${pinQuery} HTTP/1.1\r\n` +
        `Host: ${host}:${port}\r\n` +
        `Content-Type: application/json\r\n` +
        `Content-Length: ${new util.TextEncoder().encodeInto(bodyText).length}\r\n` +
        `Connection: close\r\n\r\n`;
      await conn.send(head);
      await conn.send(bodyText);
      const resp = await conn.readResponse(15000);
      Log.i(`prepare-upload 返回 ${resp.status}`);

      if (resp.status === 401) {
        return SendResult.PinRequired;
      }
      if (resp.status === 403) {
        return SendResult.Declined;
      }
      if (resp.status !== 200) {
        return SendResult.Failed;
      }
      const parsed = JSON.parse(resp.body) as PrepareUploadResponseDto;
      sessionId = parsed.sessionId;
      tokens = parsed.files;
    } catch (e) {
      Log.e(`prepare-upload 失败: ${JSON.stringify(e)}`);
      return SendResult.Failed;
    } finally {
      await conn.close();
    }

    // 2) 逐个上传
    let sentTotal = 0;
    for (let i = 0; i < files.length; i++) {
      const id = idOf[i];
      const token = tokens[id];
      if (token === undefined) {
        Log.w(`文件 ${id} 未获得 token，跳过`);
        continue;
      }
      const ok = await this.uploadOne(
        secure, host, port, sessionId, id, token, files[i],
        (sentInFile: number) => {
          onProgress(sentTotal + sentInFile, totalBytes, files[i].name);
        }
      );
      if (!ok) {
        Log.e(`上传失败 ${files[i].name}`);
        return SendResult.Failed;
      }
      sentTotal += files[i].size;
      onProgress(sentTotal, totalBytes, files[i].name);
    }

    Log.i(`全部发送完成，共 ${files.length} 个文件 / ${totalBytes} 字节`);
    return SendResult.Success;
  }

  private async uploadOne(
    secure: boolean, host: string, port: number,
    sessionId: string, fileId: string, token: string,
    file: SendFileItem,
    onProgress: (sent: number) => void
  ): Promise<boolean> {
    const conn = new HttpConn();
    let handle: fs.File | null = null;
    try {
      await conn.connect(secure, host, port);
      const path = `${Const.PATH_UPLOAD}?sessionId=${encodeURIComponent(sessionId)}` +
        `&fileId=${encodeURIComponent(fileId)}&token=${encodeURIComponent(token)}`;
      const head = `POST ${path} HTTP/1.1\r\n` +
        `Host: ${host}:${port}\r\n` +
        `Content-Type: application/octet-stream\r\n` +
        `Content-Length: ${file.size}\r\n` +
        `Connection: close\r\n\r\n`;
      await conn.send(head);

      handle = fs.openSync(file.path, fs.OpenMode.READ_ONLY);
      // 64KB 一块，边读边发，await 天然形成背压
      const chunkSize = 65536;
      const buf = new ArrayBuffer(chunkSize);
      let offset = 0;
      while (offset < file.size) {
        const want = Math.min(chunkSize, file.size - offset);
        const read = fs.readSync(handle.fd, buf, { offset: offset, length: want });
        if (read <= 0) {
          break;
        }
        const payload = new Uint8Array(read);
        payload.set(new Uint8Array(buf).subarray(0, read), 0);
        await conn.send(payload.buffer);
        offset += read;
        onProgress(offset);
      }

      const resp = await conn.readResponse(30000);
      Log.i(`upload ${file.name} 返回 ${resp.status} (${offset}/${file.size})`);
      return resp.status === 200;
    } catch (e) {
      const err = e as BusinessError;
      Log.e(`upload 失败 ${file.name}: ${err.code} ${err.message}`);
      return false;
    } finally {
      if (handle !== null) {
        try {
          fs.closeSync(handle.fd);
        } catch (e) {
          // 忽略
        }
      }
      await conn.close();
    }
  }

  /** 探测设备是否可达（GET /info），用于发送前确认 */
  async probe(device: DeviceItem): Promise<boolean> {
    const conn = new HttpConn();
    try {
      await conn.connect(device.protocol === 'https', device.ip, device.port);
      await conn.send(`GET ${Const.PATH_INFO} HTTP/1.1\r\nHost: ${device.ip}:${device.port}\r\nConnection: close\r\n\r\n`);
      const resp = await conn.readResponse(8000);
      return resp.status === 200;
    } catch (e) {
      return false;
    } finally {
      await conn.close();
    }
  }
}

interface PrepareUploadBody {
  info: DeviceInfoDto;
  files: Record<string, FileDto>;
}

export const sendClient = new SendClientImpl();
