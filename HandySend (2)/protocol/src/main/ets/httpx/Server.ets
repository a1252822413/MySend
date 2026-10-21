import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteLink, PeerAddress } from '../transport/ByteLink';
import { peerCertificateFingerprint, TcpAcceptedLink, TlsAcceptedLink, resolvePeer, unknownPeer } from '../transport/AcceptedLinks';
import { HttpConnection } from './Connection';
import { RequestHandler } from './Exchange';
import { describeFailure } from '../util/Errors';
import { MAX_CONNECTIONS, MAX_CONNECTIONS_PER_IP } from '../wire/Constants';

export interface TlsMaterial {
  certPem: string;
  keyPem: string;
  keyPassword: string;
  /**
   * Request a client certificate. Official LocalSend servers make one mandatory, so symmetry asks
   * for it here too — but HarmonyOS validates a requested certificate against its trust store, and
   * a LAN peer's certificate is self-signed, so this stays configurable and defaults to off until
   * verified against the official client.
   *
   * Measured on the emulator SDK: `TLSSocketServer` hands decrypted records to JavaScript out of
   * order (about one 8 KiB record in fourteen), so a multi-megabyte upload keeps its byte count
   * while its bytes land scrambled. The ciphertext reaches us in order — the MACs seal — so the
   * defect is below us and cannot be repaired by reordering opaque body bytes. Plain HTTP is
   * therefore the default, and encryption stays opt-in until the path is verified on a device.
   */
  requestClientCertificate: boolean;
}

export interface ServerConfig {
  port: number;
  tls: TlsMaterial | null;
  routes: Map<string, RequestHandler>;
  log: (message: string) => void;
}

/**
 * The receiver's HTTP server.
 *
 * LocalSend runs one TCP listener per device on the same port as the UDP multicast group, and both
 * plain and TLS sockets feed the same HTTP/1.1 connection state machine.
 */
export class HttpServer {
  private config: ServerConfig;
  private connections: Set<HttpConnection> = new Set<HttpConnection>();
  private perIp: Map<string, number> = new Map<string, number>();
  private tcp: socket.TCPSocketServer | null = null;
  private tls: socket.TLSSocketServer | null = null;
  private stopped: boolean = false;

  private constructor(config: ServerConfig) {
    this.config = config;
  }

  static async start(config: ServerConfig): Promise<HttpServer> {
    const server: HttpServer = new HttpServer(config);
    await server.listen();
    return server;
  }

  private async listen(): Promise<void> {
    const address: socket.NetAddress = { address: '0.0.0.0', port: this.config.port, family: 1 };
    if (this.config.tls === null) {
      const tcp: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      this.tcp = tcp;
      tcp.on('connect', (conn: socket.TCPSocketConnection) => {
        try {
          this.onAccepted(conn);
        } catch (e) {
          this.config.log(`tcp accept threw: ${describeFailure(e)}`);
        }
      });
      tcp.on('error', (err: BusinessError) => {
        this.config.log(`tcp server error ${err.code} ${err.message}`);
      });
      await tcp.listen(address);
      return;
    }
    const tls: socket.TLSSocketServer = socket.constructTLSSocketServerInstance();
    this.tls = tls;
    const material: TlsMaterial = this.config.tls;
    const secureOptions: socket.TLSSecureOptions = {
      cert: material.certPem,
      key: material.keyPem,
      password: material.keyPassword,
      protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13],
      isBidirectionalAuthentication: material.requestClientCertificate
    };
    const options: socket.TLSConnectOptions = {
      address: address,
      secureOptions: secureOptions,
      ALPNProtocols: ['http/1.1']
    };
    await tls.listen(options);
    // Unlike the TCP server, a TLS server drops callbacks registered before listen(): the native
    // side then logs `CallOnConnectCallback fun === null` and hands accepted connections to nobody,
    // so every request stalls. Subscribe only once the listener exists.
    tls.on('connect', (conn: socket.TLSSocketConnection) => {
      this.onTlsAccepted(conn);
    });
    tls.on('error', (err: BusinessError) => {
      this.config.log(`tls server error code=${err.code} message=${err.message} raw=${describeFailure(err)}`);
    });
  }

  private onTlsAccepted(conn: socket.TLSSocketConnection): void {
    // The link is built here, not after the peer lookup: subscribing to `message` synchronously is
    // what keeps the record stream in order, and anything that arrives during the lookup is buffered.
    const link: TlsAcceptedLink = new TlsAcceptedLink(conn, unknownPeer(), null);
    const ask: boolean = this.config.tls !== null && this.config.tls.requestClientCertificate;
    resolvePeer(conn, 0).then((address: PeerAddress) => {
      link.updatePeer(address);
      if (!ask) {
        this.accept(link);
        return;
      }
      peerCertificateFingerprint(conn).then((value: string | null) => {
        link.setCertFingerprint(value);
        this.accept(link);
      });
    }, (reason: Object) => {
      this.config.log(`failed to resolve tls peer: ${describeFailure(reason)}`);
      this.accept(link);
    });
  }

  private onAccepted(conn: socket.TCPSocketConnection): void {
    const link: TcpAcceptedLink = new TcpAcceptedLink(conn, unknownPeer());
    resolvePeer(conn, 0).then((address: PeerAddress) => {
      link.updatePeer(address);
      this.accept(link);
    }, (reason: Object) => {
      this.config.log(`failed to resolve tcp peer: ${describeFailure(reason)}`);
      this.accept(link);
    });
  }

  private accept(link: ByteLink): void {
    if (this.stopped) {
      link.close();
      return;
    }
    const host: string = link.peer().host;
    const active: number = this.perIp.get(host) ?? 0;
    if (this.connections.size >= MAX_CONNECTIONS || (host.length > 0 && active >= MAX_CONNECTIONS_PER_IP)) {
      // Over limit: drop without a handshake, matching the official server's connection caps.
      link.close();
      return;
    }
    this.perIp.set(host, active + 1);
    const connection: HttpConnection = new HttpConnection(link, this.config.routes, this.config.log);
    connection.setOnFinished((finished: HttpConnection) => {
      this.release(finished);
    });
    this.connections.add(connection);
    connection.start();
  }

  private release(connection: HttpConnection): void {
    if (!this.connections.delete(connection)) {
      return;
    }
    const host: string = connection.peerHost;
    const active: number = this.perIp.get(host) ?? 0;
    if (active <= 1) {
      this.perIp.delete(host);
    } else {
      this.perIp.set(host, active - 1);
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    const snapshot: HttpConnection[] = [];
    this.connections.forEach((connection: HttpConnection) => {
      snapshot.push(connection);
    });
    snapshot.forEach((connection: HttpConnection) => {
      connection.close('server stopped');
    });
    this.connections.clear();
    this.perIp.clear();
    try {
      if (this.tcp !== null) {
        await this.tcp.close();
      }
      if (this.tls !== null) {
        await this.tls.close();
      }
    } catch (e) {
      this.config.log(`listener close reported: ${describeFailure(e)}`);
    }
  }
}
