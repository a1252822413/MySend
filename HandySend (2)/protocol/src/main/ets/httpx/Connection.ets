import { util } from '@kit.ArkTS';
import { ByteLink } from '../transport/ByteLink';
import { HttpRequestHead, Status, framingOf, parseRequestHead, setHeader } from './Http';
import { describeFailure } from '../util/Errors';
import { ByteQueue, bytesToAscii } from './Framing';
import {
  BodySource, ChunkSink, Exchange, RequestHandler, ServerReply, replyWithMessage
} from './Exchange';

const MAX_HEAD_BYTES: number = 64 * 1024;
const IDLE_TIMEOUT_MS: number = 45000;

enum Phase {
  /** Accumulating a request head. */
  HEAD = 'head',
  /** A handler is running and may be pulling body bytes. */
  HANDLING = 'handling',
  DONE = 'done'
}

/**
 * One HTTP/1.1 conversation over a ByteLink (TCP or TLS, dialed or accepted).
 *
 * LocalSend's upload endpoint needs the handler to start before the body has arrived — that is how
 * a receiver can answer 403 without downloading a file it will not accept — so head parsing,
 * body framing and handler execution are interleaved on a single serialized pump instead of
 * "read everything, then dispatch".
 */
export class HttpConnection {
  private link: ByteLink;
  private routes: Map<string, RequestHandler>;
  private head: ByteQueue = new ByteQueue();
  private body: BodySource | null = null;
  private phase: Phase = Phase.HEAD;
  private pumping: boolean = false;
  private rerunRequested: boolean = false;
  private closed: boolean = false;
  private idleTimer: number = -1;
  private onFinished: ((connection: HttpConnection) => void) | null = null;
  private log: (message: string) => void;

  constructor(link: ByteLink, routes: Map<string, RequestHandler>, log: (message: string) => void) {
    this.link = link;
    this.routes = routes;
    this.log = log;
  }

  setOnFinished(callback: (connection: HttpConnection) => void): void {
    this.onFinished = callback;
  }

  start(): void {
    this.link.onData((chunk: Uint8Array) => {
      this.onBytes(chunk);
    });
    this.link.onClosed(() => {
      this.onSocketClosed();
    });
    this.armIdleTimer();
    this.pump();
  }

  get peerHost(): string {
    return this.link.peer().host;
  }

  close(reason: string): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.phase = Phase.DONE;
    this.clearIdleTimer();
    if (this.body !== null) {
      this.body.abort(reason);
    }
    this.link.close();
    if (this.onFinished !== null) {
      this.onFinished(this);
    }
  }

  private onBytes(chunk: Uint8Array): void {
    this.armIdleTimer();
    if (this.closed) {
      return;
    }
    if (this.phase === Phase.HEAD) {
      this.head.append(chunk);
      this.pump();
      return;
    }
    if (this.body !== null) {
      this.body.append(chunk);
      this.body.signalDataArrived();
    }
  }

  private onSocketClosed(): void {
    if (this.body !== null) {
      // A client that hangs up mid-body must make the handler fail, not stall forever.
      this.body.abort('connection closed by peer');
    }
    this.close('peer closed');
  }

  private armIdleTimer(): void {
    this.clearIdleTimer();
    if (this.closed) {
      return;
    }
    if (this.phase === Phase.HANDLING && (this.body === null || this.body.isFinished())) {
      // Nothing more can arrive on this socket while the handler works, and a handler may work for as
      // long as the user takes over a confirmation dialog. Silence here does not mean the peer is gone
      // — that case reports itself through `onSocketClosed` — so the idle clock stays off.
      return;
    }
    this.idleTimer = setTimeout(() => {
      this.close('idle timeout');
    }, IDLE_TIMEOUT_MS);
  }

  private clearIdleTimer(): void {
    if (this.idleTimer >= 0) {
      clearTimeout(this.idleTimer);
      this.idleTimer = -1;
    }
  }

  /** Serializes pumps so two socket reads can never interleave inside one request. */
  private pump(): void {
    if (this.pumping) {
      this.rerunRequested = true;
      return;
    }
    this.pumping = true;
    this.pumpLoop().finally(() => {
      this.pumping = false;
      if (this.rerunRequested && !this.closed) {
        this.rerunRequested = false;
        this.pump();
      }
    });
  }

  private async pumpLoop(): Promise<void> {
    while (!this.closed) {
      if (this.phase !== Phase.HEAD) {
        return;
      }
      const headEnd: number = this.head.indexOfDoubleCrlf();
      if (headEnd < 0) {
        if (this.head.size > MAX_HEAD_BYTES) {
          await this.failRequest(Status.BadRequest, 'Header too large');
          return;
        }
        return;
      }
      const headBytes: Uint8Array | null = this.head.take(headEnd - 4);
      this.head.take(4);
      if (headBytes === null) {
        return;
      }
      const request: HttpRequestHead | null = parseRequestHead(bytesToAscii(headBytes));
      if (request === null) {
        await this.failRequest(Status.BadRequest, 'Malformed request line');
        return;
      }
      const body: BodySource = new BodySource(framingOf(request.contentLength, request.chunked), request.contentLength);
      this.body = body;
      // Whatever arrived after the head already belongs to the body.
      const carried: Uint8Array | null = this.head.take(this.head.size);
      if (carried !== null && carried.length > 0) {
        body.append(carried);
        body.signalDataArrived();
      }
      if (request.path.length === 0 || request.path.charAt(0) !== '/') {
        await this.failRequest(Status.BadRequest, 'Invalid request target');
        return;
      }
      this.phase = Phase.HANDLING;
      // The clock that was armed while the head arrived must be re-decided now: a handler that has
      // nothing left to read can take as long as the user needs, and a stale timer would cut it off.
      this.armIdleTimer();
      await this.handle(request, body);
      if (this.closed) {
        return;
      }
      // Reset for the next pipelined/keep-alive request.
      this.head.clear();
      this.body = null;
      this.phase = Phase.HEAD;
      // The handler is over, so the connection is genuinely idle now and the clock starts again.
      this.armIdleTimer();
    }
  }

  private async handle(request: HttpRequestHead, body: BodySource): Promise<void> {
    const handler: RequestHandler | undefined = this.routes.get(request.path);
    if (handler === undefined) {
      await this.failRequest(Status.Forbidden, 'Unknown endpoint');
      return;
    }
    const fingerprint: string | null = await this.link.peerCertFingerprint();
    const exchange: Exchange = new Exchange(request, body, this.link.peer().host, fingerprint,
      (): boolean => this.closed);
    let reply: ServerReply;
    try {
      reply = await handler(exchange);
    } catch (e) {
      this.log(`handler ${request.path} threw: ${describeFailure(e)}`);
      await this.failRequest(Status.InternalError, 'Internal error');
      return;
    }
    const drained: boolean = body.isFinished();
    await this.writeReply(reply, request.keepAlive && drained && reply.stream === null);
    if (!drained) {
      // An undrained request body cannot be reused safely on a keep-alive connection.
      this.close('body not drained');
    }
  }

  private async failRequest(status: number, message: string): Promise<void> {
    const reply: ServerReply = replyWithMessage(status, message);
    await this.writeReply(reply, false);
    this.close(`failed with ${status}`);
  }

  private async writeReply(reply: ServerReply, keepAlive: boolean): Promise<void> {
    const headers: Map<string, string> = reply.headers;
    const length: number = reply.body !== null ? reply.body.length : (reply.stream !== null ? reply.contentLength : 0);
    const sendBody: boolean = reply.status !== Status.NoContent && reply.status !== 304;
    if (sendBody) {
      setHeader(headers, 'content-length', `${length}`);
    } else {
      headers.delete('content-length');
    }
    setHeader(headers, 'connection', keepAlive ? 'keep-alive' : 'close');
    const lines: string[] = [`HTTP/1.1 ${reply.status} ${reasonOf(reply.status)}`];
    headers.forEach((value: string, key: string) => {
      lines.push(`${key}: ${value}`);
    });
    const head: Uint8Array = bytesToAsciiHead(lines);
    try {
      await this.link.send(head);
      if (sendBody && reply.body !== null && reply.body.length > 0) {
        await this.link.send(reply.body);
      }
    } catch (e) {
      this.close(`write failed: ${describeFailure(e)}`);
    }
    if (sendBody && reply.stream !== null) {
      // Run even after a failed head write: a producer that holds a file open must reach its own
      // cleanup, and the first write to the closed link is what releases it.
      try {
        await reply.stream(new ChunkSink(this.link));
      } catch (e) {
        this.close(`stream write failed: ${describeFailure(e)}`);
      }
    }
    if (!keepAlive) {
      this.close('response complete, closing');
    }
  }
}

function reasonOf(status: number): string {
  switch (status) {
    case Status.Ok:
      return 'OK';
    case Status.NoContent:
      return 'No Content';
    case Status.BadRequest:
      return 'Bad Request';
    case Status.Unauthorized:
      return 'Unauthorized';
    case Status.Forbidden:
      return 'Forbidden';
    case Status.Conflict:
      return 'Conflict';
    case Status.UnprocessableEntity:
      return 'Unprocessable Entity';
    case Status.TooManyRequests:
      return 'Too Many Requests';
    default:
      return 'Internal Server Error';
  }
}

function bytesToAsciiHead(lines: string[]): Uint8Array {
  const text: string = `${lines.join('\r\n')}\r\n\r\n`;
  return new util.TextEncoder('utf-8').encodeInto(text);
}

