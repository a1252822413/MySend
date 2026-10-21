import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { DEFAULT_MULTICAST_GROUP, DEFAULT_MULTICAST_GROUP_V6 } from '../wire/Constants';
import { Dto, WireAnnouncement } from '../wire/Dto';
import { parseRecord } from '../wire/JsonValue';
import { LocalInterface } from '../util/NetIF';
import { describePlatformError } from '../util/Errors';
import { tightBuffer } from '../transport/ByteLink';

/** A datagram that parsed into an announcement, with the socket address it arrived from. */
export interface ReceivedAnnouncement {
  announcement: WireAnnouncement;
  /** Always the packet's source address, never anything the payload claims. */
  host: string;
  sourcePort: number;
}

export type AnnouncementSink = (received: ReceivedAnnouncement) => void;
export type DiscoveryLogger = (message: string) => void;

/** Same as the official core: announcements must not leave the local subnet. */
const MULTICAST_TTL: number = 1;

const encoder: util.TextEncoder = new util.TextEncoder('utf-8');
const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

function familyOf(host: string): number {
  return host.indexOf(':') === -1 ? 1 : 2;
}

/**
 * UDP multicast transport: a listening socket on the well-known port plus one sending socket per
 * local interface.
 *
 * The per-interface senders are not decoration. A socket bound to the wildcard address sends
 * multicast out whatever the default route picks, and on a phone that is often cellular, so the
 * announcement never reaches the Wi-Fi LAN. Binding to the interface address pins the egress.
 *
 * Binding/joining failures are logged and skipped rather than raised: losing one interface must not
 * disable discovery, and the emulator has no multicast at all.
 */
export class MulticastChannel {
  private receiver: socket.MulticastSocket | null = null;
  private receiverV6: socket.MulticastSocket | null = null;
  private senders: socket.MulticastSocket[] = [];
  private sink: AnnouncementSink;
  private log: DiscoveryLogger;
  private group: string;
  private closed: boolean = false;

  private constructor(group: string, sink: AnnouncementSink, log: DiscoveryLogger) {
    this.group = group;
    this.sink = sink;
    this.log = log;
  }

  /** Without a joined listener the group traffic never arrives, however the senders fare. */
  hasReceiver(): boolean {
    return this.receiver !== null || this.receiverV6 !== null;
  }

  static async open(interfaces: LocalInterface[], port: number, group: string | null,
    sink: AnnouncementSink, log: DiscoveryLogger): Promise<MulticastChannel> {
    const resolvedGroup: string = group === null ? DEFAULT_MULTICAST_GROUP : group;
    const channel: MulticastChannel = new MulticastChannel(resolvedGroup, sink, log);
    channel.receiver = await channel.join(false, port, resolvedGroup);
    channel.receiverV6 = await channel.join(true, port, DEFAULT_MULTICAST_GROUP_V6);
    for (let i = 0; i < interfaces.length; i++) {
      const netIf: LocalInterface = interfaces[i];
      try {
        const sender: socket.MulticastSocket = socket.constructMulticastSocketInstance();
        await sender.bind({ address: netIf.address, port: 0, family: 1 });
        sender.setMulticastTTL(MULTICAST_TTL);
        sender.on('message', (info: socket.SocketMessageInfo) => {
          channel.handle(info);
        });
        channel.senders.push(sender);
      } catch (e) {
        log(`multicast sender skipped (${netIf.address}): ${describePlatformError(e as Object, 'bind')}`);
      }
    }
    return channel;
  }

  private async join(useV6: boolean, port: number, group: string): Promise<socket.MulticastSocket | null> {
    try {
      const handle: socket.MulticastSocket = socket.constructMulticastSocketInstance();
      await handle.bind({ address: useV6 ? '::' : '0.0.0.0', port: port, family: useV6 ? 2 : 1 });
      // Several LocalSend instances on one host must all see the group traffic.
      handle.setLoopbackMode(true);
      handle.setMulticastTTL(MULTICAST_TTL);
      await handle.addMembership({ address: group, port: port, family: useV6 ? 2 : 1 });
      handle.on('message', (info: socket.SocketMessageInfo) => {
        this.handle(info);
      });
      return handle;
    } catch (e) {
      this.log(`multicast ${useV6 ? 'ipv6' : 'ipv4'} listener unavailable: ` +
        `${describePlatformError(e as Object, 'bind/join')}`);
      return null;
    }
  }

  private handle(info: socket.SocketMessageInfo): void {
    if (this.closed) {
      return;
    }
    const announcement: WireAnnouncement | null = decodeAnnouncement(info.message);
    if (announcement === null) {
      // Not LocalSend traffic, or a datagram too truncated to parse.
      return;
    }
    this.sink({
      announcement: announcement,
      host: info.remoteInfo.address,
      sourcePort: info.remoteInfo.port
    });
  }

  /** Broadcast an announcement to the group, out every interface we could bind. */
  async sendToGroup(payload: string, port: number): Promise<void> {
    const options: socket.UDPSendOptions = {
      data: tightBuffer(encoder.encodeInto(payload)),
      address: { address: this.group, port: port, family: familyOf(this.group) }
    };
    const handles: socket.MulticastSocket[] = this.senders.slice();
    if (handles.length === 0 && this.receiver !== null) {
      handles.push(this.receiver);
    }
    for (let i = 0; i < handles.length; i++) {
      try {
        await handles[i].send(options);
      } catch (e) {
        this.log(`multicast send failed: ${describePlatformError(e as Object, 'send')}`);
      }
    }
  }

  /** Direct reply to the announcer (the multicast/UDP fallback of section 3.1). */
  async sendTo(host: string, port: number, payload: string): Promise<void> {
    const handle: socket.MulticastSocket | null = familyOf(host) === 2 ? this.receiverV6 : this.receiver;
    if (handle === null) {
      return;
    }
    const options: socket.UDPSendOptions = {
      data: tightBuffer(encoder.encodeInto(payload)),
      address: { address: host, port: port, family: familyOf(host) }
    };
    try {
      await handle.send(options);
    } catch (e) {
      this.log(`multicast reply to ${host}:${port} failed: ${describePlatformError(e as Object, 'send')}`);
    }
  }

  async close(): Promise<void> {
    this.closed = true;
    const handles: socket.MulticastSocket[] = [];
    if (this.receiver !== null) {
      handles.push(this.receiver);
    }
    if (this.receiverV6 !== null) {
      handles.push(this.receiverV6);
    }
    for (let i = 0; i < this.senders.length; i++) {
      handles.push(this.senders[i]);
    }
    this.senders = [];
    for (let i = 0; i < handles.length; i++) {
      try {
        await handles[i].close();
      } catch (e) {
        // A socket the stack already dropped is not a failure worth surfacing.
      }
    }
  }
}

function decodeAnnouncement(buffer: ArrayBuffer): WireAnnouncement | null {
  const record: Record<string, Object> | null = parseRecord(decoder.decodeToString(new Uint8Array(buffer)));
  if (record === null) {
    return null;
  }
  return Dto.parseAnnouncement(record);
}
