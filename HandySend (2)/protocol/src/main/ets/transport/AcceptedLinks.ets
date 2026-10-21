import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteLink, IpFamily, PeerAddress, TransportError, tightBuffer } from './ByteLink';
import { sha256Hex } from '../util/Digest';

type DataCallback = (chunk: Uint8Array) => void;

/** How long to wait for a client certificate that may never arrive. */
const CERT_WAIT_MS: number = 3000;
/** Bytes an accepted socket may hand over before the HTTP layer starts listening on it. */
const PENDING_LIMIT: number = 16 * 1024 * 1024;

/**
 * Shared plumbing for the four HarmonyOS socket shapes. Subclasses only map send/close/peer
 * resolution onto their concrete socket object; event fan-out lives here.
 */
abstract class SocketByteLink implements ByteLink {
  protected peerAddress: PeerAddress;
  protected dataCallback: DataCallback | null = null;
  protected closedCallback: (() => void) | null = null;
  protected closed: boolean = false;
  private pending: Uint8Array[] = [];
  private pendingBytes: number = 0;
  private tls: boolean;

  constructor(peerAddress: PeerAddress, tls: boolean) {
    this.peerAddress = peerAddress;
    this.tls = tls;
  }

  peer(): PeerAddress {
    return this.peerAddress;
  }

  /** Filled in after the accept-time address lookup finishes; data is already flowing by then. */
  updatePeer(peer: PeerAddress): void {
    this.peerAddress = peer;
  }

  isTls(): boolean {
    return this.tls;
  }

  onData(callback: DataCallback): void {
    this.dataCallback = callback;
    const buffered: Uint8Array[] = this.pending;
    this.pending = [];
    this.pendingBytes = 0;
    for (let i = 0; i < buffered.length; i++) {
      callback(buffered[i]);
    }
  }

  onClosed(callback: () => void): void {
    this.closedCallback = callback;
  }

  protected handleChunk(message: ArrayBuffer): void {
    const raw: Object = message as Object;
    const view: Uint8Array = raw instanceof Uint8Array ? raw as Uint8Array : new Uint8Array(message);
    const copy: Uint8Array = new Uint8Array(view.length);
    copy.set(view);
    if (this.dataCallback !== null) {
      this.dataCallback(copy);
      return;
    }
    // The HTTP layer attaches a moment after the socket is accepted, so keep the bytes it has not
    // claimed yet. Dropping them would silently corrupt the start of the request.
    if (this.pendingBytes + copy.length > PENDING_LIMIT) {
      this.close();
      return;
    }
    this.pending.push(copy);
    this.pendingBytes += copy.length;
  }

  protected handleClosed(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    if (this.closedCallback !== null) {
      this.closedCallback();
    }
  }

  async peerCertFingerprint(): Promise<string | null> {
    return null;
  }

  abstract send(data: Uint8Array): Promise<void>;

  abstract close(): Promise<void>;
}

function familyOf(raw: number | undefined): IpFamily {
  // NetAddress.family is 1 for IPv4 and 2 for IPv6.
  return raw === 2 ? 'IPv6' : 'IPv4';
}

/** Placeholder peer for a link that starts receiving before its address lookup resolves. */
export function unknownPeer(): PeerAddress {
  const peer: PeerAddress = { host: '', port: 0, family: 'IPv4' };
  return peer;
}

export class TcpAcceptedLink extends SocketByteLink {
  private conn: socket.TCPSocketConnection;

  constructor(conn: socket.TCPSocketConnection, peer: PeerAddress) {
    super(peer, false);
    this.conn = conn;
    conn.on('message', (info: socket.SocketMessageInfo) => {
      this.handleChunk(info.message);
    });
    conn.on('close', () => {
      this.handleClosed();
    });
  }

  async send(data: Uint8Array): Promise<void> {
    try {
      const options: socket.TCPSendOptions = { data: tightBuffer(data) };
      await this.conn.send(options);
    } catch (e) {
      const error: BusinessError = e as BusinessError;
      throw new TransportError(`tcp send failed: ${error.message}`, error.code);
    }
  }

  async close(): Promise<void> {
    try {
      await this.conn.close();
    } catch (e) {
      // A socket that is already gone is not an error for our state machine.
    }
    this.handleClosed();
  }
}

export class TlsAcceptedLink extends SocketByteLink {
  private conn: socket.TLSSocketConnection;
  /** Read once at accept time: a connection's peer certificate cannot change underneath it. */
  private certFingerprint: string | null;

  constructor(conn: socket.TLSSocketConnection, peer: PeerAddress, certFingerprint: string | null) {
    super(peer, true);
    this.conn = conn;
    this.certFingerprint = certFingerprint;
    conn.on('message', (info: socket.SocketMessageInfo) => {
      this.handleChunk(info.message);
    });
    conn.on('close', () => {
      this.handleClosed();
    });
  }

  setCertFingerprint(value: string | null): void {
    this.certFingerprint = value;
  }

  async send(data: Uint8Array): Promise<void> {
    try {
      await this.conn.send(tightBuffer(data));
    } catch (e) {
      const error: BusinessError = e as BusinessError;
      throw new TransportError(`tls send failed: ${error.message}`, error.code);
    }
  }

  async close(): Promise<void> {
    try {
      await this.conn.close();
    } catch (e) {
    }
    this.handleClosed();
  }

  async peerCertFingerprint(): Promise<string | null> {
    return this.certFingerprint;
  }
}

/**
 * Reads the peer certificate of an accepted TLS connection.
 *
 * `getRemoteCertificate()` never settles when the peer presented no certificate, so this is only
 * worth asking for when the server requested one — and even then the wait is bounded.
 */
export async function peerCertificateFingerprint(conn: socket.TLSSocketConnection): Promise<string | null> {
  const timeout: Promise<string | null> = new Promise<string | null>((resolve: (value: string | null) => void) => {
    setTimeout((): void => {
      resolve(null);
    }, CERT_WAIT_MS);
  });
  const reading: Promise<string | null> = conn.getRemoteCertificate().then(
    (raw: socket.X509CertRawData): Promise<string | null> => sha256Hex(raw.data, true),
    (reason: Object): string | null => null);
  return await Promise.race<string | null>([reading, timeout]);
}

/** Resolves the peer address of an accepted socket; both server connection types expose the same call. */
export async function resolvePeer(
  conn: socket.TCPSocketConnection | socket.TLSSocketConnection,
  fallbackPort: number
): Promise<PeerAddress> {
  try {
    const address: socket.NetAddress = await conn.getRemoteAddress();
    const peer: PeerAddress = {
      host: address.address,
      port: address.port === undefined ? fallbackPort : address.port,
      family: familyOf(address.family)
    };
    return peer;
  } catch (e) {
    const peer: PeerAddress = { host: '', port: fallbackPort, family: 'IPv4' };
    return peer;
  }
}
