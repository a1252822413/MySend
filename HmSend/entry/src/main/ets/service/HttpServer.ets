// 接收端 HTTP/HTTPS 服务：在 TCPSocketServer / TLSSocketServer 之上手写 HTTP/1.1。
// 对应 PC 端 Networking/LocalSendHttpServer.cs（Kestrel 那一层要自己实现）。
//
// 实现范围（够用且不复杂）：
//   · 只解析请求行 + 头部 + Content-Length 正文，不处理 chunked / multipart
//   · 每个请求响应后立即关闭连接（Connection: close），不做 keep-alive
//   · 上传走流式落盘（边收边写），不把大文件读进内存
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Log } from '../common/Logger';
import { Const } from '../common/Constants';
import { TlsCerts } from '../common/TlsCerts';
import * as tlsNative from 'libkuaitls.so';
import { settingsService } from './SettingsService';
import { deviceRegistry } from './DeviceRegistry';
import { fileReceiver, OpenFileResult, ReceiveFile } from './FileReceiver';
import { receiveRequests } from './ReceiveRequestService';
import { DeviceInfoDto, PrepareUploadRequestDto, PrepareUploadResponseDto, CancelRequestDto } from '../model/Types';

/** 把两种连接（TCP/TLS）收敛成一个可发送/关闭的最小接口 */
export class ConnAdapter {
  sendFn: (data: string | ArrayBuffer) => Promise<void>;
  closeFn: () => Promise<void>;

  constructor(sendFn: (data: string | ArrayBuffer) => Promise<void>, closeFn: () => Promise<void>) {
    this.sendFn = sendFn;
    this.closeFn = closeFn;
  }
}

class HttpSession {
  private conn: ConnAdapter;
  private buf: Uint8Array = new Uint8Array(0);
  private headersParsed: boolean = false;
  private responded: boolean = false;

  private method: string = '';
  private path: string = '';
  private query: Map<string, string> = new Map<string, string>();
  private contentLength: number = 0;
  private bodyReceived: number = 0;
  private bodyChunks: Uint8Array[] = [];

  /** 非空表示本次请求是上传，直接流式写盘 */
  private uploadFile: ReceiveFile | null = null;
  /** 鸿蒙 TLS 的原生缓冲只有等到"有新数据"才会继续下发（见下方 nudge 说明） */
  private nudgeTimer: number = -1;
  private lastDataAt: number = 0;
  /** prepareRoute 是异步的（要等文件句柄打开），期间到达的数据块必须先暂存，
      否则会被误当成请求体缓存 → 上传丢数据。 */
  private preparing: boolean = false;
  private pendingChunks: Uint8Array[] = [];

  constructor(conn: ConnAdapter) {
    this.conn = conn;
  }

  onData(chunk: Uint8Array): void {
    if (this.responded) {
      return;
    }
    if (this.preparing) {
      this.pendingChunks.push(chunk);
      return;
    }
    if (!this.headersParsed) {
      this.buf = HttpSession.concat(this.buf, chunk);
      const idx = HttpSession.findHeaderEnd(this.buf);
      if (idx < 0) {
        if (this.buf.length > 65536) {
          this.respond(400, 'Header too large');
        }
        return;
      }
      const headText = HttpSession.decode(HttpSession.copyRange(this.buf, 0, idx));
      const rest = HttpSession.copyRange(this.buf, idx + 4, this.buf.length);
      this.buf = new Uint8Array(0);
      this.parseHead(headText);
      this.headersParsed = true;

      if (this.path === Const.PATH_UPLOAD && this.method === 'POST') {
        this.preparing = true;
      }
      this.prepareRoute().then(() => {
        this.preparing = false;
        if (!this.responded && rest.length > 0) {
          this.onBody(rest);
        }
        for (let i = 0; i < this.pendingChunks.length; i++) {
          if (this.responded) {
            break;
          }
          this.onBody(this.pendingChunks[i]);
        }
        this.pendingChunks = [];
        if (!this.responded && this.contentLength === 0) {
          this.dispatch();
        }
      });
      return;
    }
    this.onBody(chunk);
  }

  private parseHead(text: string): void {
    const lines = text.split('\r\n');
    if (lines.length === 0) {
      this.respond(400, 'Bad request');
      return;
    }
    const first = lines[0].split(' ');
    if (first.length < 3) {
      this.respond(400, 'Bad request line');
      return;
    }
    this.method = first[0];
    const target = first[1];
    const q = target.indexOf('?');
    if (q >= 0) {
      this.path = target.substring(0, q);
      this.query = HttpSession.parseQuery(target.substring(q + 1));
    } else {
      this.path = target;
    }

    for (let i = 1; i < lines.length; i++) {
      const line = lines[i];
      const c = line.indexOf(':');
      if (c > 0) {
        const key = line.substring(0, c).trim().toLowerCase();
        const val = line.substring(c + 1).trim();
        if (key === 'content-length') {
          this.contentLength = parseInt(val, 10);
          if (isNaN(this.contentLength) || this.contentLength < 0) {
            this.contentLength = 0;
          }
        }
      }
    }
    Log.i(`收到请求 ${this.method} ${this.path} len=${this.contentLength}`);
  }

  /** 上传请求需要先按 sessionId/fileId/token 打开文件 */
  private async prepareRoute(): Promise<void> {
    if (this.path !== Const.PATH_UPLOAD || this.method !== 'POST') {
      return;
    }
    const sessionId = this.param('sessionId');
    const fileId = this.param('fileId');
    const token = this.param('token');
    if (sessionId.length === 0 || fileId.length === 0 || token.length === 0) {
      this.respond(400, JSON.stringify({ message: 'Missing parameters' }));
      return;
    }
    const result: OpenFileResult = fileReceiver.openFile(sessionId, fileId, token);
    if (result.file === null) {
      this.respond(result.statusCode, JSON.stringify({ message: result.message }));
      return;
    }
    this.uploadFile = result.file;
    this.lastDataAt = Date.now();
    // 看门狗：鸿蒙的 TLS 实现把多余数据缓在原生层，只有在"又收到新数据"时才继续
    // 投递 message 事件。客户端发完最后一段就静默了，于是尾部数据永远不上来。
    // 对策：检测到 400ms 没有新数据且请求体未收完，就发一个空 TLS 记录去踢一下。
    this.nudgeTimer = setInterval(() => {
      this.checkStall();
    }, 300);
  }

  private onBody(data: Uint8Array): void {
    const file = this.uploadFile;
    if (file !== null) {
      this.lastDataAt = Date.now();
      const written = fileReceiver.write(file, data);
      this.bodyReceived += written;
      // 诊断：大文件传输时观察分块大小与累计进度
      if (file.received % 524288 < data.length) {
        Log.i(`进度 ${file.received}/${file.size} (${data.length}B/块) t=${Date.now()}`);
      }
      if (this.bodyReceived >= this.contentLength && this.contentLength > 0) {
        // 数据只是入队，必须等真正落盘再回 200，否则客户端可能先收到成功
        const f = file;
        fileReceiver.flush(f).then(() => {
          fileReceiver.close(f);
          this.respond(200, '');
        });
      }
      return;
    }

    this.bodyChunks.push(data);
    this.bodyReceived += data.length;
    if (this.bodyReceived >= this.contentLength) {
      Log.i(`请求体接收完成 ${this.path} ${this.bodyReceived}B`);
      this.dispatch();
    }
  }

  private dispatch(): void {
    const body = this.bodyText();
    if (this.path === Const.PATH_INFO && this.method === 'GET') {
      this.respond(200, JSON.stringify(settingsService.toDeviceInfo(false)));
      return;
    }
    if (this.path === Const.PATH_REGISTER && this.method === 'POST') {
      this.handleRegister(body);
      return;
    }
    if (this.path === Const.PATH_PREPARE_UPLOAD && this.method === 'POST') {
      this.handlePrepare(body);
      return;
    }
    if (this.path === Const.PATH_UPLOAD && this.method === 'POST') {
      // 零长度上传（空文件）不会进 onBody 的写入分支，这里兜底
      const file = this.uploadFile;
      if (file !== null) {
        fileReceiver.close(file);
        this.respond(200, '');
      } else {
        this.respond(403, JSON.stringify({ message: 'Invalid session' }));
      }
      return;
    }
    if (this.path === Const.PATH_CANCEL && this.method === 'POST') {
      this.handleCancel(body);
      return;
    }
    this.respond(404, JSON.stringify({ message: 'Not found' }));
  }

  private handleRegister(body: string): void {
    try {
      const dto = JSON.parse(body) as DeviceInfoDto;
      deviceRegistry.upsert(dto, this.senderIpHint(dto));
      this.respond(200, '');
    } catch (e) {
      Log.w(`register 解析失败: ${JSON.stringify(e)}`);
      this.respond(400, JSON.stringify({ message: 'Invalid body' }));
    }
  }

  private async handlePrepare(body: string): Promise<void> {
    // PIN 校验：本机设了 PIN 就必须带 ?pin= 且完全匹配（PC 端同样返回 401）
    const pin = settingsService.value.pin;
    if (pin.length > 0 && this.param('pin') !== pin) {
      Log.w('prepare-upload PIN 校验失败');
      this.respond(401, JSON.stringify({ message: 'Invalid pin' }));
      return;
    }

    let req: PrepareUploadRequestDto;
    try {
      req = JSON.parse(body) as PrepareUploadRequestDto;
    } catch (e) {
      Log.w(`prepare-upload 解析失败: ${JSON.stringify(e)}`);
      this.respond(400, JSON.stringify({ message: 'Invalid body' }));
      return;
    }
    if (req.files === undefined) {
      this.respond(400, JSON.stringify({ message: 'Missing files' }));
      return;
    }

    const senderAlias = req.info !== undefined && req.info.alias !== undefined ? req.info.alias : '未知设备';
    // 发送方信息顺带入表，便于界面立刻显示
    if (req.info !== undefined) {
      deviceRegistry.upsert(req.info, '');
    }

    const allIds = Object.keys(req.files);
    let accepted: string[] = allIds;
    if (!settingsService.value.autoAccept) {
      // 挂住连接，等用户在界面上点接收/拒绝（最多 120 秒）
      Log.i(`等待用户确认接收：${senderAlias} 发来 ${allIds.length} 个文件`);
      accepted = await receiveRequests.ask(senderAlias, '', req.files, 120000);
    }

    if (accepted.length === 0) {
      Log.i('用户拒绝接收，返回 403');
      this.respond(403, JSON.stringify({ message: 'Declined' }));
      return;
    }

    const resp: PrepareUploadResponseDto = fileReceiver.createSession(req.files, '', accepted, senderAlias);
    this.respond(200, JSON.stringify(resp));
  }

  private handleCancel(body: string): void {
    try {
      const req = JSON.parse(body) as CancelRequestDto;
      const ok = fileReceiver.cancel(req.sessionId);
      this.respond(ok ? 200 : 204, '');
    } catch (e) {
      this.respond(400, JSON.stringify({ message: 'Invalid body' }));
    }
  }

  private senderIpHint(dto: DeviceInfoDto): string {
    // register 的 body 不带 IP，真实 IP 由连接对端提供；这里拿不到就用空串占位
    return '';
  }

  private param(key: string): string {
    const v = this.query.get(key);
    return v === undefined ? '' : v;
  }

  private bodyText(): string {
    let total = 0;
    for (let i = 0; i < this.bodyChunks.length; i++) {
      total += this.bodyChunks[i].length;
    }
    const merged = new Uint8Array(total);
    let off = 0;
    for (let i = 0; i < this.bodyChunks.length; i++) {
      merged.set(this.bodyChunks[i], off);
      off += this.bodyChunks[i].length;
    }
    return HttpSession.decode(merged);
  }

  /** 停滞检测：必要时发空记录触发原生缓冲下发 */
  private checkStall(): void {
    if (this.responded || this.uploadFile === null) {
      this.stopNudge();
      return;
    }
    if (this.bodyReceived >= this.contentLength) {
      this.stopNudge();
      return;
    }
    if (Date.now() - this.lastDataAt < 400) {
      return;
    }
    Log.i(`上传停滞 ${this.bodyReceived}/${this.contentLength}，发送空记录触发下发`);
    this.conn.sendFn(new ArrayBuffer(0)).catch((e: BusinessError) => {
      Log.w(`空记录发送失败: ${e.code} ${e.message}`);
    });
    this.lastDataAt = Date.now();
  }

  private stopNudge(): void {
    if (this.nudgeTimer !== -1) {
      clearInterval(this.nudgeTimer);
      this.nudgeTimer = -1;
    }
  }

  private respond(code: number, body: string): void {
    this.stopNudge();
    if (this.responded) {
      return;
    }
    this.responded = true;
    try {
      this.buildAndSend(code, body);
    } catch (e) {
      Log.e(`响应构造异常 code=${code}: ${JSON.stringify(e)}`);
    }
  }

  private buildAndSend(code: number, body: string): void {

    const enc = new util.TextEncoder();
    // encodeInto('') 在 ArkTS 上会抛异常（已实测），空响应体必须单独判空
    const bodyBytes = body.length > 0 ? enc.encodeInto(body) : new Uint8Array(0);
    const contentType = body.length > 0 ? 'application/json' : 'text/plain';
    const head = `HTTP/1.1 ${code} ${HttpSession.reason(code)}\r\n` +
      `Content-Type: ${contentType}\r\n` +
      `Content-Length: ${bodyBytes.length}\r\n` +
      `Connection: close\r\n\r\n`;
    const headBytes = enc.encodeInto(head);
    const out = HttpSession.concat(headBytes, bodyBytes);

    Log.i(`响应: 准备发送 code=${code} bytes=${out.length}`);
    // 不要在 'message' 回调里同步 send：鸿蒙的 TLSSocketConnection 在这种重入上下文中
    // 会静默卡住（不报错、不发送），表现为客户端一直等响应直到超时。
    // 用 setTimeout(0) 跳出回调上下文再发。
    setTimeout(() => {
      Log.i(`响应: 开始 send code=${code}`);
      this.conn.sendFn(out.buffer).then(() => {
        Log.i(`响应: send 完成 code=${code}`);
        this.conn.closeFn();
      }).catch((e: BusinessError) => {
        Log.w(`响应发送失败: ${e.code} ${e.message}`);
        this.conn.closeFn();
      });
    }, 0);
  }

  private static reason(code: number): string {
    if (code === 200) {
      return 'OK';
    }
    if (code === 204) {
      return 'No Content';
    }
    if (code === 400) {
      return 'Bad Request';
    }
    if (code === 401) {
      return 'Unauthorized';
    }
    if (code === 403) {
      return 'Forbidden';
    }
    if (code === 404) {
      return 'Not Found';
    }
    return 'Error';
  }

  private static parseQuery(q: string): Map<string, string> {
    const map = new Map<string, string>();
    const parts = q.split('&');
    for (let i = 0; i < parts.length; i++) {
      const kv = parts[i].split('=');
      if (kv.length === 2) {
        try {
          map.set(decodeURIComponent(kv[0]), decodeURIComponent(kv[1]));
        } catch (e) {
          map.set(kv[0], kv[1]);
        }
      }
    }
    return map;
  }

  static concat(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  static copyRange(src: Uint8Array, start: number, end: number): Uint8Array {
    const len = end - start;
    const out = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
      out[i] = src[start + i];
    }
    return out;
  }

  static findHeaderEnd(b: Uint8Array): number {
    for (let i = 0; i + 3 < b.length; i++) {
      if (b[i] === 13 && b[i + 1] === 10 && b[i + 2] === 13 && b[i + 3] === 10) {
        return i;
      }
    }
    return -1;
  }

  static decode(bytes: Uint8Array): string {
    try {
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(bytes);
    } catch (e) {
      let s = '';
      for (let i = 0; i < bytes.length; i++) {
        s += String.fromCharCode(bytes[i]);
      }
      return s;
    }
  }
}

class HttpServerImpl {
  private tcp: socket.TCPSocketServer | null = null;
  private tls: socket.TLSSocketServer | null = null;
  private running: boolean = false;
  /** 原生 TLS 层的连接会话表 */
  private tlsSessions: Map<number, HttpSession> = new Map<number, HttpSession>();
  private tlsNativeStarted: boolean = false;

  isRunning(): boolean {
    return this.running;
  }

  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    const port = settingsService.value.port;
    const useTls = settingsService.value.https;

    try {
      if (useTls) {
        await this.startTls(port);
      } else {
        await this.startTcp(port);
      }
      this.running = true;
      Log.i(useTls ? `HTTPS 服务已启动 :${port}` : `HTTP 服务已启动 :${port}`);
    } catch (e) {
      const err = e as BusinessError;
      Log.e(`服务启动失败: ${err.code} ${err.message}`);
    }
  }

  private async startTcp(port: number): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    await server.listen({ address: '0.0.0.0', port: port, family: 1 });
    server.on('connect', (conn: socket.TCPSocketConnection) => {
      // TCP 连接的 send 需要 TCPSendOptions 包一层
      const adapter = new ConnAdapter(
        (data: string | ArrayBuffer): Promise<void> => conn.send({ data: data }),
        (): Promise<void> => conn.close()
      );
      const session = new HttpSession(adapter);
      conn.on('message', (info: socket.SocketMessageInfo) => {
        session.onData(new Uint8Array(info.message));
      });
      conn.on('error', () => {
        conn.close();
      });
    });
    this.tcp = server;
  }

  /**
   * HTTPS 服务：走 NAPI 原生 TLS 层（OpenSSL）。
   *
   * 为什么不用鸿蒙的 TLSSocketServer：实测它在多记录大 body 上会丢最后一个 8KB
   * （详见 docs/harmonyos-app-design.md §11.2），且卡住后会拖死整个服务。
   * 原生层只负责"握手 + 加解密 + 收发原始字节"，HTTP 解析仍由上层 HttpSession 完成，
   * 因此协议逻辑（PIN/token/分块落盘/路径校验）一行都不用改。
   */
  private async startTls(port: number): Promise<void> {
    const ok: boolean = tlsNative.start(
      port,
      TlsCerts.CERT_PEM,
      TlsCerts.KEY_PEM,
      (connId: number) => {
        Log.i(`TLS 连接建立 #${connId}`);
        const adapter = new ConnAdapter(
          (data: string | ArrayBuffer): Promise<void> => {
            const buf = HttpServerImpl.toArrayBuffer(data);
            const sent: boolean = tlsNative.send(connId, buf);
            if (!sent && buf.byteLength > 0) {
              Log.w(`TLS 发送失败 #${connId}`);
            }
            return Promise.resolve();
          },
          (): Promise<void> => {
            tlsNative.closeConn(connId);
            return Promise.resolve();
          }
        );
        this.tlsSessions.set(connId, new HttpSession(adapter));
      },
      (connId: number, data: ArrayBuffer) => {
        const session = this.tlsSessions.get(connId);
        if (session !== undefined) {
          session.onData(new Uint8Array(data));
        }
      },
      (connId: number) => {
        this.tlsSessions.delete(connId);
        Log.i(`TLS 连接关闭 #${connId}`);
      }
    );

    if (!ok) {
      throw new Error('libkuaitls.start 失败（证书/端口/已启动）');
    }
    this.tlsNativeStarted = true;
    Log.i(`HTTPS 服务已启动 :${port}（native TLS, ${String(tlsNative.version())}）`);
  }

  /** 把字符串或 ArrayBuffer 统一成原生层要的 ArrayBuffer */
  private static toArrayBuffer(data: string | ArrayBuffer): ArrayBuffer {
    if (typeof data === 'string') {
      const bytes = new util.TextEncoder().encodeInto(data);
      const out = new ArrayBuffer(bytes.length);
      new Uint8Array(out).set(bytes, 0);
      return out;
    }
    return data;
  }

  async stop(): Promise<void> {
    const tcp = this.tcp;
    const tls = this.tls;
    this.tcp = null;
    this.tls = null;
    this.running = false;
    if (this.tlsNativeStarted) {
      this.tlsNativeStarted = false;
      this.tlsSessions.clear();
      tlsNative.stop();
      Log.i('native TLS 已停止');
    }
    try {
      if (tcp !== null) {
        await tcp.close();
      }
      if (tls !== null) {
        await tls.close();
      }
    } catch (e) {
      Log.w(`服务关闭异常: ${JSON.stringify(e)}`);
    }
    Log.i('服务已停止');
  }
}

export const httpServer = new HttpServerImpl();
