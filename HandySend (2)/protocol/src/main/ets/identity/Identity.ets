import { generateSelfSigned } from './X509SelfSigned';
import { certFingerprint, randomFingerprintHex } from './Fingerprint';
import { wrapIdentityError } from './IdentityErrors';

/** The scheme we must advertise on the wire and use for HTTP+TLS sockets. */
export type IdentityScheme = 'http' | 'https';

/**
 * Alias-independent device identity. The alias ("Peng's phone") can change
 * freely; this material must stay stable for the device's whole life because
 * the fingerprint is how peers recognize and authenticate us.
 */
export class Identity {
  readonly certDer: Uint8Array;
  readonly certPem: string;
  readonly keyPem: string;
  /** Password for an encrypted PKCS#8 key; "" for our unencrypted choice. */
  readonly keyPassword: string;
  /** Uppercase hex SHA-256 of certDer (encryption on) or a random string (off). */
  readonly fingerprint: string;
  readonly scheme: IdentityScheme;

  constructor(certDer: Uint8Array, certPem: string, keyPem: string, keyPassword: string,
    fingerprint: string, scheme: IdentityScheme) {
    this.certDer = certDer;
    this.certPem = certPem;
    this.keyPem = keyPem;
    this.keyPassword = keyPassword;
    this.fingerprint = fingerprint;
    this.scheme = scheme;
  }

  get isHttps(): boolean {
    return this.scheme === 'https';
  }

  /** Full mTLS identity: fresh RSA-2048 key pair + self-signed certificate. */
  static async generate(): Promise<Identity> {
    const material = await generateSelfSigned();
    const fingerprint = await certFingerprint(material.certDer);
    return new Identity(material.certDer, material.certPem, material.keyPem,
      material.keyPassword, fingerprint, 'https');
  }

  /**
   * Encryption-off mode: no certificate at all, the announcement carries a
   * random fingerprint. The string must be persisted by the caller so the
   * device keeps one identity across restarts.
   */
  static httpOnly(fingerprint: string): Identity {
    return new Identity(new Uint8Array(0), '', '', '', fingerprint, 'http');
  }

  /** Random uppercase-hex fingerprint for a brand-new http-only device. */
  static async randomFingerprint(): Promise<string> {
    try {
      return await randomFingerprintHex(32);
    } catch (e) {
      throw wrapIdentityError('identity', 'failed to create random fingerprint', e as Object);
    }
  }
}
