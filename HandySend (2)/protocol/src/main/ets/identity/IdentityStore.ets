import { Identity } from './Identity';
import { pemDearmor } from './PEM';
import { certFingerprint } from './Fingerprint';
import { wrapIdentityError } from './IdentityErrors';

/**
 * Persistence contract injected by the app: the protocol HAR must not know
 * how (or where) the identity is stored, only that it survives restarts.
 */
export interface StoredIdentity {
  certPem: string;
  keyPem: string;
  keyPassword: string;
  fingerprint: string;
}

export interface IdentityStore {
  load(): Promise<StoredIdentity | null>;

  save(identity: StoredIdentity): Promise<void>;
}

/**
 * Get-or-create semantics matching the official clients: ONE identity per
 * device, generated on first launch, reused forever. Fingerprint rule:
 * encryption on  -> SHA-256 (uppercase hex) of the certificate DER;
 * encryption off -> a persisted random string.
 */
export class IdentityRepository {
  private readonly store: IdentityStore;

  constructor(store: IdentityStore) {
    this.store = store;
  }

  async resolve(encryptionEnabled: boolean, fallbackFingerprint: string): Promise<Identity> {
    const stored: StoredIdentity | null = await this.load();
    if (!encryptionEnabled) {
      return this.resolveHttpOnly(stored, fallbackFingerprint);
    }
    if (stored !== null && stored.certPem.length > 0 && stored.keyPem.length > 0) {
      const rebuilt: Identity | null = await this.rebuild(stored);
      if (rebuilt !== null) {
        return rebuilt;
      }
      // Corrupt/unparsable certificate: fall through and regenerate once.
    }
    const fresh: Identity = await Identity.generate();
    const saved: StoredIdentity = {
      certPem: fresh.certPem,
      keyPem: fresh.keyPem,
      keyPassword: fresh.keyPassword,
      fingerprint: fresh.fingerprint
    };
    await this.save(saved);
    return fresh;
  }

  private async resolveHttpOnly(stored: StoredIdentity | null, fallbackFingerprint: string): Promise<Identity> {
    if (stored !== null && stored.fingerprint.length > 0) {
      return Identity.httpOnly(stored.fingerprint);
    }
    let fingerprint: string = fallbackFingerprint;
    if (fingerprint.length === 0) {
      fingerprint = await Identity.randomFingerprint();
    }
    const saved: StoredIdentity = {
      certPem: '',
      keyPem: '',
      keyPassword: '',
      fingerprint: fingerprint
    };
    await this.save(saved);
    return Identity.httpOnly(fingerprint);
  }

  /** Returns null when the stored PEM cannot be parsed or its fingerprint fails to compute. */
  private async rebuild(stored: StoredIdentity): Promise<Identity | null> {
    try {
      const certDer: Uint8Array = pemDearmor(stored.certPem, 'CERTIFICATE');
      const fingerprint: string = await certFingerprint(certDer);
      return new Identity(certDer, stored.certPem, stored.keyPem, stored.keyPassword, fingerprint, 'https');
    } catch (e) {
      return null;
    }
  }

  private async load(): Promise<StoredIdentity | null> {
    try {
      return await this.store.load();
    } catch (e) {
      throw wrapIdentityError('store', 'loading the stored identity failed', e as Object);
    }
  }

  private async save(identity: StoredIdentity): Promise<void> {
    try {
      await this.store.save(identity);
    } catch (e) {
      throw wrapIdentityError('store', 'persisting the identity failed', e as Object);
    }
  }
}
