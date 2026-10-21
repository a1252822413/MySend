import { fileIo } from '@kit.CoreFileKit';
import { ApiPath } from '../wire/Constants';
import {
  Dto, WireDeviceInfo, WireFile, WireFileMetadata, WirePrepareDownloadResponse
} from '../wire/Dto';
import { JsonWriter } from '../wire/JsonValue';
import {
  ChunkSink, Exchange, RequestHandler, ServerReply, bytesFromUtf8, replyWithHtml, replyWithJson,
  replyWithMessage, replyWithStream
} from '../httpx/Exchange';
import { Status } from '../httpx/Http';
import { PinGuard, PinResult } from '../session/PinGuard';
import { SendSource } from '../send/SendTypes';
import { mimeTypeOf } from '../send/MimeTypes';
import { UriStat, statUri } from '../util/FileStat';
import { describeFailure } from '../util/Errors';
import { DOWNLOAD_PAGE, SHARING_OFF_PAGE, UPLOAD_PAGE, webText } from './WebPages';
import { WEB_I18N_PATH, WebOfferContext, WebOfferFile, WebShareConfig, WebShareMode } from './WebTypes';

const DOWNLOAD_CHUNK: number = 64 * 1024;
/** How often an unanswered browser request checks whether the browser is still there. */
const HANGUP_POLL_MS: number = 500;
/** Clients remembered before the quietest is dropped; a LAN never has this many browsers. */
const MAX_TRACKED_CLIENTS: number = 32;
/** A `User-Agent` is display text for the confirmation dialog, so it is only ever shown shortened. */
const MAX_USER_AGENT: number = 140;

/** ASCII characters a `Content-Disposition` file name may carry unescaped (RFC 6266 with RFC 2396 marks). */
const UNRESERVED_PUNCT: string = "-_.!~*'()";
const HEX_DIGITS: string = '0123456789ABCDEF';

/** One browser allowed to download. The reference keys these by address, and so do we. */
interface WebSession {
  /** The client address, doubled as the session id so a reload can re-fetch the list. */
  sessionId: string;
  ip: string;
  accepted: boolean;
}

/**
 * The web share: the Download API of spec sections 5.2 and 5.3 with the page a browser downloads
 * through, plus the upload page that turns browsers into senders of the normal upload API.
 *
 * The contract follows `packages/core/src/http/server/web.rs` request for request, because a browser
 * is the client and browsers are unforgiving about the shape: the session id is the client address,
 * `prepare-download` answers the whole offer as a fileId-keyed map, an unaccepted or foreign session
 * gets 403 rather than a file, and `download` replies with `application/octet-stream`, an
 * attachment disposition and the exact Content-Length.
 *
 * What the reference does with channels and drop guards, this does with one waiting slot and
 * explicit release points, because the phone's answer comes from a dialog the user may take a minute
 * over — and the browser that asked may be gone by then.
 */
export class WebShare {
  private config: WebShareConfig;
  private files: Map<string, WebOfferFile> = new Map<string, WebOfferFile>();
  /** Map iteration order is insertion order, but the offer needs a stable, indexable order. */
  private order: string[] = [];
  private sessions: Map<string, WebSession> = new Map<string, WebSession>();
  private pinGuard: PinGuard = new PinGuard();
  /** The one browser whose request the user has not answered yet; a second gets 409. */
  private waitingIp: string | null = null;
  private mode: WebShareMode = WebShareMode.IDLE;

  constructor(config: WebShareConfig) {
    this.config = config;
  }

  routes(): Map<string, RequestHandler> {
    const routes: Map<string, RequestHandler> = new Map<string, RequestHandler>();
    routes.set('/', this.indexHandler());
    routes.set(WEB_I18N_PATH, this.i18nHandler());
    routes.set(ApiPath.PREPARE_DOWNLOAD, this.prepareDownloadHandler());
    routes.set(ApiPath.DOWNLOAD, this.downloadHandler());
    return routes;
  }

  /** True while either page is live; the download flag wants the narrower {@link isDownloading}. */
  isSharing(): boolean {
    return this.mode !== WebShareMode.IDLE;
  }

  isDownloading(): boolean {
    return this.mode === WebShareMode.DOWNLOAD;
  }

  isUploading(): boolean {
    return this.mode === WebShareMode.UPLOAD;
  }

  offered(): WebOfferFile[] {
    const list: WebOfferFile[] = [];
    for (let i = 0; i < this.order.length; i++) {
      const file: WebOfferFile | undefined = this.files.get(this.order[i]);
      if (file !== undefined) {
        list.push(file);
      }
    }
    return list;
  }

  totalOffered(): number {
    let total: number = 0;
    for (let i = 0; i < this.order.length; i++) {
      const file: WebOfferFile | undefined = this.files.get(this.order[i]);
      if (file !== undefined) {
        total += file.size;
      }
    }
    return total;
  }

  /** Bytes handed to browsers during this share; the page shows it as a one-line receipt. */
  transferred(): number {
    let total: number = 0;
    for (let i = 0; i < this.order.length; i++) {
      const file: WebOfferFile | undefined = this.files.get(this.order[i]);
      if (file !== undefined) {
        total += file.downloaded;
      }
    }
    return total;
  }

  acceptedClients(): number {
    let count: number = 0;
    this.sessions.forEach((session: WebSession) => {
      if (session.accepted) {
        count++;
      }
    });
    return count;
  }

  /**
   * Offers `sources` to browsers and switches the server's web surface on.
   *
   * The list is snapshotted, not aliased to what the user picked: a file that becomes unreadable
   * mid-share must not silently vanish from an offer a browser is already quoting byte counts from.
   * Returns how many files were offered; a source the platform will not open is dropped, and an empty
   * result leaves the share off.
   */
  async share(sources: SendSource[]): Promise<number> {
    const files: Map<string, WebOfferFile> = new Map<string, WebOfferFile>();
    const order: string[] = [];
    for (let i = 0; i < sources.length; i++) {
      const source: SendSource = sources[i];
      try {
        const info: UriStat = await statUri(source.uri);
        const fileId: string = `w${order.length + 1}`;
        const file: WebOfferFile = {
          fileId: fileId,
          fileName: source.fileName,
          size: info.size,
          fileType: mimeTypeOf(source.fileName),
          uri: source.uri,
          modifiedMs: info.modifiedMs,
          downloaded: 0
        };
        files.set(fileId, file);
        order.push(fileId);
      } catch (e) {
        this.config.log(`网页传跳过读不到的文件 ${source.fileName}: ${describeFailure(e)}`);
      }
    }
    if (order.length === 0) {
      this.stop();
      return 0;
    }
    this.files = files;
    this.order = order;
    this.sessions.clear();
    this.pinGuard.reset();
    this.waitingIp = null;
    this.mode = WebShareMode.DOWNLOAD;
    this.config.log(`网页传: 开始分享 ${order.length} 个文件，共 ${this.totalOffered()} 字节`);
    this.config.onChanged();
    return order.length;
  }

  /**
   * Switches `/` to the upload page.
   *
   * Browsers then talk to the normal upload API that the receive path already serves, so nothing
   * needs offering here — but the modes are exclusive, because only one page can live at `/`.
   */
  acceptBrowserUploads(): void {
    this.files = new Map<string, WebOfferFile>();
    this.order = [];
    this.sessions.clear();
    this.pinGuard.reset();
    this.waitingIp = null;
    this.mode = WebShareMode.UPLOAD;
    this.config.log('网页传: 开始接收浏览器上传');
    this.config.onChanged();
  }

  /** Stops offering, forgets every browser that was allowed, and hands `/` back to the 403 page. */
  stop(): void {
    if (this.mode === WebShareMode.IDLE && this.order.length === 0) {
      return;
    }
    this.mode = WebShareMode.IDLE;
    this.files = new Map<string, WebOfferFile>();
    this.order = [];
    this.sessions.clear();
    this.pinGuard.reset();
    this.waitingIp = null;
    this.config.log('网页传: 已停止分享');
    this.config.onChanged();
  }

  /** Forgets state without logging; used when the server stops. */
  reset(): void {
    this.mode = WebShareMode.IDLE;
    this.files = new Map<string, WebOfferFile>();
    this.order = [];
    this.sessions.clear();
    this.pinGuard.reset();
    this.waitingIp = null;
  }

  // ------------------------------------------------------------------ web assets

  indexHandler(): RequestHandler {
    return async (exchange: Exchange): Promise<ServerReply> => {
      if (this.mode === WebShareMode.DOWNLOAD) {
        return replyWithHtml(Status.Ok, DOWNLOAD_PAGE);
      }
      if (this.mode === WebShareMode.UPLOAD) {
        return replyWithHtml(Status.Ok, UPLOAD_PAGE);
      }
      return replyWithHtml(Status.Forbidden, SHARING_OFF_PAGE);
    };
  }

  i18nHandler(): RequestHandler {
    return async (exchange: Exchange): Promise<ServerReply> => {
      const raw: string | undefined = exchange.request.headers.get('accept-language');
      const table: Map<string, string> = webText(raw === undefined ? '' : raw);
      const writer: JsonWriter = new JsonWriter();
      table.forEach((value: string, key: string) => {
        writer.putString(key, value);
      });
      return replyWithJson(Status.Ok, writer.build());
    };
  }

  // ------------------------------------------------------------- prepare-download

  prepareDownloadHandler(): RequestHandler {
    return async (exchange: Exchange): Promise<ServerReply> => {
      if (!this.isDownloading()) {
        return replyWithMessage(Status.Forbidden, 'Web download not initialized.');
      }
      const ip: string = exchange.peerHost;

      // An already allowed browser may reload the page and must not have to ask the user again.
      const asked: string | undefined = exchange.request.query.get('sessionId');
      if (asked !== undefined && this.isAccepted(asked, ip)) {
        return this.fileListResponse(asked);
      }

      const pinReply: ServerReply | null = this.checkPin(exchange);
      if (pinReply !== null) {
        return pinReply;
      }

      if (this.waitingIp !== null) {
        return replyWithMessage(Status.Conflict, 'Another request is waiting for the user');
      }

      const session: WebSession = { sessionId: ip, ip: ip, accepted: false };
      this.rememberSession(session);
      this.waitingIp = ip;
      const context: WebOfferContext = {
        clientIp: ip,
        userAgent: userAgentOf(exchange),
        fileCount: this.order.length,
        totalBytes: this.totalOffered()
      };
      const accepted: boolean = await this.decideOrHangUp(exchange, context);
      if (this.waitingIp === ip) {
        this.waitingIp = null;
      }
      const current: WebSession | undefined = this.sessions.get(ip);
      if (!accepted || !this.isDownloading() || current === undefined) {
        if (current !== undefined && !current.accepted) {
          this.sessions.delete(ip);
        }
        this.config.log(exchange.isCancelled()
          ? `网页传: ${ip} 断开了，请求作废`
          : `网页传: ${ip} 的下载请求未获批准`);
        // The sheet may still be on screen with nothing left to answer.
        this.config.onOfferClosed(ip);
        return replyWithMessage(Status.Forbidden, 'File transfer rejected.');
      }
      current.accepted = true;
      this.config.log(`网页传: 允许 ${ip} 下载 ${this.order.length} 个文件`);
      this.config.onChanged();
      return this.fileListResponse(ip);
    };
  }

  /**
   * Resolves with the user's answer, or false as soon as the browser hangs up.
   *
   * The reference has a request future to cancel; we have a dialog that stays on screen. Without this
   * poll a browser that gave up would leave the confirmation open and the waiting slot claimed.
   */
  private decideOrHangUp(exchange: Exchange, context: WebOfferContext): Promise<boolean> {
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      let settled: boolean = false;
      let timer: number = -1;
      const finish: (value: boolean) => void = (value: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer >= 0) {
          clearInterval(timer);
        }
        resolve(value);
      };
      timer = setInterval((): void => {
        if (exchange.isCancelled()) {
          finish(false);
        }
      }, HANGUP_POLL_MS);
      this.config.decide(context).then((value: boolean): void => {
        finish(value);
      }, (reason: Object): void => {
        this.config.log(`网页传确认失败: ${describeFailure(reason)}`);
        finish(false);
      });
    });
  }

  private fileListResponse(sessionId: string): ServerReply {
    const files: Map<string, WireFile> = new Map<string, WireFile>();
    for (let i = 0; i < this.order.length; i++) {
      const meta: WebOfferFile | undefined = this.files.get(this.order[i]);
      if (meta !== undefined) {
        files.set(meta.fileId, wireFileOf(meta));
      }
    }
    const info: WireDeviceInfo = this.config.self();
    const response: WirePrepareDownloadResponse = {
      info: Dto.infoResponseOf(info),
      sessionId: sessionId,
      files: files
    };
    return replyWithJson(Status.Ok, Dto.prepareDownloadResponseToJson(response));
  }

  // ---------------------------------------------------------------------- download

  downloadHandler(): RequestHandler {
    return async (exchange: Exchange): Promise<ServerReply> => {
      if (!this.isDownloading()) {
        return replyWithMessage(Status.Forbidden, 'Web download not initialized.');
      }
      const query: Map<string, string> = exchange.request.query;
      const sessionId: string | undefined = query.get('sessionId');
      if (sessionId === undefined || sessionId.length === 0) {
        return replyWithMessage(Status.BadRequest, 'Missing sessionId.');
      }
      if (!this.isAccepted(sessionId, exchange.peerHost)) {
        return replyWithMessage(Status.Forbidden, 'Invalid sessionId.');
      }
      const fileId: string | undefined = query.get('fileId');
      if (fileId === undefined || fileId.length === 0) {
        return replyWithMessage(Status.BadRequest, 'Missing fileId.');
      }
      const meta: WebOfferFile | undefined = this.files.get(fileId);
      if (meta === undefined) {
        return replyWithMessage(Status.Forbidden, 'Invalid fileId.');
      }

      // Opened before the answer is committed: a file that has gone must fail as a status code, not
      // as a response that promises Content-Length and then delivers nothing.
      let handle: fileIo.File;
      try {
        handle = await fileIo.open(meta.uri, fileIo.OpenMode.READ_ONLY);
      } catch (e) {
        this.config.log(`网页传无法打开 ${meta.fileName}: ${describeFailure(e)}`);
        return replyWithMessage(Status.InternalError, 'Failed to read file');
      }
      try {
        const now: fileIo.Stat = fileIo.statSync(handle.fd);
        if (now.size !== meta.size) {
          this.config.log(`网页传拒绝 ${meta.fileName}: 大小已从 ${meta.size} 变为 ${now.size}`);
          await fileIo.close(handle);
          return replyWithMessage(Status.InternalError, 'File changed after sharing');
        }
      } catch (e) {
        this.config.log(`网页传无法核对 ${meta.fileName}: ${describeFailure(e)}`);
        await fileIo.close(handle);
        return replyWithMessage(Status.InternalError, 'Failed to read file');
      }

      const headers: Map<string, string> = new Map<string, string>();
      headers.set('content-disposition', `attachment; filename="${attachmentName(meta.fileName)}"`);
      return replyWithStream(Status.Ok, 'application/octet-stream', meta.size, headers,
        this.fileProducer(meta, handle, exchange));
    };
  }

  /**
   * Streams the already open handle. The byte count is what Content-Length promised, so the loop stops
   * on a hang-up and reports the shortfall rather than writing on into a dead socket.
   */
  private fileProducer(file: WebOfferFile, handle: fileIo.File,
    exchange: Exchange): (sink: ChunkSink) => Promise<void> {
    return async (sink: ChunkSink): Promise<void> => {
      let sent: number = 0;
      try {
        const window: ArrayBuffer = new ArrayBuffer(DOWNLOAD_CHUNK);
        while (!exchange.isCancelled()) {
          const read: number = await fileIo.read(handle.fd, window);
          if (read <= 0) {
            break;
          }
          await sink.write(new Uint8Array(window, 0, read));
          sent += read;
        }
      } catch (e) {
        this.config.log(`网页传中断 ${file.fileName}: ${describeFailure(e)}`);
      } finally {
        try {
          await fileIo.close(handle);
        } catch (e) {
          // The transfer already decided the outcome.
        }
      }
      file.downloaded += sent;
      if (sent !== file.size) {
        this.config.log(`网页传: ${file.fileName} 只送出 ${sent}/${file.size} 字节`);
      } else {
        this.config.log(`网页传: ${file.fileName} 已下载完成 (${exchange.peerHost})`);
      }
      this.config.onChanged();
    };
  }

  // ----------------------------------------------------------------------- helpers

  private isAccepted(sessionId: string, ip: string): boolean {
    const session: WebSession | undefined = this.sessions.get(sessionId);
    return session !== undefined && session.accepted && session.ip === ip;
  }

  private rememberSession(session: WebSession): void {
    if (!this.sessions.has(session.sessionId) && this.sessions.size >= MAX_TRACKED_CLIENTS) {
      // Insertion order is the eviction order: the browser that has been quiet longest goes.
      const oldest: string | undefined = this.sessions.keys().next().value as string | undefined;
      if (oldest !== undefined) {
        this.sessions.delete(oldest);
      }
    }
    this.sessions.set(session.sessionId, session);
  }

  /**
   * The PIN gate of the reference web server, without its TLS exemption: a browser has no client
   * certificate, so under encryption as much as in plain HTTP the PIN is the only thing standing
   * between the LAN and the shared files.
   */
  private checkPin(exchange: Exchange): ServerReply | null {
    const required: string | null = this.config.pin();
    if (required === null) {
      return null;
    }
    const provided: string | undefined = exchange.request.query.get('pin');
    const result: PinResult = this.pinGuard.check(required, provided === undefined ? null : provided,
      exchange.peerHost);
    switch (result) {
      case PinResult.OK:
        return null;
      case PinResult.LOCKED:
        return replyWithMessage(Status.TooManyRequests, 'Too many requests');
      case PinResult.MISSING:
        return replyWithMessage(Status.Unauthorized, 'PIN required');
      default:
        return replyWithMessage(Status.Unauthorized, 'Invalid PIN');
    }
  }
}

function userAgentOf(exchange: Exchange): string {
  const raw: string | undefined = exchange.request.headers.get('user-agent');
  const text: string = raw === undefined ? '' : raw;
  return text.length > MAX_USER_AGENT ? text.substring(0, MAX_USER_AGENT) : text;
}

/** The offer as the wire wants it; `modified` is the ISO string the sender side also sends. */
function wireFileOf(file: WebOfferFile): WireFile {
  const entry: WireFile = {
    id: file.fileId,
    fileName: file.fileName,
    size: file.size,
    fileType: file.fileType
  };
  if (file.modifiedMs > 0) {
    const metadata: WireFileMetadata = { modified: new Date(file.modifiedMs).toISOString() };
    entry.metadata = metadata;
  }
  return entry;
}

/**
 * A file name for `Content-Disposition`.
 *
 * Directory separators become dashes so a shared `folder/name.txt` cannot make the browser build a
 * path, and everything outside the unreserved set is percent-encoded — including the UTF-8 bytes of a
 * Chinese name, which a header cannot carry raw.
 */
function attachmentName(raw: string): string {
  const bytes: Uint8Array = bytesFromUtf8(raw.split('/').join('-'));
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    const byte: number = bytes[i];
    if (isUnreserved(byte)) {
      out += String.fromCharCode(byte);
    } else {
      out += `%${HEX_DIGITS.charAt(byte >> 4)}${HEX_DIGITS.charAt(byte & 0x0f)}`;
    }
  }
  return out;
}

function isUnreserved(byte: number): boolean {
  if (byte >= 0x41 && byte <= 0x5a) {
    return true;
  }
  if (byte >= 0x61 && byte <= 0x7a) {
    return true;
  }
  if (byte >= 0x30 && byte <= 0x39) {
    return true;
  }
  if (byte < 0x80) {
    return UNRESERVED_PUNCT.indexOf(String.fromCharCode(byte)) >= 0;
  }
  return false;
}
