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
import { historyService, HistoryRecord, HistoryFile } from './HistoryService';

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
  /** 给任意 Promise 加超时，避免 socket 既不 resolve 也不 reject 时永远卡住 */
  static withTimeout<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
    return new Promise<T>((resolve: (v: T) => void, reject: (e: Error) => void) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          reject(new Error(`${label} 超时 ${ms}ms`));
        }
      }, ms);
      p.then((v: T) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(v);
        }
      }).catch((e: Error) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          reject(e);
        }
      });
    });
  }

  private tcp: socket.TCPSocket | null = null;
  private tls: socket.TLSSocket | null = null;
  private buffer: Uint8Array = new Uint8Array(0);
  private onData: (() => void) | null = null;
  private closed: boolean = false;

  async connect(secure: boolean, host: string, port: number, timeoutMs: number = 12000): Promise<void> {
    if (secure) {
      const t = socket.constructTLSSocketInstance();
      // 先挂到 this 上：连接失败/超时时 close() 才能释放它。
      // （之前是 connect 成功后才赋值，导致探测失败时 socket 泄漏，
      //   子网扫描 254 个 IP 累积后 fd 用尽，后续探测全部失败。）
      this.tls = t;
      try {
        // 鸿蒙要求先 bind 再 connect，否则 send 时报 2303600 No bind socket
        await HttpConn.withTimeout(t.bind({ address: '0.0.0.0', port: 0, family: 1 }), 5000, 'tls.bind');
        await HttpConn.withTimeout(t.connect({
          address: { address: host, port: port, family: 1 },
          // 对端是自签名证书（PC/手机各自生成），跳过校验以避免信任链问题
          secureOptions: { ca: [TlsCerts.CERT_PEM] },
          skipRemoteValidation: true,
          timeout: 10000
        }), timeoutMs, 'tls.connect');
      } catch (e) {
        // 不 await：close 自身有 800ms 超时，若阻塞会让子网扫描慢一倍。
        // 这里只发起释放，让底层异步回收。
        this.close().then(() => {
        }).catch(() => {
        });
        throw e as Error;
      }
      // 关键：事件订阅必须在 connect 之后注册。
      // 在 bind/connect 之前注册的 'message' 不会生效（实测收不到任何数据）。
      t.on('message', (info: socket.SocketMessageInfo) => {
        this.append(new Uint8Array(info.message));
      });
      t.on('error', () => {
        Log.w('TLS 连接报错');
      });
      t.on('close', () => {
        this.closed = true;
      });
    } else {
      const t = socket.constructTCPSocketInstance();
      this.tcp = t;
      try {
        // 同上：客户端 socket 必须先 bind
        await HttpConn.withTimeout(t.bind({ address: '0.0.0.0', port: 0, family: 1 }), 5000, 'tcp.bind');
        await HttpConn.withTimeout(t.connect({ address: { address: host, port: port, family: 1 }, timeout: 10000 }), timeoutMs, 'tcp.connect');
      } catch (e) {
        this.close().then(() => {
        }).catch(() => {
        });
        throw e as Error;
      }
      // 同上：订阅必须在 connect 之后
      t.on('message', (info: socket.SocketMessageInfo) => {
        this.append(new Uint8Array(info.message));
      });
      t.on('close', () => {
        this.closed = true;
      });
      this.tcp = t;
    }
  }

  async send(data: string | ArrayBuffer): Promise<void> {
    if (this.tls !== null) {
      await HttpConn.withTimeout(this.tls.send(data), 20000, 'tls.send');
    } else if (this.tcp !== null) {
      await HttpConn.withTimeout(this.tcp.send({ data: data }), 20000, 'tcp.send');
    }
  }

  async close(): Promise<void> {
    try {
      if (this.tls !== null) {
        await HttpConn.withTimeout(this.tls.close(), 800, 'tls.close');
      } else if (this.tcp !== null) {
        await HttpConn.withTimeout(this.tcp.close(), 800, 'tcp.close');
      }
    } catch (e) {
      Log.w(`关闭连接异常: ${String(e)}`);
    }
    this.tls = null;
    this.tcp = null;
  }

  private append(bytes: Uint8Array): void {
    Log.i(`客户端收到 ${bytes.length}B`);
    const merged = new Uint8Array(this.buffer.length + bytes.length);
    merged.set(this.buffer, 0);
    merged.set(bytes, this.buffer.length);
    this.buffer = merged;
    const cb = this.onData;
    if (cb !== null) {
      cb();
    }
  }

  /**
   * 读完整响应。
   * 三种 body 边界都要处理：
   *   1) Content-Length（最理想）
   *   2) Transfer-Encoding: chunked（Kestrel 对 JSON 响应常用，实测踩到）
   *   3) 连接关闭（兜底）
   */
  async readResponse(timeoutMs: number): Promise<HttpResponse> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const idx = HttpConn.findHeaderEnd(this.buffer);
      if (idx >= 0) {
        const headText = HttpConn.decode(HttpConn.slice(this.buffer, 0, idx));
        const bodyStart = idx + 4;
        const bodyBytes = HttpConn.slice(this.buffer, bodyStart, this.buffer.length);

        if (HttpConn.isChunked(headText)) {
          const chunk = HttpConn.decodeChunked(bodyBytes);
          if (chunk.complete || this.closed) {
            const resp = new HttpResponse();
            resp.parse(headText, chunk.text);
            return resp;
          }
        } else {
          const contentLength = HttpConn.parseContentLength(headText);
          if (contentLength >= 0 && bodyBytes.length >= contentLength) {
            const resp = new HttpResponse();
            resp.parse(headText, HttpConn.decode(HttpConn.slice(bodyBytes, 0, contentLength)));
            return resp;
          }
          if (contentLength < 0 && this.closed) {
            const resp = new HttpResponse();
            resp.parse(headText, HttpConn.decode(bodyBytes));
            return resp;
          }
        }
      } else if (this.closed) {
        throw new Error('连接已关闭但未收到完整响应头');
      }
      await HttpConn.sleep(20);
    }
    // 超时兜底：把已收到的内容交给上层，便于日志排查
    Log.w(`响应超时，已收 ${this.buffer.length}B，首部=${HttpConn.decode(HttpConn.slice(this.buffer, 0, Math.min(120, this.buffer.length)))}`);
    throw new Error('等待响应超时');
  }

  static isChunked(head: string): boolean {
    return head.toLowerCase().indexOf('transfer-encoding: chunked') >= 0;
  }

  /** 解析 chunked 编码；数据不完整时返回 complete=false */
  static decodeChunked(bytes: Uint8Array): ChunkResult {
    const result = new ChunkResult();
    let pos = 0;
    let out = '';
    while (pos < bytes.length) {
      let lineEnd = -1;
      for (let i = pos; i + 1 < bytes.length; i++) {
        if (bytes[i] === 13 && bytes[i + 1] === 10) {
          lineEnd = i;
          break;
        }
      }
      if (lineEnd < 0) {
        return result;
      }
      const sizeText = HttpConn.decode(HttpConn.slice(bytes, pos, lineEnd)).trim();
      const size = parseInt(sizeText, 16);
      if (isNaN(size)) {
        result.text = out;
        result.complete = true; // 解析不了就别卡住
        return result;
      }
      pos = lineEnd + 2;
      if (size === 0) {
        result.text = out;
        result.complete = true;
        return result;
      }
      if (pos + size + 2 > bytes.length) {
        result.text = out;
        return result;
      }
      out += HttpConn.decode(HttpConn.slice(bytes, pos, pos + size));
      pos += size + 2;
    }
    result.text = out;
    return result;
  }

  /** 从响应头里取 Content-Length，找不到返回 -1 */
  static parseContentLength(head: string): number {
    const lines = head.split('\r\n');
    for (let i = 1; i < lines.length; i++) {
      const line = lines[i];
      const c = line.indexOf(':');
      if (c <= 0) {
        continue;
      }
      const key = line.substring(0, c).trim().toLowerCase();
      if (key === 'content-length') {
        const v = parseInt(line.substring(c + 1).trim(), 10);
        return isNaN(v) ? -1 : v;
      }
    }
    return -1;
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

export class ChunkResult {
  complete: boolean = false;
  text: string = '';
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
      const resp = await conn.readResponse(60000);
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
      const err = e as BusinessError;
      Log.e(`prepare-upload 失败: code=${err.code} msg=${err.message} raw=${String(e)}`);
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
    this.recordSend(device, files, totalBytes, true);
    return SendResult.Success;
  }

  /** 发送历史（成功/失败都记，便于排查） */
  private recordSend(device: DeviceItem, files: SendFileItem[], totalBytes: number, success: boolean): void {
    const record = new HistoryRecord();
    record.id = `${Date.now()}`;
    record.direction = 'send';
    record.peerAlias = device.alias;
    record.peerIp = device.ip;
    record.totalSize = totalBytes;
    record.timestamp = Date.now();
    record.success = success;
    for (let i = 0; i < files.length; i++) {
      const hf = new HistoryFile();
      hf.name = files[i].name;
      hf.size = files[i].size;
      record.files.push(hf);
    }
    historyService.add(record);
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

  /** 取对端 info 的原始 body（自检用，验证 chunked 解码） */
  async fetchInfo(device: DeviceItem, timeoutMs: number = 12000): Promise<string> {
    const conn = new HttpConn();
    try {
      await conn.connect(device.protocol === 'https', device.ip, device.port, timeoutMs);
      await conn.send(`GET ${Const.PATH_INFO} HTTP/1.1\r\nHost: ${device.ip}:${device.port}\r\nConnection: close\r\n\r\n`);
      const resp = await conn.readResponse(Math.max(2000, timeoutMs));
      Log.i(`fetchInfo status=${resp.status} bodyLen=${resp.body.length}`);
      return resp.body;
    } finally {
      await conn.close();
    }
  }

  /** 探测设备是否可达（GET /info），用于发送前确认 */
  async probe(device: DeviceItem): Promise<boolean> {
    const conn = new HttpConn();
    try {
      await conn.connect(device.protocol === 'https', device.ip, device.port);
      Log.i('probe: 已连接，准备发送 GET');
      await conn.send(`GET ${Const.PATH_INFO} HTTP/1.1\r\nHost: ${device.ip}:${device.port}\r\nConnection: close\r\n\r\n`);
      Log.i('probe: GET 已发出，等待响应');
      const resp = await conn.readResponse(8000);
      Log.i(`probe: 收到响应 status=${resp.status}`);
      return resp.status === 200;
    } catch (e) {
      Log.w(`probe 失败: ${String(e)}`);
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
