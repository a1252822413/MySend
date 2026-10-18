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
import { settingsService } from './SettingsService';
import { deviceRegistry } from './DeviceRegistry';
import { fileReceiver, OpenFileResult, ReceiveFile } from './FileReceiver';
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
  }

  private onBody(data: Uint8Array): void {
    const file = this.uploadFile;
    if (file !== null) {
      const written = fileReceiver.write(file, data);
      this.bodyReceived += written;
      if (this.bodyReceived >= this.contentLength && this.contentLength > 0) {
        fileReceiver.close(file);
        this.respond(200, '');
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

  private handlePrepare(body: string): void {
    // PIN 校验：本机设了 PIN 就必须带 ?pin= 且完全匹配（PC 端同样返回 401）
    const pin = settingsService.value.pin;
    if (pin.length > 0 && this.param('pin') !== pin) {
      Log.w('prepare-upload PIN 校验失败');
      this.respond(401, JSON.stringify({ message: 'Invalid pin' }));
      return;
    }
    try {
      const req = JSON.parse(body) as PrepareUploadRequestDto;
      if (req.files === undefined) {
        this.respond(400, JSON.stringify({ message: 'Missing files' }));
        return;
      }
      // 发送方信息顺带入表，便于界面立刻显示
      if (req.info !== undefined) {
        deviceRegistry.upsert(req.info, '');
      }
      const resp: PrepareUploadResponseDto = fileReceiver.createSession(req.files, '');
      this.respond(200, JSON.stringify(resp));
    } catch (e) {
      Log.w(`prepare-upload 解析失败: ${JSON.stringify(e)}`);
      this.respond(400, JSON.stringify({ message: 'Invalid body' }));
    }
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

  private respond(code: number, body: string): void {
    if (this.responded) {
      return;
    }
    this.responded = true;

    const enc = new util.TextEncoder();
    const bodyBytes = enc.encodeInto(body);
    const contentType = body.length > 0 ? 'application/json' : 'text/plain';
    const head = `HTTP/1.1 ${code} ${HttpSession.reason(code)}\r\n` +
      `Content-Type: ${contentType}\r\n` +
      `Content-Length: ${bodyBytes.length}\r\n` +
      `Connection: close\r\n\r\n`;
    const headBytes = enc.encodeInto(head);
    const out = HttpSession.concat(headBytes, bodyBytes);

    this.conn.sendFn(out.buffer).then(() => {
      this.conn.closeFn();
    }).catch((e: BusinessError) => {
      Log.w(`响应发送失败: ${e.code} ${e.message}`);
      this.conn.closeFn();
    });
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

  private async startTls(port: number): Promise<void> {
    const server = socket.constructTLSSocketServerInstance();
    await server.listen({
      address: { address: '0.0.0.0', port: port, family: 1 },
      secureOptions: {
        cert: TlsCerts.CERT_PEM,
        key: TlsCerts.KEY_PEM,
        ca: [TlsCerts.CERT_PEM],
        protocols: socket.Protocol.TLSv12,
        useRemoteCipherPrefer: true,
        signatureAlgorithms: 'rsa_pss_rsae_sha256:ECDSA+SHA256',
        cipherSuite: 'AES256-SHA256'
      },
      ALPNProtocols: ['http/1.1']
    });
    server.on('connect', (conn: socket.TLSSocketConnection) => {
      // TCP 连接的 send 需要 TCPSendOptions 包一层
      // TLS 连接的 send 直接接收 payload，不包 TCPSendOptions
      const adapter = new ConnAdapter(
        (data: string | ArrayBuffer): Promise<void> => conn.send(data),
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
    this.tls = server;
  }

  async stop(): Promise<void> {
    const tcp = this.tcp;
    const tls = this.tls;
    this.tcp = null;
    this.tls = null;
    this.running = false;
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
