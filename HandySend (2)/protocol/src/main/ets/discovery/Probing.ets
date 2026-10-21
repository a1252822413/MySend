import { ApiPath, ProtocolScheme, SCAN_CONCURRENCY, SCAN_MAX_INTERFACES } from '../wire/Constants';
import { Dto, WireDeviceInfo, WireInfoResponse } from '../wire/Dto';
import { parseRecord } from '../wire/JsonValue';
import { ClientCredentials } from '../transport/DialedLinks';
import { HttpClient, JsonResponse, Target } from '../httpx/Client';
import { describeFailure } from '../util/Errors';
import { LocalInterface, subnetHosts } from '../util/NetIF';
import { DiscoveryLogger } from './Multicast';

/** The outcome of probing one address: either a peer or the reason it is not one. */
export interface ProbeOutcome {
  host: string;
  port: number;
  /** The scheme this probe actually used. */
  scheme: ProtocolScheme;
  response: WireInfoResponse | null;
  /** Fingerprint of the certificate the peer presented, when the probe used TLS. */
  certFingerprint: string | null;
  error: string | null;
}

export interface ProbeOptions {
  self: WireDeviceInfo;
  credentials: ClientCredentials | null;
  timeoutMs: number;
  log: DiscoveryLogger;
}

function schemeOf(peer: WireDeviceInfo): ProtocolScheme {
  return peer.protocol === ProtocolScheme.HTTPS ? ProtocolScheme.HTTPS : ProtocolScheme.HTTP;
}

/**
 * `POST /api/localsend/v2/register` — the two-way discovery call.
 *
 * Both directions matter: sending it makes the peer add us to its list (it learns our socket address
 * from this request), and its body is how we learn about the peer.
 */
export async function probeRegister(host: string, port: number, scheme: ProtocolScheme,
  options: ProbeOptions): Promise<ProbeOutcome> {
  const target: Target = { host: host, port: port, scheme: scheme };
  try {
    const response: JsonResponse = await HttpClient.requestJson({
      target: target,
      method: 'POST',
      path: ApiPath.REGISTER,
      query: new Map<string, string>(),
      json: Dto.deviceInfoToJson(options.self).build(),
      credentials: options.credentials,
      timeoutMs: options.timeoutMs,
      log: options.log
    });
    if (response.status < 200 || response.status >= 300) {
      return { host: host, port: port, scheme: scheme, response: null, certFingerprint: null,
        error: `register ${host}:${port} -> ${response.status}` };
    }
    const record: Record<string, Object> | null = parseRecord(response.body);
    if (record === null) {
      return { host: host, port: port, scheme: scheme, response: null, certFingerprint: null,
        error: `register ${host}:${port} -> unparseable body` };
    }
    return { host: host, port: port, scheme: scheme, response: Dto.parseInfoResponse(record),
      certFingerprint: response.peerCertFingerprint, error: null };
  } catch (e) {
    // A non-LocalSend host on this port fails to connect or fails to answer; both are expected.
    return { host: host, port: port, scheme: scheme, response: null, certFingerprint: null,
      error: `${describeFailure(e)}` };
  }
}

/** Probe a peer that announced itself; the payload tells us the port, the socket told us the host. */
export async function probeAnnouncer(announcement: WireDeviceInfo, host: string,
  options: ProbeOptions): Promise<ProbeOutcome> {
  const port: number = announcement.port > 0 ? announcement.port : options.self.port;
  return await probeRegister(host, port, schemeOf(announcement), options);
}

/**
 * Legacy discovery (spec section 3.2): walk the local /24 and register with every address.
 *
 * Used when multicast is unavailable or blocked — which includes the emulator's NAT, so this is not
 * a dead code path for us. Concurrency and interface count are capped so a scan cannot flood a
 * weak access point.
 */
export class SubnetScanner {
  private options: ProbeOptions;

  constructor(options: ProbeOptions) {
    this.options = options;
  }

  /** Hosts to walk for one interface, matching the Rust core: the whole /24 minus our own address. */
  static hostsFor(interfaces: LocalInterface[]): string[] {
    const seen: Set<string> = new Set<string>();
    const hosts: string[] = [];
    const limit: number = Math.min(interfaces.length, SCAN_MAX_INTERFACES);
    for (let i = 0; i < limit; i++) {
      const netIf: LocalInterface = interfaces[i];
      const candidates: string[] = subnetHosts(netIf.address, netIf.prefixLength);
      for (let j = 0; j < candidates.length; j++) {
        const host: string = candidates[j];
        if (!seen.has(host)) {
          seen.add(host);
          hosts.push(host);
        }
      }
    }
    return hosts;
  }

  async run(interfaces: LocalInterface[], port: number,
    onOutcome: (outcome: ProbeOutcome) => void): Promise<void> {
    await this.walk(SubnetScanner.hostsFor(interfaces), port, this.options.self.protocol, onOutcome);
  }

  /** Explicit-host variant, used for the emulator test path and "connect by IP". */
  async walk(hosts: string[], port: number, scheme: ProtocolScheme,
    onOutcome: (outcome: ProbeOutcome) => void): Promise<void> {
    const queue: string[] = hosts.slice();
    const workers: Promise<void>[] = [];
    const workerCount: number = Math.min(SCAN_CONCURRENCY, queue.length);
    for (let i = 0; i < workerCount; i++) {
      workers.push((async (): Promise<void> => {
        while (queue.length > 0) {
          const host: string = queue.shift() as string;
          onOutcome(await probeRegister(host, port, scheme, this.options));
        }
      })());
    }
    await Promise.all(workers);
  }
}
