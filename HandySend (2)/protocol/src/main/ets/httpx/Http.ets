import { PeerAddress } from '../transport/ByteLink';
import { util } from '@kit.ArkTS';

/** Protocol-level status codes the spec assigns meanings to; anything else is a generic failure. */
export enum Status {
  Ok = 200,
  NoContent = 204,
  BadRequest = 400,
  Unauthorized = 401,
  Forbidden = 403,
  Conflict = 409,
  UnprocessableEntity = 422,
  TooManyRequests = 429,
  InternalError = 500,
  ServiceUnavailable = 503
}

export function reasonPhrase(status: number): string {
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
    case Status.InternalError:
      return 'Internal Server Error';
    case Status.ServiceUnavailable:
      return 'Service Unavailable';
    default:
      return 'Unknown';
  }
}

export class HttpError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = 'HttpError';
    this.status = status;
  }
}

export interface HttpRequestHead {
  method: string;
  /** Raw target, i.e. `/api/localsend/v2/upload?sessionId=..&fileId=..&token=..`. */
  target: string;
  path: string;
  query: Map<string, string>;
  version: string;
  headers: Map<string, string>;
  keepAlive: boolean;
  contentLength: number;
  chunked: boolean;
}

export interface HttpResponseHead {
  version: string;
  status: number;
  reason: string;
  headers: Map<string, string>;
  keepAlive: boolean;
  contentLength: number;
  chunked: boolean;
}

const CRLF: string = '\r\n';

export function headerValue(headers: Map<string, string>, name: string): string | null {
  const value: string | undefined = headers.get(name.toLowerCase());
  return value === undefined ? null : value;
}

export function setHeader(headers: Map<string, string>, name: string, value: string): void {
  headers.set(name.toLowerCase(), value);
}

/**
 * Splits the request or response head off a byte buffer.
 *
 * Returns the byte length of the head including the terminating CRLFCRLF, or -1 when it is not
 * complete yet. Scanning is byte-wise because the head is ASCII by definition; decoding the whole
 * buffer as text would be both slower and wrong once body bytes start arriving.
 */
export function findHeadEnd(bytes: Uint8Array, from: number): number {
  let index: number = from;
  while (index + 3 < bytes.length) {
    if (bytes[index] === 0x0d && bytes[index + 1] === 0x0a && bytes[index + 2] === 0x0d && bytes[index + 3] === 0x0a) {
      return index + 4;
    }
    index++;
  }
  return -1;
}

export function decodeAscii(bytes: Uint8Array, from: number, to: number): string {
  const slice: Uint8Array = bytes.subarray(from, to);
  let out: string = '';
  for (let i = 0; i < slice.length; i++) {
    out += String.fromCharCode(slice[i]);
  }
  return out;
}

export function encodeUtf8(text: string): Uint8Array {
  return new util.TextEncoder('utf-8').encodeInto(text);
}

function addFoldedHeaders(headers: Map<string, string>, lines: string[], start: number): number {
  let index: number = start;
  while (index < lines.length) {
    const line: string = lines[index];
    if (line.length === 0) {
      index++;
      continue;
    }
    const colon: number = line.indexOf(':');
    if (colon <= 0) {
      index++;
      continue;
    }
    const name: string = line.substring(0, colon).trim().toLowerCase();
    let value: string = line.substring(colon + 1).trim();
    // Obsolete line folding (RFC 7230 3.2.4) is rare but free to accept.
    while (index + 1 < lines.length && (lines[index + 1].startsWith(' ') || lines[index + 1].startsWith('\t'))) {
      value += ` ${lines[index + 1].trim()}`;
      index++;
    }
    const previous: string | undefined = headers.get(name);
    headers.set(name, previous === undefined ? value : `${previous},${value}`);
    index++;
  }
  return index;
}

export function parseRequestHead(head: string): HttpRequestHead | null {
  const lines: string[] = head.split(CRLF);
  if (lines.length < 1) {
    return null;
  }
  const requestLine: string[] = lines[0].split(' ');
  if (requestLine.length < 3) {
    return null;
  }
  const headers: Map<string, string> = new Map<string, string>();
  addFoldedHeaders(headers, lines, 1);
  const target: string = requestLine[1];
  const queryIndex: number = target.indexOf('?');
  const path: string = queryIndex >= 0 ? target.substring(0, queryIndex) : target;
  const query: Map<string, string> = parseQueryString(queryIndex >= 0 ? target.substring(queryIndex + 1) : '');
  const version: string = requestLine[2];
  const connection: string | null = headerValue(headers, 'connection');
  const keepAlive: boolean = version.toUpperCase() === 'HTTP/1.1'
    ? !(connection !== null && connection.toLowerCase() === 'close')
    : connection !== null && connection.toLowerCase() === 'keep-alive';
  const contentLengthRaw: string | null = headerValue(headers, 'content-length');
  const transferEncoding: string | null = headerValue(headers, 'transfer-encoding');
  const request: HttpRequestHead = {
    method: requestLine[0].toUpperCase(),
    target: target,
    path: path,
    query: query,
    version: version,
    headers: headers,
    keepAlive: keepAlive,
    contentLength: contentLengthRaw === null ? -1 : Number.parseInt(contentLengthRaw, 10),
    chunked: transferEncoding !== null && transferEncoding.toLowerCase().indexOf('chunked') >= 0
  };
  return request;
}

export function parseResponseHead(head: string): HttpResponseHead | null {
  const lines: string[] = head.split(CRLF);
  if (lines.length < 1) {
    return null;
  }
  const statusLine: string[] = lines[0].split(' ');
  if (statusLine.length < 2) {
    return null;
  }
  const status: number = Number.parseInt(statusLine[1], 10);
  if (Number.isNaN(status)) {
    return null;
  }
  const headers: Map<string, string> = new Map<string, string>();
  addFoldedHeaders(headers, lines, 1);
  const connection: string | null = headerValue(headers, 'connection');
  const keepAlive: boolean = !(connection !== null && connection.toLowerCase() === 'close');
  const contentLengthRaw: string | null = headerValue(headers, 'content-length');
  const transferEncoding: string | null = headerValue(headers, 'transfer-encoding');
  const response: HttpResponseHead = {
    version: statusLine[0],
    status: status,
    reason: statusLine.length > 2 ? lines[0].substring(statusLine[0].length + statusLine[1].length + 2) : '',
    headers: headers,
    keepAlive: keepAlive,
    contentLength: contentLengthRaw === null ? -1 : Number.parseInt(contentLengthRaw, 10),
    chunked: transferEncoding !== null && transferEncoding.toLowerCase().indexOf('chunked') >= 0
  };
  return response;
}

export function parseQueryString(query: string): Map<string, string> {
  const out: Map<string, string> = new Map<string, string>();
  if (query.length === 0) {
    return out;
  }
  query.split('&').forEach((pair: string) => {
    if (pair.length === 0) {
      return;
    }
    const equals: number = pair.indexOf('=');
    const name: string = equals >= 0 ? pair.substring(0, equals) : pair;
    const value: string = equals >= 0 ? pair.substring(equals + 1) : '';
    out.set(safeDecode(name), safeDecode(value));
  });
  return out;
}

export function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value.replace(/\+/g, ' '));
  } catch (e) {
    return value;
  }
}

export function serializeHead(lines: string[]): Uint8Array {
  return encodeUtf8(`${lines.join(CRLF)}${CRLF}${CRLF}`);
}

/**
 * Body framing of an HTTP/1.1 message.
 *
 * `none` covers GET and every response without a payload; `fixed` covers Content-Length; `chunked`
 * covers streaming bodies. Chunked framing must be stripped before the bytes reach the file writer —
 * leaving the `<hex>\r\n` markers in the payload is the classic corruption bug in hand-rolled servers.
 */
export enum BodyFraming {
  NONE = 'none',
  FIXED = 'fixed',
  CHUNKED = 'chunked'
}

export function framingOf(contentLength: number, chunked: boolean): BodyFraming {
  if (chunked) {
    return BodyFraming.CHUNKED;
  }
  return contentLength > 0 ? BodyFraming.FIXED : BodyFraming.NONE;
}

export interface RequestContext {
  peer: PeerAddress;
  /** TLS peer certificate fingerprint when mutual authentication produced one. */
  peerCertFingerprint: string | null;
}
