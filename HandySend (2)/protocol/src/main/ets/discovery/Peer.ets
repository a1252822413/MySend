import { DeviceTypeValue, ProtocolScheme } from '../wire/Constants';
import { WireDeviceInfo, WireInfoResponse } from '../wire/Dto';

/** How a peer entered the list; used for diagnostics only, never for trust. */
export enum PeerSource {
  MULTICAST = 'multicast',
  REGISTER = 'register',
  SCAN = 'scan'
}

/**
 * A discovered LocalSend member.
 *
 * `host` always comes from the socket that carried the announcement or request, never from the
 * payload — the payload only tells us which port to dial. Trusting a self-reported address would
 * let any device on the LAN point a peer at a third host.
 */
export class Peer {
  readonly fingerprint: string;
  alias: string;
  version: string;
  deviceModel: string;
  deviceType: DeviceTypeValue;
  host: string;
  port: number;
  protocol: ProtocolScheme;
  /** Section 5: the peer also serves the download API (web send). */
  download: boolean;
  lastSeenMs: number;
  source: PeerSource;

  constructor(fingerprint: string, alias: string, host: string, port: number, protocol: ProtocolScheme) {
    this.fingerprint = fingerprint;
    this.alias = alias;
    this.version = '';
    this.deviceModel = '';
    this.deviceType = DeviceTypeValue.DESKTOP;
    this.host = host;
    this.port = port;
    this.protocol = protocol;
    this.download = false;
    this.lastSeenMs = Date.now();
    this.source = PeerSource.MULTICAST;
  }

  isHttps(): boolean {
    return this.protocol === ProtocolScheme.HTTPS;
  }

  applyInfo(info: WireDeviceInfo, source: PeerSource): void {
    this.alias = info.alias;
    this.version = info.version;
    this.deviceModel = info.deviceModel ?? '';
    this.deviceType = info.deviceType ?? DeviceTypeValue.DESKTOP;
    this.protocol = info.protocol;
    this.download = info.download;
    if (info.port > 0) {
      this.port = info.port;
    }
    this.touch(source);
  }

  /** /register and /info responses carry no port or scheme, so only the mutable fields update. */
  applyResponse(response: WireInfoResponse, source: PeerSource): void {
    this.alias = response.alias;
    this.version = response.version;
    this.deviceModel = response.deviceModel ?? '';
    this.deviceType = response.deviceType ?? DeviceTypeValue.DESKTOP;
    this.download = response.download;
    this.touch(source);
  }

  private touch(source: PeerSource): void {
    this.lastSeenMs = Date.now();
    this.source = source;
  }
}

/** Result of a confirmation: the stored peer and whether it was absent before. */
export interface NewPeer {
  peer: Peer;
  isNew: boolean;
}

/**
 * Deduplicated by fingerprint, which is the protocol's device identity.
 *
 * The fingerprint must be resolved by the caller: in TLS mode the peer's identity is the
 * certificate presented in the handshake, and the string in the body only counts when the
 * connection is unencrypted.
 *
 * There is deliberately no expiry: a LocalSend device that stays silent is still reachable, and the
 * official clients keep the entry until the user leaves the page.
 */
export class PeerStore {
  private peers: Map<string, Peer> = new Map<string, Peer>();

  get(fingerprint: string): Peer | null {
    const peer: Peer | undefined = this.peers.get(fingerprint);
    return peer === undefined ? null : peer;
  }

  /** Insert or refresh, keyed by the resolved fingerprint. Returns the peer and whether it is new. */
  confirm(fingerprint: string, host: string, port: number, protocol: ProtocolScheme,
    source: PeerSource): NewPeer {
    let peer: Peer | null = this.get(fingerprint);
    let isNew: boolean = false;
    if (peer === null) {
      peer = new Peer(fingerprint, '', host, port, protocol);
      this.peers.set(fingerprint, peer);
      isNew = true;
    } else if (peer.host !== host) {
      // The socket address wins: a device that roamed to a new IP must not keep the stale one.
      peer.host = host;
    }
    if (port > 0) {
      peer.port = port;
    }
    peer.protocol = protocol;
    return { peer: peer, isNew: isNew };
  }

  /** Registers or refreshes a peer seen in an `info` payload. */
  upsertInfo(info: WireDeviceInfo, fingerprint: string, host: string, source: PeerSource): NewPeer {
    const confirmed: NewPeer = this.confirm(fingerprint, host, info.port, info.protocol, source);
    confirmed.peer.applyInfo(info, source);
    return confirmed;
  }

  upsertResponse(info: WireInfoResponse, fingerprint: string, host: string, port: number,
    protocol: ProtocolScheme, source: PeerSource): NewPeer {
    const confirmed: NewPeer = this.confirm(fingerprint, host, port, protocol, source);
    confirmed.peer.applyResponse(info, source);
    return confirmed;
  }

  isNew(fingerprint: string): boolean {
    return this.get(fingerprint) === null;
  }

  remove(fingerprint: string): void {
    this.peers.delete(fingerprint);
  }

  /** Sorted by alias so the UI list does not reshuffle on every announcement. */
  list(): Peer[] {
    const out: Peer[] = [];
    this.peers.forEach((peer: Peer) => {
      out.push(peer);
    });
    out.sort((a: Peer, b: Peer): number => a.alias.localeCompare(b.alias));
    return out;
  }

  size(): number {
    return this.peers.size;
  }

  clear(): void {
    this.peers.clear();
  }
}
