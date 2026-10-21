import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  derBoolean, derBitString, derGeneralizedTime, derIntegerNumber, derIntegerPositiveBytes,
  derNull, derOid, derOctetString, derSequence, derSet, derTlv, derUtf8String, derUtcTime,
  TAG_CONTEXT_0, TAG_CONTEXT_3
} from './Asn1';
import { sha256Bytes } from '../util/Digest';
import { pemArmor } from './PEM';
import { wrapIdentityError } from './IdentityErrors';

/**
 * Self-signed X.509 certificate builder, byte-compatible in *spirit* with the
 * official Rust core (packages/core/src/crypto/cert.rs, rcgen defaults):
 * RSA-2048, issuer == subject == CN "LocalSend User", serial derived from the
 * public-key hash, CA basic constraints, keyCertSign|digitalSignature|
 * keyEncipherment, SHA-256 with RSA (PKCS#1 v1.5). Peers authenticate each
 * other purely by certificate fingerprint, so the fields above are the ones
 * that must match; SANs are intentionally absent.
 */

/** rcgen-compatible validity window (1975..4096) so peers never reject on date checks. */
const NOT_BEFORE_UTC: string = '750101000000Z';
const NOT_AFTER_GENERALIZED: string = '40960101000000Z';

const OID_CN: number[] = [2, 5, 4, 3];
const OID_SHA256_RSA: number[] = [1, 2, 840, 113549, 1, 1, 11]; // sha256WithRSAEncryption
const OID_BASIC_CONSTRAINTS: number[] = [2, 5, 29, 19];
const OID_KEY_USAGE: number[] = [2, 5, 29, 15];

const COMMON_NAME: string = 'LocalSend User';

export class SelfSignedMaterial {
  readonly certDer: Uint8Array;
  readonly certPem: string;
  readonly keyPem: string;
  readonly keyPassword: string;
  /** true when keyPem is an encrypted PKCS#8 (BEGIN ENCRYPTED PRIVATE KEY). */
  readonly keyIsEncrypted: boolean;

  constructor(certDer: Uint8Array, certPem: string, keyPem: string, keyPassword: string, keyIsEncrypted: boolean) {
    this.certDer = certDer;
    this.certPem = certPem;
    this.keyPem = keyPem;
    this.keyPassword = keyPassword;
    this.keyIsEncrypted = keyIsEncrypted;
  }
}

function buildAlgorithmIdentifier(): Uint8Array {
  // SEQUENCE { OID sha256WithRSAEncryption, NULL } — rcgen emits the NULL parameter.
  return derSequence([derOid(OID_SHA256_RSA), derNull()]);
}

function buildName(): Uint8Array {
  // RDNSequence with one RDN: SET { SEQUENCE { OID 2.5.4.3, UTF8String } }.
  const atv: Uint8Array = derSequence([derOid(OID_CN), derUtf8String(COMMON_NAME)]);
  return derSequence([derSet([atv])]);
}

function buildValidity(): Uint8Array {
  // 4096 cannot be represented in UTCTime, so notAfter is GeneralizedTime —
  // exactly what rcgen/der writes for dates outside 1950..2049.
  return derSequence([derUtcTime(NOT_BEFORE_UTC), derGeneralizedTime(NOT_AFTER_GENERALIZED)]);
}

function buildExtensions(): Uint8Array {
  const basicConstraints: Uint8Array = derSequence([derBoolean(true)]);
  const extBasicConstraints: Uint8Array = derSequence([
    derOid(OID_BASIC_CONSTRAINTS),
    derBoolean(true), // critical, per RFC 5280 and rcgen
    derOctetString(basicConstraints)
  ]);
  // KeyUsage bits, MSB-first: digitalSignature(0) | keyEncipherment(2) | keyCertSign(5) = 0xA4.
  const keyUsageBits: Uint8Array = new Uint8Array([0xa4]);
  const extKeyUsage: Uint8Array = derSequence([
    derOid(OID_KEY_USAGE),
    derBoolean(true),
    derOctetString(derBitString(keyUsageBits, 1))
  ]);
  const extensions: Uint8Array = derSequence([extBasicConstraints, extKeyUsage]);
  return derTlv(TAG_CONTEXT_3, extensions);
}

/**
 * Generate an RSA-2048 key pair and a self-signed certificate.
 *
 * Private key export: `priKey.getEncoded()` returns unencrypted PKCS#8 DER
 * (d.ts: "The private key must comply with ... PKCS #8 specifications, and DER
 * encoding"), which we armor as "BEGIN PRIVATE KEY". We deliberately do NOT
 * encrypt it: the HarmonyOS TLS socket option `TLSSecureOptions.key` accepts a
 * PEM string plus an optional `password`, and an encrypted key would force us
 * to carry the password through every socket setup while the PEM already sits
 * in our private app sandbox. `keyPassword` is therefore "" by contract.
 */
export async function generateSelfSigned(): Promise<SelfSignedMaterial> {
  try {
    const generator: cryptoFramework.AsyKeyGenerator = cryptoFramework.createAsyKeyGenerator('RSA2048');
    const keyPair: cryptoFramework.KeyPair = await generator.generateKeyPair();

    // PubKey.getEncoded() is X.509 SubjectPublicKeyInfo DER — embed it verbatim.
    const spkiDer: Uint8Array = keyPair.pubKey.getEncoded().data;
    const pkcs8Der: Uint8Array = keyPair.priKey.getEncoded().data;

    // rcgen default: serial derived from the public key, kept positive.
    const spkiHash: Uint8Array = await sha256Bytes(spkiDer);
    const serial: Uint8Array = derIntegerPositiveBytes(spkiHash.subarray(0, 8));

    const algId: Uint8Array = buildAlgorithmIdentifier();
    const name: Uint8Array = buildName();
    const tbs: Uint8Array = derSequence([
      derTlv(TAG_CONTEXT_0, derIntegerNumber(2)), // v3
      serial,
      algId,
      name, // issuer == subject: self-signed
      buildValidity(),
      name,
      spkiDer,
      buildExtensions()
    ]);

    const signer: cryptoFramework.Sign = cryptoFramework.createSign('RSA2048|PKCS1|SHA256');
    await signer.init(keyPair.priKey);
    const signature: cryptoFramework.DataBlob = await signer.sign({ data: tbs });

    const certDer: Uint8Array = derSequence([
      tbs,
      algId,
      derBitString(signature.data, 0)
    ]);

    const certPem: string = pemArmor('CERTIFICATE', certDer);
    const keyPem: string = pemArmor('PRIVATE KEY', pkcs8Der);
    return new SelfSignedMaterial(certDer, certPem, keyPem, '', false);
  } catch (e) {
    throw wrapIdentityError('x509', 'self-signed certificate generation failed', e as Object);
  }
}
