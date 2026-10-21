import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { describePlatformError } from '../util/Errors';
import { hexLower } from '../util/Digest';

/**
 * Identifiers the receiver puts on the wire. The reference core uses uuid v4 for both
 * the session id and the per-file token, and official senders treat them as opaque
 * strings, so the shape that matters is "36 lowercase hex characters with dashes".
 */

function dashJoined(hex: string): string {
  return `${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-`
    + `${hex.substring(16, 20)}-${hex.substring(20, 32)}`;
}

/** Random uuid v4: version nibble in byte 6, variant bits in byte 8. */
export async function uuidV4(): Promise<string> {
  let bytes: Uint8Array;
  try {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    const blob: cryptoFramework.DataBlob = await random.generateRandom(16);
    bytes = blob.data;
  } catch (e) {
    throw new Error(describePlatformError(e as Object, 'generateRandom(16) for uuid'));
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return dashJoined(hexLower(bytes));
}
