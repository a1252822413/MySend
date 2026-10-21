import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hexUpper, sha256Hex } from '../util/Digest';
import { wrapIdentityError } from './IdentityErrors';

/**
 * Identity-facing digest helpers. The digest primitives themselves live in
 * `util/Digest`; this module only fixes the alphabet LocalSend uses:
 * uppercase hex is the wire `fingerprint` (SHA-256 of the certificate DER, see
 * packages/core/src/crypto/cert.rs in the official client), while file checksums
 * stay lowercase.
 */

export async function certFingerprint(certDer: Uint8Array): Promise<string> {
  return await sha256Hex(certDer, true);
}

/** Cryptographically random uppercase hex string of `bytes` bytes. Used for
 * the random fingerprint in encryption-off (HTTP) mode. */
export async function randomFingerprintHex(bytes: number): Promise<string> {
  try {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    const blob: cryptoFramework.DataBlob = await random.generateRandom(bytes);
    return hexUpper(blob.data);
  } catch (e) {
    throw wrapIdentityError('fingerprint', 'random fingerprint generation failed', e as Object);
  }
}
