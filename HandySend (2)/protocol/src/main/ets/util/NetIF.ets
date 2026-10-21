/**
 * Local interface enumeration for UDP multicast binding, plus the address
 * arithmetic the legacy /24 HTTP discovery scan needs. Ported from
 * packages/core/src/util/interface.rs and the `scan_subnet` fallback in
 * packages/core/src/discovery/mod.rs.
 */
import { connection } from '@kit.NetworkKit';
import { NetError, describePlatformError, platformErrorCode } from './Errors';

/**
 * One usable IPv4 link. `netIF` carries the OS network id: HarmonyOS exposes no
 * if_nametoindex, and a socket picks its route by binding the net handle.
 */
export interface LocalInterface {
  address: string;
  prefixLength: number;
  netIF: number;
  name: string;
}

/** The Rust fallback scan only ever walks a /24; refuse to enumerate wilder blocks. */
const MAX_SCANNED_HOSTS: number = 65536;

function stripScope(address: string): string {
  const at: number = address.indexOf('%');
  return at === -1 ? address : address.substring(0, at);
}

/** Four dot-separated decimal octets, nothing else. */
function parseIpv4Octets(address: string): number[] | null {
  const parts: string[] = address.split('.');
  if (parts.length !== 4) {
    return null;
  }
  const octets: number[] = [];
  for (let i = 0; i < 4; i++) {
    const part: string = parts[i];
    if (part.length === 0 || part.length > 3) {
      return null;
    }
    let value: number = 0;
    for (let j = 0; j < part.length; j++) {
      const code: number = part.charCodeAt(j);
      if (code < 0x30 || code > 0x39) {
        return null;
      }
      value = value * 10 + (code - 0x30);
    }
    if (value > 255) {
      return null;
    }
    octets.push(value);
  }
  return octets;
}

function toDotted(value: number): string {
  const a: number = Math.floor(value / 16777216) % 256;
  const b: number = Math.floor(value / 65536) % 256;
  const c: number = Math.floor(value / 256) % 256;
  const d: number = value % 256;
  return '' + a + '.' + b + '.' + c + '.' + d;
}

function isHexGroup(text: string): boolean {
  if (text.length === 0 || text.length > 4) {
    return false;
  }
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    const isDigit: boolean = code >= 0x30 && code <= 0x39;
    const isLower: boolean = code >= 0x61 && code <= 0x66;
    const isUpper: boolean = code >= 0x41 && code <= 0x46;
    if (!isDigit && !isLower && !isUpper) {
      return false;
    }
  }
  return true;
}

/** Number of colon-separated groups, -1 when malformed; an embedded IPv4 tail counts as one. */
function countIpv6Groups(text: string): number {
  if (text.length === 0) {
    return 0;
  }
  const parts: string[] = text.split(':');
  for (let i = 0; i < parts.length; i++) {
    const part: string = parts[i];
    if (part.length === 0 || (!isHexGroup(part) && parseIpv4Octets(part) === null)) {
      return -1;
    }
  }
  return parts.length;
}

export function isIpv4(address: string): boolean {
  return parseIpv4Octets(address) !== null;
}

/** Literal syntax check; a `%scope` suffix is tolerated and ignored. */
export function isIpv6(address: string): boolean {
  const body: string = stripScope(address);
  if (body.length === 0 || body.indexOf(':') === -1) {
    return false;
  }
  const halves: string[] = body.split('::');
  if (halves.length > 2) {
    return false;
  }
  const head: number = countIpv6Groups(halves.length === 2 ? halves[0] : body);
  const tail: number = countIpv6Groups(halves.length === 2 ? halves[1] : '');
  if (head < 0 || tail < 0) {
    return false;
  }
  // '::' stands for at least one elided group, so an uncompressed address must
  // spell all eight and a compressed one may not already fill them.
  return halves.length === 2 ? head + tail <= 7 : head + tail === 8;
}

function isLoopbackIpv4(address: string): boolean {
  const octets: number[] | null = parseIpv4Octets(address);
  if (octets === null) {
    return false;
  }
  return octets[0] === 127;
}

/**
 * URL host form of `ip`. A bare IPv6 literal is ambiguous in a URL, so it is
 * bracketed, and the scope stays on the literal (`[fe80::1%3]`) because a
 * link-local address is only dialable through the interface it was learned on.
 */
export function formatHostForUrl(ip: string, scopeId?: number): string {
  const at: number = ip.indexOf('%');
  const body: string = at === -1 ? ip : ip.substring(0, at);
  if (isIpv4(body)) {
    return body;
  }
  let scope: string = at === -1 ? '' : ip.substring(at);
  if (scopeId !== undefined) {
    scope = '%' + scopeId;
  }
  return '[' + body + scope + ']';
}

/**
 * Properties of one net handle, or null when they cannot be read. A single link
 * that fails must not blind the whole discovery pass.
 */
async function readProperties(net: connection.NetHandle): Promise<connection.ConnectionProperties | null> {
  try {
    return await connection.getConnectionProperties(net);
  } catch (e) {
    return null;
  }
}

async function readAllNets(): Promise<connection.NetHandle[]> {
  try {
    return await connection.getAllNets();
  } catch (e) {
    throw new NetError(describePlatformError(e as Object, 'connection.getAllNets'), platformErrorCode(e as Object));
  }
}

/**
 * Non-loopback IPv4 links of every network the OS knows about. Addresses with no
 * prefix length are dropped: without one there is no subnet to join or scan.
 */
export async function getLocalIpv4Interfaces(): Promise<LocalInterface[]> {
  const result: LocalInterface[] = [];
  const nets: connection.NetHandle[] = await readAllNets();

  for (let i = 0; i < nets.length; i++) {
    const net: connection.NetHandle = nets[i];
    const properties: connection.ConnectionProperties | null = await readProperties(net);
    if (properties === null) {
      continue;
    }
    const links: connection.LinkAddress[] = properties.linkAddresses;
    for (let j = 0; j < links.length; j++) {
      const netAddress: connection.NetAddress | undefined = links[j].address;
      if (netAddress === undefined) {
        continue;
      }
      const prefixLength: number = links[j].prefixLength;
      const address: string = netAddress.address;
      if (!isIpv4(address) || prefixLength <= 0 || isLoopbackIpv4(address)) {
        continue;
      }
      // The same address can surface under more than one net handle.
      let duplicate: boolean = false;
      for (let k = 0; k < result.length; k++) {
        if (result[k].address === address) {
          duplicate = true;
          break;
        }
      }
      if (duplicate) {
        continue;
      }
      const entry: LocalInterface = {
        address: address,
        prefixLength: prefixLength,
        netIF: net.netId,
        name: properties.interfaceName
      };
      result.push(entry);
    }
  }
  return result;
}

/**
 * Host addresses of `addr`'s block, its own address excluded — the peers a
 * register request may still get an answer from. Network and broadcast
 * addresses are kept, matching the Rust scan which walks every value of the
 * host part and skips only the local interface.
 */
export function subnetHosts(addr: string, prefix: number): string[] {
  const octets: number[] | null = parseIpv4Octets(addr);
  if (octets === null) {
    throw new NetError('Not an IPv4 address: ' + addr, -1);
  }
  if (prefix < 1 || prefix > 32) {
    throw new NetError('Invalid prefix length: ' + prefix, -1);
  }
  const blockSize: number = Math.pow(2, 32 - prefix);
  if (blockSize > MAX_SCANNED_HOSTS) {
    throw new NetError('Refusing to scan a /' + prefix + ' block of ' + blockSize + ' addresses', -1);
  }
  const local: number = (octets[0] * 16777216) + (octets[1] * 65536) + (octets[2] * 256) + octets[3];
  const base: number = Math.floor(local / blockSize) * blockSize;
  const hosts: string[] = [];
  for (let offset = 0; offset < blockSize; offset++) {
    const host: number = base + offset;
    if (host === local) {
      continue;
    }
    hosts.push(toDotted(host));
  }
  return hosts;
}
