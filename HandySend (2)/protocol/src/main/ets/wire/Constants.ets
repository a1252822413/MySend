/**
 * Protocol-wide constants, from the LocalSend protocol spec v2.2 plus the
 * defaults observable in the official Rust core (packages/core).
 */

/** Default port for both the UDP multicast group and the HTTP/TCP server. */
export const DEFAULT_PORT: number = 53317;

/** IPv4 multicast group. LocalSend pins 224.0.0.0/24 because some Android devices reject other groups. */
export const DEFAULT_MULTICAST_GROUP: string = '224.0.0.167';

/** LocalSend extension: link-local transient IPv6 group. */
export const DEFAULT_MULTICAST_GROUP_V6: string = 'ff12::fd3a:e420';

/** Wire protocol version this client speaks. */
export const PROTOCOL_VERSION: string = '2.2';

/** Register timeout applied to a single peer answer during discovery. */
export const DISCOVERY_TIMEOUT_MS: number = 500;

/** Delays of the announcement burst; the official client sends three datagrams, then stops. */
export const ANNOUNCE_DELAYS_MS: number[] = [100, 500, 2000];

/** Concurrency of the legacy /24 HTTP scan fallback. */
export const SCAN_CONCURRENCY: number = 50;

/** Maximum number of interfaces probed by the legacy scan. */
export const SCAN_MAX_INTERFACES: number = 3;

/** Parallel upload streams per send task. */
export const UPLOAD_CONCURRENCY: number = 2;

/**
 * Attempts one file may make before the transfer gives up on it. Both halves read it the same way:
 * the receiver resets a checksum mismatch to pending while `attempts < MAX_UPLOAD_ATTEMPTS`, and the
 * sender stops at the same count, so neither side can exhaust the other's patience.
 */
export const MAX_UPLOAD_ATTEMPTS: number = 3;

/** Wrong-PIN attempts tolerated per source IP before 429. */
export const MAX_PIN_ATTEMPTS: number = 3;

/** Connection caps of the HTTP server. */
export const MAX_CONNECTIONS: number = 64;
export const MAX_CONNECTIONS_PER_IP: number = 8;

export enum ApiPath {
  INFO = '/api/localsend/v2/info',
  REGISTER = '/api/localsend/v2/register',
  PREPARE_UPLOAD = '/api/localsend/v2/prepare-upload',
  UPLOAD = '/api/localsend/v2/upload',
  CANCEL = '/api/localsend/v2/cancel',
  PREPARE_DOWNLOAD = '/api/localsend/v2/prepare-download',
  DOWNLOAD = '/api/localsend/v2/download'
}

export enum DeviceTypeValue {
  MOBILE = 'mobile',
  DESKTOP = 'desktop',
  WEB = 'web',
  HEADLESS = 'headless',
  SERVER = 'server'
}

export enum ProtocolScheme {
  HTTP = 'http',
  HTTPS = 'https'
}

/**
 * Wire values of `deviceType` are free-form: section 7.1 requires implementations to cope with
 * unknown values, and the official implementation maps them to `desktop`.
 */
export function normalizeDeviceType(raw: string | undefined | null): DeviceTypeValue {
  switch (raw === undefined || raw === null ? '' : raw.toLowerCase()) {
    case DeviceTypeValue.MOBILE:
      return DeviceTypeValue.MOBILE;
    case DeviceTypeValue.WEB:
      return DeviceTypeValue.WEB;
    case DeviceTypeValue.HEADLESS:
      return DeviceTypeValue.HEADLESS;
    case DeviceTypeValue.SERVER:
      return DeviceTypeValue.SERVER;
    default:
      return DeviceTypeValue.DESKTOP;
  }
}
