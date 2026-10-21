import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteLink, IpFamily, PeerAddress, TransportError, tightBuffer } from './ByteLink';
import { sha256Hex } from '../util/Digest';

type DataCallback = (chunk: Uint8Array) => void;

abstract class DialedLink implements ByteLink {
  protected peerAddress: PeerAddress;
  protected dataCallback: DataCallback | null = null;
  protected closedCallback: (() => void) | null = null;
  protected closed: boolean = false;

  constructor(peerAddress: PeerAddress) {
    this.peerAddress = peerAddress;
  }

  peer(): PeerAddress {
    return this.peerAddress;
  }

  onData(callback: DataCallback): void {
    this.dataCallback = callback;
  }

  onClosed(callback: () => void): void {
    this.closedCallback = callback;
  }

  protected handleChunk(message: ArrayBuffer): void {
    if (this.dataCallback !== null) {
      this.dataCallback(new Uint8Array(message));
    }
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

  abstract isTls(): boolean;
}

class TcpDialedLink extends DialedLink {
  private conn: socket.TCPSocket;

  constructor(conn: socket.TCPSocket, peer: PeerAddress) {
    super(peer);
    this.conn = conn;
    conn.on('message', (info: socket.SocketMessageInfo) => {
      this.handleChunk(info.message);
    });
    conn.on('close', () => {
      this.handleClosed();
    });
  }

  isTls(): boolean {
    return false;
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
    }
    this.handleClosed();
  }
}

class TlsDialedLink extends DialedLink {
  private conn: socket.TLSSocket;

  constructor(conn: socket.TLSSocket, peer: PeerAddress) {
    super(peer);
    this.conn = conn;
    conn.on('message', (info: socket.SocketMessageInfo) => {
      this.handleChunk(info.message);
    });
    conn.on('close', () => {
      this.handleClosed();
    });
  }

  isTls(): boolean {
    return true;
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
    try {
      const raw: socket.X509CertRawData = await this.conn.getRemoteCertificate();
      return await sha256Hex(raw.data, true);
    } catch (e) {
      return null;
    }
  }
}

export interface ClientCredentials {
  /** PEM certificate chain presented as the TLS client certificate. */
  certPem: string;
  /** PEM private key matching `certPem`. */
  keyPem: string;
  /** Password protecting the key; empty string for an unencrypted PEM. */
  keyPassword: string;
}

function withTimeout<T>(operation: Promise<T>, timeoutMs: number, label: string): Promise<T> {
  if (timeoutMs <= 0) {
    return operation;
  }
  return new Promise<T>((resolve: (value: T) => void, reject: (reason: Object) => void) => {
    const timer: number = setTimeout(() => {
      reject(new TransportError(`${label} timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    operation.then((value: T) => {
      clearTimeout(timer);
      resolve(value);
    }, (reason: Object) => {
      clearTimeout(timer);
      reject(reason);
    });
  });
}

export async function connectTcp(target: PeerAddress, timeoutMs: number): Promise<ByteLink> {
  const conn: socket.TCPSocket = socket.constructTCPSocketInstance();
  const options: socket.TCPConnectOptions = {
    address: { address: target.host, port: target.port, family: target.family === 'IPv6' ? 2 : 1 },
    timeout: timeoutMs
  };
  await withTimeout(conn.connect(options), timeoutMs + 1000, `connect ${target.host}`);
  return new TcpDialedLink(conn, target);
}

/**
 * LocalSend peers always present self-signed, per-device certificates, so certificate-chain
 * validation is skipped and identity comes from the certificate fingerprint instead — the same
 * model the official client uses (a custom verifier that only checks the signature and dates).
 */
export async function connectTls(
  target: PeerAddress,
  credentials: ClientCredentials | null,
  timeoutMs: number
): Promise<ByteLink> {
  const conn: socket.TLSSocket = socket.constructTLSSocketInstance();
  const secureOptions: socket.TLSSecureOptions = {
    protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13],
    useRemoteCipherPrefer: true
  };
  if (credentials !== null) {
    secureOptions.cert = credentials.certPem;
    secureOptions.key = credentials.keyPem;
    secureOptions.password = credentials.keyPassword;
  }
  const address: socket.NetAddress = {
    address: target.host,
    port: target.port,
    family: target.family === 'IPv6' ? 2 : 1
  };
  try {
    await conn.bind({ address: target.family === 'IPv6' ? '::' : '0.0.0.0', port: 0 });
  } catch (e) {
    const error: BusinessError = e as BusinessError;
    throw new TransportError(`tls bind failed: ${error.message}`, error.code);
  }
  const options: socket.TLSConnectOptions = {
    address: address,
    secureOptions: secureOptions,
    ALPNProtocols: ['http/1.1'],
    skipRemoteValidation: true,
    timeout: timeoutMs
  };
  await withTimeout(conn.connect(options), timeoutMs + 1000, `tls connect ${target.host}`);
  return new TlsDialedLink(conn, target);
}
