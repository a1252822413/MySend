import { KnownChannel, ProtocolScheme } from '@lsnext/protocol';

const DEFAULT_PORT: number = 53317;

/**
 * Parses the address the user types: `[scheme://]host[:port]`.
 *
 * A scheme prefix is required for HTTPS because the peer's own announcement never reaches us
 * without multicast — the address is all we have to go on, and the scheme decides which port
 * shape and handshake to attempt.
 */
export function parseHostSpec(text: string): KnownChannel | null {
  let rest: string = text.trim().toLowerCase();
  let scheme: ProtocolScheme = ProtocolScheme.HTTP;
  if (rest.startsWith('https://')) {
    scheme = ProtocolScheme.HTTPS;
    rest = rest.substring('https://'.length);
  } else if (rest.startsWith('http://')) {
    rest = rest.substring('http://'.length);
  }
  // A trailing slash is how the address gets pasted from a browser.
  const slash: number = rest.indexOf('/');
  if (slash >= 0) {
    rest = rest.substring(0, slash);
  }
  const host: string = rest.indexOf(':') >= 0 ? rest.substring(0, rest.indexOf(':')) : rest;
  if (host.length === 0) {
    return null;
  }
  const port: number = rest.indexOf(':') >= 0 ? Number(rest.substring(rest.indexOf(':') + 1)) : DEFAULT_PORT;
  if (!(port >= 1 && port <= 65535)) {
    return null;
  }
  return { host: host, port: port, protocol: scheme };
}

/** The round-trip form we persist, so a saved address parses exactly like a typed one. */
export function formatHostSpec(channel: KnownChannel): string {
  const scheme: string = channel.protocol === ProtocolScheme.HTTPS ? 'https://' : '';
  return `${scheme}${channel.host}:${channel.port}`;
}

export function sameHost(a: KnownChannel, b: KnownChannel): boolean {
  return a.host === b.host && a.port === b.port && a.protocol === b.protocol;
}
