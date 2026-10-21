import { util } from '@kit.ArkTS';
import { ByteLink, PeerAddress, formatAuthority } from '../transport/ByteLink';
import { connectTcp, connectTls, ClientCredentials } from '../transport/DialedLinks';
import { ProtocolScheme } from '../wire/Constants';
import { HttpResponseHead, Status, framingOf, parseResponseHead, setHeader } from './Http';
import { describeFailure } from '../util/Errors';
import { BodyDecoder, ByteQueue, bytesToAscii } from './Framing';

const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
const MAX_RESPONSE_HEAD: number = 64 * 1024;

export interface JsonResponse {
  status: number;
  body: string;
  /** Socket peer of the responder, used to confirm which device answered. */
  peerHost: string;
  peerCertFingerprint: string | null;
}

export interface Target {
  host: string;
  port: number;
  scheme: ProtocolScheme;
  family?: string;
  scopeId?: number;
}

export class SendProgress {
  /** Bytes handed to the socket so far. */
  sent: number = 0;
  readonly total: number;
  private readonly cancelledCheck: () => boolean;

  constructor(total: number, cancelledCheck: () => boolean) {
    this.total = total;
    this.cancelledCheck = cancelledCheck;
  }

  isCancelled(): boolean {
    return this.cancelledCheck();
  }
}

export interface UploadResult {
  status: number;
  body: string;
  /** True when the local side aborted the body, which is distinct from a peer rejection. */
  cancelledLocally: boolean;
}

export interface DownloadResult {
  status: number;
  body: string;
  bytes: number;
}

function toPeer(target: Target): PeerAddress {
  const peer: PeerAddress = {
    host: target.host,
    port: target.port,
    family: target.family === 'IPv6' ? 'IPv6' : 'IPv4',
    scopeId: target.scopeId
  };
  return peer;
}

async function dial(target: Target, credentials: ClientCredentials | null, timeoutMs: number): Promise<ByteLink> {
  const peer: PeerAddress = toPeer(target);
  if (target.scheme === ProtocolScheme.HTTPS) {
    return await connectTls(peer, credentials, timeoutMs);
  }
  return await connectTcp(peer, timeoutMs);
}

function buildRequestHead(method: string, path: string, query: Map<string, string>, headers: Map<string, string>): Uint8Array {
  const lines: string[] = [`${method} ${queryString(path, query)} HTTP/1.1`];
  headers.forEach((value: string, key: string) => {
    lines.push(`${key}: ${value}`);
  });
  const text: string = `${lines.join('\r\n')}\r\n\r\n`;
  return new util.TextEncoder('utf-8').encodeInto(text);
}

export function queryString(path: string, query: Map<string, string>): string {
  if (query.size === 0) {
    return path;
  }
  let out: string = `${path}?`;
  let first: boolean = true;
  query.forEach((value: string, key: string) => {
    if (!first) {
      out += '&';
    }
    out += `${encodeURIComponent(key)}=${encodeURIComponent(value)}`;
    first = false;
  });
  return out;
}

/**
 * Reads a response head out of a link's byte stream.
 *
 * Sockets deliver arbitrary chunk boundaries, so bytes that belong to the body stay in the queue
 * instead of being discarded or re-requested.
 */
class ResponseReader {
  private queue: ByteQueue = new ByteQueue();
  private link: ByteLink;
  private waiter: (() => void) | null = null;
  private ended: boolean = false;
  private head: HttpResponseHead | null = null;
  private decoder: BodyDecoder | null = null;

  constructor(link: ByteLink) {
    this.link = link;
    link.onData((chunk: Uint8Array) => {
      this.queue.append(chunk);
      this.wake();
    });
    link.onClosed(() => {
      this.ended = true;
      this.wake();
    });
  }

  private wake(): void {
    const waiter: (() => void) | null = this.waiter;
    this.waiter = null;
    if (waiter !== null) {
      waiter();
    }
  }

  private waitForByte(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      this.waiter = resolve;
    });
  }

  async readHead(): Promise<HttpResponseHead | null> {
    while (true) {
      const end: number = this.queue.indexOfDoubleCrlf();
      if (end >= 0) {
        const headBytes: Uint8Array | null = this.queue.take(end - 4);
        this.queue.take(4);
        const parsed: HttpResponseHead | null = headBytes === null ? null : parseResponseHead(bytesToAscii(headBytes));
        this.head = parsed;
        if (parsed !== null) {
          this.decoder = new BodyDecoder(framingOf(parsed.contentLength, parsed.chunked), parsed.contentLength);
        }
        return parsed;
      }
      if (this.ended || this.queue.size > MAX_RESPONSE_HEAD) {
        return null;
      }
      await this.waitForByte();
    }
  }

  /** Reads one body chunk; null when the body is complete (including a close-delimited body). */
  async readBodyChunk(maxBytes: number): Promise<Uint8Array | null> {
    if (this.head === null || this.decoder === null) {
      return null;
    }
    while (true) {
      const chunk: Uint8Array | null = this.decoder.read(this.queue, maxBytes);
      if (chunk !== null && chunk.length > 0) {
        return chunk;
      }
      if (this.decoder.isFinished()) {
        return null;
      }
      if (this.decoder.isFailed() || this.ended) {
        return null;
      }
      await this.waitForByte();
    }
  }

  async readWholeBody(limit: number): Promise<Uint8Array> {
    const parts: Uint8Array[] = [];
    let total: number = 0;
    while (true) {
      const chunk: Uint8Array | null = await this.readBodyChunk(64 * 1024);
      if (chunk === null) {
        break;
      }
      parts.push(chunk);
      total += chunk.length;
      if (total > limit) {
        break;
      }
    }
    const out: Uint8Array = new Uint8Array(total);
    let offset: number = 0;
    parts.forEach((part: Uint8Array) => {
      out.set(part, offset);
      offset += part.length;
    });
    return out;
  }

  bodyIsComplete(): boolean {
    return this.decoder === null || this.decoder.isFinished();
  }
}

export interface RequestSpec {
  target: Target;
  method: string;
  path: string;
  query: Map<string, string>;
  /** JSON payload for the small endpoints; mutually exclusive with a streaming body. */
  json?: string;
  credentials?: ClientCredentials | null;
  timeoutMs?: number;
  log?: (message: string) => void;
}

/** Streaming body for uploads: the producer must stop promptly once `isCancelled` turns true. */
export interface StreamingBody {
  length: number;
  produce: (progress: SendProgress, write: (bytes: Uint8Array) => Promise<void>) => Promise<void>;
}

export class HttpClient {
  /**
   * Small JSON endpoints: /register, /info, /prepare-upload, /cancel, /prepare-download.
   */
  static async requestJson(spec: RequestSpec): Promise<JsonResponse> {
    const timeout: number = spec.timeoutMs ?? 5000;
    const link: ByteLink = await dial(spec.target, spec.credentials ?? null, timeout);
    try {
      const headers: Map<string, string> = new Map<string, string>();
      headers.set('host', formatAuthority(toPeer(spec.target)));
      headers.set('connection', 'close');
      headers.set('accept', 'application/json');
      const body: Uint8Array | null = spec.json === undefined ? null : new util.TextEncoder('utf-8').encodeInto(spec.json);
      if (body !== null) {
        setHeader(headers, 'content-type', 'application/json; charset=utf-8');
        setHeader(headers, 'content-length', `${body.length}`);
      }
      const reader: ResponseReader = new ResponseReader(link);
      await link.send(buildRequestHead(spec.method, spec.path, spec.query, headers));
      if (body !== null) {
        await link.send(body);
      }
      const head: HttpResponseHead | null = await reader.readHead();
      if (head === null) {
        throw new Error(`no response from ${spec.target.host}${spec.path}`);
      }
      const raw: Uint8Array = await reader.readWholeBody(1024 * 1024);
      const response: JsonResponse = {
        status: head.status,
        body: raw.length === 0 ? '' : decoder.decodeToString(raw),
        peerHost: link.peer().host,
        peerCertFingerprint: await link.peerCertFingerprint()
      };
      return response;
    } finally {
      await link.close();
    }
  }

  /**
   * POST /upload with a streamed body.
   *
   * The body is framed with Content-Length rather than chunked transfer encoding: the file size is
   * always known from the metadata the receiver already accepted, and peers that do content-length
   * based checksum verification must not have to de-frame chunks.
   */
  static async upload(spec: RequestSpec, body: StreamingBody, onSent: (sent: number, total: number) => void,
    isCancelled: () => boolean): Promise<UploadResult> {
    const timeout: number = spec.timeoutMs ?? 20000;
    const link: ByteLink = await dial(spec.target, spec.credentials ?? null, timeout);
    let cancelledByPeer: boolean = false;
    let peerReplied: boolean = false;
    let written: number = 0;
    try {
      const headers: Map<string, string> = new Map<string, string>();
      headers.set('host', formatAuthority(toPeer(spec.target)));
      headers.set('content-type', 'application/octet-stream');
      headers.set('content-length', `${body.length}`);
      const reader: ResponseReader = new ResponseReader(link);
      await link.send(buildRequestHead(spec.method, spec.path, spec.query, headers));

      const producer: Promise<void> = body.produce(
        new SendProgress(body.length, (): boolean => isCancelled() || cancelledByPeer || peerReplied),
        async (bytes: Uint8Array): Promise<void> => {
          await link.send(bytes);
          // Progress is reported here rather than by the producer: this is the point where bytes
          // actually leave, so a producer that buffers cannot report a transfer ahead of itself.
          written += bytes.length;
          onSent(written, body.length);
        }
      );

      // Read the answer concurrently: a receiver may reject before the body finishes arriving.
      const head: HttpResponseHead | null = await reader.readHead();
      if (head === null) {
        cancelledByPeer = true;
        await producer.catch(() => {
        });
        await link.close();
        const result: UploadResult = { status: 0, body: '', cancelledLocally: isCancelled() };
        return result;
      }
      peerReplied = true;
      const early: boolean = head.status !== Status.Ok && !isCancelled();
      if (early) {
        // The receiver will not read the rest of the body; stop feeding it, then drain the response.
        cancelledByPeer = true;
      }
      await producer.catch((reason: Object) => {
        (spec.log ?? ((message: string): void => undefined))(`upload producer stopped: ${describeFailure(reason)}`);
      });
      const raw: Uint8Array = await reader.readWholeBody(256 * 1024);
      const response: UploadResult = {
        status: head.status,
        body: raw.length === 0 ? '' : decoder.decodeToString(raw),
        cancelledLocally: isCancelled()
      };
      return response;
    } finally {
      await link.close();
    }
  }

  /** GET /download and web-page fetches: streams the response body into `onChunk`. */
  static async download(spec: RequestSpec, onChunk: (bytes: Uint8Array) => Promise<void>,
    isCancelled: () => boolean): Promise<DownloadResult> {
    const timeout: number = spec.timeoutMs ?? 20000;
    const link: ByteLink = await dial(spec.target, spec.credentials ?? null, timeout);
    try {
      const headers: Map<string, string> = new Map<string, string>();
      headers.set('host', formatAuthority(toPeer(spec.target)));
      headers.set('connection', 'close');
      const reader: ResponseReader = new ResponseReader(link);
      await link.send(buildRequestHead('GET', spec.path, spec.query, headers));
      const head: HttpResponseHead | null = await reader.readHead();
      if (head === null) {
        const empty: DownloadResult = { status: 0, body: '', bytes: 0 };
        return empty;
      }
      if (head.status !== Status.Ok) {
        const raw: Uint8Array = await reader.readWholeBody(256 * 1024);
        const failure: DownloadResult = {
          status: head.status,
          body: raw.length === 0 ? '' : decoder.decodeToString(raw),
          bytes: 0
        };
        return failure;
      }
      let bytes: number = 0;
      while (true) {
        if (isCancelled()) {
          break;
        }
        const chunk: Uint8Array | null = await reader.readBodyChunk(64 * 1024);
        if (chunk === null) {
          break;
        }
        bytes += chunk.length;
        await onChunk(chunk);
      }
      const result: DownloadResult = { status: bytes > 0 || head.status === Status.Ok ? head.status : 0, body: '', bytes: bytes };
      return result;
    } finally {
      await link.close();
    }
  }
}
