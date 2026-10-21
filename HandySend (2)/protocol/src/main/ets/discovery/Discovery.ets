import { util } from '@kit.ArkTS';
import { ANNOUNCE_DELAYS_MS, ApiPath, DEFAULT_MULTICAST_GROUP, DeviceTypeValue, DISCOVERY_TIMEOUT_MS,
  ProtocolScheme } from '../wire/Constants';
import { Dto, WireAnnouncement, WireDeviceInfo, WireInfoResponse } from '../wire/Dto';
import { parseRecord } from '../wire/JsonValue';
import { ClientCredentials } from '../transport/DialedLinks';
import { Identity } from '../identity/Identity';
import { Exchange, RequestHandler, ServerReply, replyWithJson, replyWithMessage } from '../httpx/Exchange';
import { Status } from '../httpx/Http';
import { describeFailure } from '../util/Errors';
import { getLocalIpv4Interfaces, LocalInterface } from '../util/NetIF';
import { NewPeer, Peer, PeerSource, PeerStore } from './Peer';
import { AnnouncementSink, DiscoveryLogger, MulticastChannel, ReceivedAnnouncement } from './Multicast';
import { ProbeOptions, ProbeOutcome, probeAnnouncer, probeRegister, SubnetScanner } from './Probing';

export type PeersChanged = (peers: Peer[]) => void;

/** A channel we already know a peer on: favorites, or a peer that vanished when multicast died. */
export interface KnownChannel {
  host: string;
  port: number;
  protocol: ProtocolScheme;
}

export interface DiscoveryConfig {
  /** Re-read on every send, so renaming the device takes effect without a restart. */
  self: () => WireDeviceInfo;
  port: number;
  /** Multicast group override; null uses the protocol default. */
  group: string | null;
  /** Used to build TLS client credentials for probing encrypted peers. */
  identity: () => Identity | null;
  onPeersChanged: PeersChanged;
  log: DiscoveryLogger;
}

/** How long to wait for multicast/register before escalating to a subnet scan. */
const STAGED_GRACE_MS: number = 2500;
const MAX_PROBE_BODY: number = 64 * 1024;

const utf8Decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

function utf8(bytes: Uint8Array): string {
  return utf8Decoder.decodeToString(bytes);
}

/**
 * Discovery engine: multicast announce + register, with the legacy /24 scan as fallback.
 *
 * Timings and structure mirror the official core (announce burst at 100/500/2000 ms with no periodic
 * re-announce, 500 ms register timeout, staged discovery that only scans when the cheap stages
 * confirmed nothing), because peers behave predictably only against a client that behaves like the
 * reference one.
 */
export class Discovery {
  private config: DiscoveryConfig;
  readonly peers: PeerStore = new PeerStore();
  private channel: MulticastChannel | null = null;
  private scanner: SubnetScanner | null = null;
  private interfaces: LocalInterface[] = [];
  private burstTimers: number[] = [];
  private started: boolean = false;
  private confirmations: number = 0;
  private scanning: Set<string> = new Set<string>();
  /**
   * Announcements are answered with a register request, which advertises our HTTP port. Turn this
   * off while our server is not running, or we advertise a port nobody listens on.
   */
  private answerAnnouncements: boolean = true;

  constructor(config: DiscoveryConfig) {
    this.config = config;
  }

  async start(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    try {
      this.interfaces = await getLocalIpv4Interfaces();
    } catch (e) {
      this.config.log(`interface enumeration failed: ${describeFailure(e)}`);
      this.interfaces = [];
    }
    this.scanner = new SubnetScanner(this.probeOptions(DISCOVERY_TIMEOUT_MS));
    const sink: AnnouncementSink = (received: ReceivedAnnouncement): void => {
      this.onAnnouncement(received);
    };
    try {
      this.channel = await MulticastChannel.open(this.interfaces, this.config.port, this.config.group,
        sink, this.config.log);
    } catch (e) {
      this.config.log(`multicast discovery unavailable, using http discovery: ${describeFailure(e)}`);
      this.channel = null;
    }
  }

  /** Announce burst, and a legacy scan when multicast is not carrying us. */
  announce(): void {
    this.clearBurst();
    const payload: string = Dto.announcementToJson(this.config.self(), true);
    for (let i = 0; i < ANNOUNCE_DELAYS_MS.length; i++) {
      const delay: number = ANNOUNCE_DELAYS_MS[i];
      const timer: number = setTimeout(() => {
        this.sendBurst(payload);
      }, delay);
      this.burstTimers.push(timer);
    }
  }

  private async sendBurst(payload: string): Promise<void> {
    const channel: MulticastChannel | null = this.channel;
    if (channel === null) {
      return;
    }
    await channel.sendToGroup(payload, this.config.port);
  }

  /**
   * Cheapest-first discovery: announce, probe the channels we already know, and only if nothing
   * answered within `graceMs` walk the /24 of each interface. Any confirmation proves the cheap
   * stages work on this network, so the scan would only cost battery.
   */
  async discoverStaged(knownChannels: KnownChannel[], graceMs: number = STAGED_GRACE_MS): Promise<void> {
    const before: number = this.confirmations;
    this.announce();
    await this.probeChannels(knownChannels);
    await delay(graceMs);
    if (this.confirmations === before) {
      await this.scanAllInterfaces();
    }
  }

  /** Probe specific addresses; the emulator's NAT and "connect by IP" both land here. */
  async probeChannels(channels: KnownChannel[]): Promise<void> {
    const options: ProbeOptions = this.probeOptions(DISCOVERY_TIMEOUT_MS);
    for (let i = 0; i < channels.length; i++) {
      const channel: KnownChannel = channels[i];
      this.applyProbe(await probeRegister(channel.host, channel.port, channel.protocol, options),
        PeerSource.SCAN);
    }
  }

  /** Scan the /24 of every usable interface, at most one concurrent scan per interface. */
  async scanAllInterfaces(): Promise<void> {
    for (let i = 0; i < this.interfaces.length; i++) {
      await this.scanSubnet(this.interfaces[i]);
    }
  }

  async scanSubnet(netIf: LocalInterface): Promise<void> {
    const scanner: SubnetScanner | null = this.scanner;
    if (scanner === null || this.scanning.has(netIf.address)) {
      return;
    }
    this.scanning.add(netIf.address);
    try {
      const hosts: string[] = SubnetScanner.hostsFor([netIf]);
      this.config.log(`legacy scan over ${hosts.length} host(s) on ${netIf.address}`);
      await scanner.walk(hosts, this.config.port, this.config.self().protocol,
        (outcome: ProbeOutcome): void => {
          this.applyProbe(outcome, PeerSource.SCAN);
        });
    } finally {
      this.scanning.delete(netIf.address);
    }
  }

  /**
   * Store a probe answer.
   *
   * Identity rule from the reference client: over TLS the peer is the certificate presented in the
   * handshake, and a fingerprint claimed in the body only counts when the connection is plaintext.
   */
  private applyProbe(outcome: ProbeOutcome, source: PeerSource): void {
    const response: WireInfoResponse | null = outcome.response;
    if (response === null) {
      if (outcome.error !== null) {
        this.config.log(outcome.error);
      }
      return;
    }
    const certFingerprint: string | null = outcome.certFingerprint;
    const fingerprint: string = certFingerprint === null ? response.fingerprint : certFingerprint;
    if (fingerprint === this.config.self().fingerprint) {
      return;
    }
    const confirmed: NewPeer = this.peers.upsertResponse(response, fingerprint, outcome.host, outcome.port,
      outcome.scheme, source);
    this.confirmed(confirmed);
  }

  private onAnnouncement(received: ReceivedAnnouncement): void {
    const announcement: WireAnnouncement = received.announcement;
    if (announcement.fingerprint === this.config.self().fingerprint) {
      // Multicast loopback is on deliberately, so our own announcement comes back to us.
      return;
    }
    // An announcement is not proof of reachability, but showing it immediately matches the
    // reference client's behaviour; the register answer then confirms and corrects it.
    const host: string = received.host;
    const confirmed: NewPeer = this.peers.upsertInfo(announcement, announcement.fingerprint, host,
      PeerSource.MULTICAST);
    this.confirmed(confirmed);
    if (!announcement.announce || !this.answerAnnouncements) {
      return;
    }
    // The answer to an announcement is always an HTTP register request — never another UDP datagram.
    probeAnnouncer(announcement, host, this.probeOptions(DISCOVERY_TIMEOUT_MS))
      .then((outcome: ProbeOutcome): void => {
        this.applyProbe(outcome, PeerSource.REGISTER);
      }, (reason: Object): void => {
        this.config.log(`register reply to ${host} failed: ${describeFailure(reason)}`);
      });
  }

  private confirmed(result: NewPeer): void {
    this.confirmations += 1;
    this.config.onPeersChanged(this.peers.list());
  }

  /** `POST /api/localsend/v2/register`: the two-way half of discovery, served by our HTTP server. */
  registerHandler(): RequestHandler {
    return async (exchange: Exchange): Promise<ServerReply> => {
      const bytes: Uint8Array | null = await exchange.body.readAll(MAX_PROBE_BODY);
      const record: Record<string, Object> | null = bytes === null ? null : parseRecord(utf8(bytes));
      const info: WireDeviceInfo | null = record === null ? null : Dto.parseDeviceInfo(record);
      if (info === null) {
        return replyWithMessage(Status.BadRequest, 'Invalid body');
      }
      // Over TLS the handshake certificate proves who the peer is, so a claimed fingerprint is
      // only trusted on a plaintext connection — the same rule the reference server applies.
      const claimed: string = info.fingerprint.toUpperCase();
      const proven: string | null = exchange.peerCertFingerprint === null ? null : exchange.peerCertFingerprint.toUpperCase();
      if (proven !== null && proven !== claimed) {
        this.config.log(`register from ${exchange.peerHost}: fingerprint claim not proven by its certificate`);
      } else if (claimed !== this.config.self().fingerprint.toUpperCase()) {
        // A peer that registers with us is reachable, so this counts as a confirmation.
        const confirmed: NewPeer = this.peers.upsertInfo(info, proven ?? claimed, exchange.peerHost,
          PeerSource.REGISTER);
        this.confirmed(confirmed);
      }
      return replyWithJson(Status.Ok, Dto.infoResponseToJson(this.infoResponse()));
    };
  }

  /** `GET /api/localsend/v2/info`: debugging endpoint, section 6.1. */
  infoHandler(): RequestHandler {
    return async (exchange: Exchange): Promise<ServerReply> => {
      return replyWithJson(Status.Ok, Dto.infoResponseToJson(this.infoResponse()));
    };
  }

  setAnswerAnnouncements(answer: boolean): void {
    this.answerAnnouncements = answer;
  }

  private infoResponse(): WireInfoResponse {
    return Dto.infoResponseOf(this.config.self());
  }

  private probeOptions(timeoutMs: number): ProbeOptions {
    const options: ProbeOptions = {
      self: this.config.self(),
      credentials: this.clientCredentials(),
      timeoutMs: timeoutMs,
      log: this.config.log
    };
    return options;
  }

  /**
   * Encrypted peers demand a client certificate, so probes present our own self-signed one. In
   * http-only mode there is no certificate to offer and probing stays plain.
   */
  private clientCredentials(): ClientCredentials | null {
    const identity: Identity | null = this.config.identity();
    if (identity === null || !identity.isHttps) {
      return null;
    }
    const credentials: ClientCredentials = {
      certPem: identity.certPem,
      keyPem: identity.keyPem,
      keyPassword: identity.keyPassword
    };
    return credentials;
  }

  private clearBurst(): void {
    for (let i = 0; i < this.burstTimers.length; i++) {
      clearTimeout(this.burstTimers[i]);
    }
    this.burstTimers = [];
  }

  hasMulticast(): boolean {
    return this.channel !== null && this.channel.hasReceiver();
  }

  localInterfaces(): LocalInterface[] {
    return this.interfaces;
  }

  multicastGroup(): string {
    return this.config.group === null ? DEFAULT_MULTICAST_GROUP : this.config.group;
  }

  async stop(): Promise<void> {
    this.clearBurst();
    this.started = false;
    if (this.channel !== null) {
      await this.channel.close();
      this.channel = null;
    }
  }
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}
