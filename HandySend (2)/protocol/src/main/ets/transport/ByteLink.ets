/**
 * Byte-level transport abstraction.
 *
 * The HTTP layer must not care whether it sits on a plain TCP socket or a TLS socket, nor whether
 * it is the dialing side or the accepted side, so all four HarmonyOS socket shapes are adapted to
 * one interface here.
 */

export type IpFamily = 'IPv4' | 'IPv6';

export interface PeerAddress {
  host: string;
  port: number;
  family: IpFamily;
  /** IPv6 scope id (interface index) — required to make a link-local address dialable again. */
  scopeId?: number;
}

export class TransportError extends Error {
  readonly code: number;

  constructor(message: string, code: number = -1) {
    super(message);
    this.name = 'TransportError';
    this.code = code;
  }
}

export interface ByteLink {
  /** Peer address, available once the link exists. Undefined until resolved for accepted sockets. */
  peer(): PeerAddress;

  /** Register the data callback. Data arrives as it is read from the socket, never buffered by us. */
  onData(callback: (chunk: Uint8Array) => void): void;

  onClosed(callback: () => void): void;

  send(data: Uint8Array): Promise<void>;

  close(): Promise<void>;

  /**
   * Uppercase hex SHA-256 of the peer's certificate DER, when the link is TLS and the peer
   * presented a certificate. LocalSend uses this as the device identity in encrypted mode.
   */
  peerCertFingerprint(): Promise<string | null>;

  isTls(): boolean;
}

/**
 * HarmonyOS socket `send` takes `string | ArrayBuffer`, so a Uint8Array view must be backed by an
 * exactly-sized buffer before it is handed over; a view into a larger buffer would send the tail too.
 */
export function tightBuffer(data: Uint8Array): ArrayBuffer {
  if (data.byteOffset === 0 && data.byteLength === data.buffer.byteLength) {
    return data.buffer as ArrayBuffer;
  }
  const copy: Uint8Array = new Uint8Array(data.byteLength);
  copy.set(data);
  return copy.buffer as ArrayBuffer;
}

/** Renders a peer address the way a URL authority must be written (IPv6 literals need brackets). */
export function formatAuthority(address: PeerAddress): string {
  const host: string = address.family === 'IPv6'
    ? `[${address.host}${address.scopeId !== undefined ? `%25${address.scopeId}` : ''}]`
    : address.host;
  return `${host}:${address.port}`;
}

export function parseAuthority(authority: string, defaultPort: number): PeerAddress {
  if (authority.startsWith('[')) {
    const closing: number = authority.indexOf(']');
    const hostPart: string = closing > 0 ? authority.substring(1, closing) : authority;
    const portPart: string = closing > 0 ? authority.substring(closing + 1) : '';
    const scopeIndex: number = hostPart.indexOf('%');
    const address: PeerAddress = {
      host: scopeIndex >= 0 ? hostPart.substring(0, scopeIndex) : hostPart,
      port: portPart.length > 1 ? Number.parseInt(portPart.substring(1), 10) : defaultPort,
      family: 'IPv6',
      scopeId: scopeIndex >= 0 ? Number.parseInt(hostPart.substring(scopeIndex + 1), 10) : undefined
    };
    return address;
  }
  const colon: number = authority.lastIndexOf(':');
  const address: PeerAddress = {
    host: colon > 0 ? authority.substring(0, colon) : authority,
    port: colon > 0 ? Number.parseInt(authority.substring(colon + 1), 10) : defaultPort,
    family: 'IPv4'
  };
  return address;
}
