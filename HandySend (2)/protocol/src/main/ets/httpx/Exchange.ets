import { util } from '@kit.ArkTS';
import { ByteLink } from '../transport/ByteLink';
import { concatBytes } from '../util/ByteBuffers';
import { BodyFraming, HttpRequestHead } from './Http';
import { BodyDecoder, ByteQueue } from './Framing';

/**
 * Pull-based view of a message body.
 *
 * Socket data arrives asynchronously while handlers read on demand, so the two sides meet in a
 * queue and a single waiter. `read` returns payload bytes, or null at end of body; a truncated or
 * aborted connection surfaces as an error rather than a silent short read.
 */
export class BodySource {
  private queue: ByteQueue = new ByteQueue();
  private decoder: BodyDecoder;
  private waiter: (() => void) | null = null;
  private aborted: boolean = false;
  private abortReason: string = '';
  readonly highWaterMark: number;
  private overflowBytes: number = 0;

  constructor(framing: BodyFraming, contentLength: number, highWaterMark: number = 32 * 1024 * 1024) {
    this.decoder = new BodyDecoder(framing, contentLength);
    this.highWaterMark = highWaterMark;
  }

  /** Called by the connection after appending socket bytes, and again on close. */
  signalDataArrived(): void {
    this.wake();
  }

  abort(reason: string): void {
    this.aborted = true;
    this.abortReason = reason;
    this.wake();
  }

  bytesReceived: number = 0;

  append(chunk: Uint8Array): void {
    this.queue.append(chunk);
    this.overflowBytes += chunk.length;
    if (this.queue.size > this.highWaterMark) {
      // A handler that cannot keep up must not be able to exhaust the device's memory.
      this.abort('body queue exceeded high water mark');
    }
  }

  private wake(): void {
    const waiter: (() => void) | null = this.waiter;
    this.waiter = null;
    if (waiter !== null) {
      waiter();
    }
  }

  private waitForData(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      this.waiter = resolve;
    });
  }

  async read(maxBytes: number): Promise<Uint8Array | null> {
    while (true) {
      const chunk: Uint8Array | null = this.decoder.read(this.queue, maxBytes);
      if (chunk !== null && chunk.length > 0) {
        this.bytesReceived += chunk.length;
        return chunk;
      }
      if (this.decoder.isFailed()) {
        this.abort('malformed body framing');
      }
      if (this.decoder.isFinished()) {
        return null;
      }
      if (this.aborted) {
        throw new Error(this.abortReason);
      }
      await this.waitForData();
      if (this.aborted && !this.decoder.isFinished()) {
        throw new Error(this.abortReason);
      }
    }
  }

  isFinished(): boolean {
    return this.decoder.isFinished();
  }

  /**
   * The whole body, or null when it is missing, malformed or larger than `maxBytes`.
   *
   * A single `read` hands back whatever has arrived so far, so a caller that wants the complete
   * message — which is every JSON endpoint — must keep reading until the framing says it is done.
   */
  async readAll(maxBytes: number): Promise<Uint8Array | null> {
    const parts: Uint8Array[] = [];
    let total: number = 0;
    for (;;) {
      let chunk: Uint8Array | null;
      try {
        chunk = await this.read(64 * 1024);
      } catch (e) {
        return null;
      }
      if (chunk === null) {
        break;
      }
      parts.push(chunk);
      total += chunk.length;
      if (total > maxBytes) {
        return null;
      }
    }
    return total === 0 ? null : concatBytes(parts);
  }
}

export class ChunkSink {
  private link: ByteLink;

  constructor(link: ByteLink) {
    this.link = link;
  }

  async write(bytes: Uint8Array): Promise<void> {
    await this.link.send(bytes);
  }
}

/** Reply produced by a route handler; either a fixed body or a streamed one. */
export interface ServerReply {
  status: number;
  headers: Map<string, string>;
  body: Uint8Array | null;
  /** When set, `contentLength` must be known so the peer can verify the transfer. */
  stream: ((sink: ChunkSink) => Promise<void>) | null;
  contentLength: number;
}

export class Exchange {
  readonly request: HttpRequestHead;
  readonly body: BodySource;
  /** Socket peer address, which LocalSend uses for session affinity and IP checks. */
  readonly peerHost: string;
  readonly peerCertFingerprint: string | null;
  private readonly closedCheck: () => boolean;

  constructor(request: HttpRequestHead, body: BodySource, peerHost: string,
    peerCertFingerprint: string | null, closedCheck: () => boolean) {
    this.request = request;
    this.body = body;
    this.peerHost = peerHost;
    this.peerCertFingerprint = peerCertFingerprint;
    this.closedCheck = closedCheck;
  }

  /** True once the client hung up or the connection was closed, so handlers can stop reading. */
  isCancelled(): boolean {
    return this.closedCheck();
  }
}

export type RequestHandler = (exchange: Exchange) => Promise<ServerReply>;

export function replyWithJson(status: number, json: string): ServerReply {
  const headers: Map<string, string> = new Map<string, string>();
  headers.set('content-type', 'application/json; charset=utf-8');
  const body: Uint8Array = bytesFromUtf8(json);
  return { status: status, headers: headers, body: body, stream: null, contentLength: body.length };
}

export function replyWithMessage(status: number, message: string): ServerReply {
  const payload: string = message.length === 0 ? '{}' : `{"message":${JSON.stringify(message)}}`;
  return replyWithJson(status, payload);
}

export function replyEmpty(status: number): ServerReply {
  const headers: Map<string, string> = new Map<string, string>();
  return { status: status, headers: headers, body: null, stream: null, contentLength: 0 };
}

export function replyWithHtml(status: number, html: string): ServerReply {
  const headers: Map<string, string> = new Map<string, string>();
  headers.set('content-type', 'text/html; charset=utf-8');
  const body: Uint8Array = bytesFromUtf8(html);
  return { status: status, headers: headers, body: body, stream: null, contentLength: body.length };
}

/**
 * Streams a body whose size is known up front.
 *
 * The download endpoint uses this so the browser gets Content-Length rather than chunked framing:
 * a truncation must be visible as a short body, not hidden inside a well-formed chunk stream.
 * `extra` carries endpoint-specific headers such as Content-Disposition.
 */
export function replyWithStream(status: number, contentType: string, length: number,
  extra: Map<string, string> | null, producer: (sink: ChunkSink) => Promise<void>): ServerReply {
  const headers: Map<string, string> = new Map<string, string>();
  headers.set('content-type', contentType);
  if (extra !== null) {
    extra.forEach((value: string, key: string) => {
      headers.set(key, value);
    });
  }
  return { status: status, headers: headers, body: null, stream: producer, contentLength: length };
}

const utf8Decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

export function bytesFromUtf8(text: string): Uint8Array {
  return new util.TextEncoder('utf-8').encodeInto(text);
}

export function utf8FromBytes(bytes: Uint8Array): string {
  return utf8Decoder.decodeToString(bytes);
}
