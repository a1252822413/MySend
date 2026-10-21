import { describe, it, expect } from '@ohos/hypium';
import {
  bytesEqual, bytesToHexLower, derBoolean, derIntegerNumber, derNull, derOid, derSequence,
  DerTlv, encodeDerLength, hexToBytes, indexOfBytes, readDerChildren, readDerTlv, TAG_UTF8_STRING
} from '../../main/ets/identity/Asn1';
import { pemArmor, pemDearmor } from '../../main/ets/identity/PEM';
import { generateSelfSigned, SelfSignedMaterial } from '../../main/ets/identity/X509SelfSigned';
import { sha256HexUpper } from '../../main/ets/identity/Fingerprint';

// Certificate fixture copied from the official Rust core
// (packages/core/src/crypto/cert.rs test vectors) with its known SHA-256
// fingerprint — pins our hash + uppercase-hex rendering to the wire format.
const RUST_TEST_CERT_PEM: string =
  '-----BEGIN CERTIFICATE-----\n' +
  'MIIDGTCCAgGgAwIBAgIBATANBgkqhkiG9w0BAQsFADBQMRcwFQYDVQQDEw5Mb2Nh\n' +
  'bFNlbmQgVXNlcjEJMAcGA1UEChMAMQkwBwYDVQQLEwAxCTAHBgNVBAcTADEJMAcG\n' +
  'A1UECBMAMQkwBwYDVQQGEwAwHhcNMjUwMjA5MDAwMzE0WhcNMzUwMjA3MDAwMzE0\n' +
  'WjBQMRcwFQYDVQQDEw5Mb2NhbFNlbmQgVXNlcjEJMAcGA1UEChMAMQkwBwYDVQQL\n' +
  'EwAxCTAHBgNVBAcTADEJMAcGA1UECBMAMQkwBwYDVQQGEwAwggEiMA0GCSqGSIb3\n' +
  'DQEBAQUAA4IBDwAwggEKAoIBAQCL24MxhGfrdJm0Q8ZGiBkZ27ldcEChB4w7rSbJ\n' +
  'yiKeosoNbJl2kyj5dZjfBhWGgDLGDMM5w+Mh/5SrWgTL/QrhbB+lsrxILLznWqBi\n' +
  'R8wJP0P2YW9fBahQskJQcUXt/3jsCsMTWea4rWc3HZGh03bAkJfLM+PDSOfTpvAZ\n' +
  '6DQSp9QLzC9bgVNnq3W0SvOZGpF0xRa4InCyTUgxsNsV4+GIrmN5w4EbRFVVYu7D\n' +
  '5OS5fxNSCukiS0fb6oQzUp0vIAycvvWHHbAy8T6UMoUor2nfvNcryiaOX5WBMLyh\n' +
  'yMZ5gMOyXjdm1bT1XSlvtXPYUzxvsGAzTqS8mXjw8h7mm5htAgMBAAEwDQYJKoZI\n' +
  'hvcNAQELBQADggEBABZ+I7D6wkeSrsi1NBLP2zoZ5oGh+INNcGTravfOQHs4Fbas\n' +
  '/CysaUYjsD3fmaDh4MxgWEqAmWnnBiojfpGX2SGuFqRBKyT9DgitBt0L7Ezg1k3h\n' +
  'bfSiFW4hXWp75grVO8xfML7ZcWMlhKrOsOMUGiy1qs3qsyJ3w7B2Tz78HhXGO5dd\n' +
  'jyPmZarhixKO92UpEvKGxjO0E/3UUNUzxKTAAgFfhKpuwHUgIijM/EppZtA8OcSh\n' +
  'fEztiV0xKfcPVx4d6dqRt/NMElK1Ivw2vUuxTymphZkkFOzht9m73/kyKaeFp8Ij\n' +
  'VRus1zGVD8IVpIdPMyz01WJyS7M0fWaHXKWo+Bo=\n' +
  '-----END CERTIFICATE-----\n';

const RUST_TEST_CERT_FINGERPRINT: string =
  '4BADDE53A7F7CDEEED93189FD898E02BF6B4806CA4C05DE0ACE08319B86552FA';

function isUpperHex(s: string): boolean {
  for (let i = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    const digit: boolean = c >= 0x30 && c <= 0x39;
    const upper: boolean = c >= 0x41 && c <= 0x46;
    if (!digit && !upper) {
      return false;
    }
  }
  return true;
}

/** Walk a Name (RDNSequence) and return the first CN value as a string. */
function readCommonName(name: DerTlv): string {
  const rdns: DerTlv[] = readDerChildren(name);
  for (let i = 0; i < rdns.length; i++) {
    const atvs: DerTlv[] = readDerChildren(rdns[i]); // SET -> [SEQUENCE]
    for (let j = 0; j < atvs.length; j++) {
      const pair: DerTlv[] = readDerChildren(atvs[j]); // OID + value
      if (pair.length === 2 && pair[1].tag === TAG_UTF8_STRING) {
        let s: string = '';
        for (let k = 0; k < pair[1].value.length; k++) {
          s += String.fromCharCode(pair[1].value[k]);
        }
        return s;
      }
    }
  }
  return '';
}

export default function x509Test() {
  describe('X509SelfSignedTest', () => {
    it('golden_sha256WithRSAAlgorithmIdentifier', 0, () => {
      const algId: Uint8Array = derSequence([derOid([1, 2, 840, 113549, 1, 1, 11]), derNull()]);
      expect(bytesToHexLower(algId)).assertEqual('300d06092a864886f70d01010b0500');
    });

    it('golden_length_integer_boolean', 0, () => {
      expect(bytesToHexLower(encodeDerLength(0x7f))).assertEqual('7f');
      expect(bytesToHexLower(encodeDerLength(300))).assertEqual('82012c');
      expect(bytesToHexLower(derIntegerNumber(2))).assertEqual('020102');
      expect(bytesToHexLower(derBoolean(true))).assertEqual('0101ff');
    });

    it('pem_armorDearmor_roundTrip', 0, () => {
      const original: Uint8Array = new Uint8Array(500);
      for (let i = 0; i < original.length; i++) {
        original[i] = i & 0xff;
      }
      const armored: string = pemArmor('TEST BLOCK', original);
      expect(armored.indexOf('-----BEGIN TEST BLOCK-----\n') >= 0).assertTrue();
      // Body lines must never exceed 64 characters.
      const lines: string[] = armored.split('\n');
      for (let i = 0; i < lines.length; i++) {
        expect(lines[i].length <= 64).assertTrue();
      }
      const back: Uint8Array = pemDearmor(armored, 'TEST BLOCK');
      expect(bytesEqual(back, original)).assertTrue();
    });

    it('fingerprint_officialRustVector', 0, async () => {
      const der: Uint8Array = pemDearmor(RUST_TEST_CERT_PEM, 'CERTIFICATE');
      const fp: string = await sha256HexUpper(der);
      expect(fp).assertEqual(RUST_TEST_CERT_FINGERPRINT);
    });

    it('generate_cert_parsesBack_withLocalSendUserNames', 0, async () => {
      const material: SelfSignedMaterial = await generateSelfSigned();
      const cert: DerTlv = readDerTlv(material.certDer, 0);
      const top: DerTlv[] = readDerChildren(cert);
      expect(top.length).assertEqual(3); // tbs, signatureAlgorithm, signature
      const tbsChildren: DerTlv[] = readDerChildren(top[0]);
      expect(tbsChildren.length).assertEqual(8);
      expect(readCommonName(tbsChildren[3])).assertEqual('LocalSend User'); // issuer
      expect(readCommonName(tbsChildren[5])).assertEqual('LocalSend User'); // subject
    });

    it('generate_fingerprintIs64UppercaseHex', 0, async () => {
      const material: SelfSignedMaterial = await generateSelfSigned();
      const fp: string = await sha256HexUpper(material.certDer);
      expect(fp.length).assertEqual(64);
      expect(isUpperHex(fp)).assertTrue();
    });

    it('generate_basicConstraintsCaTrue', 0, async () => {
      const material: SelfSignedMaterial = await generateSelfSigned();
      // OID 2.5.29.19 = 06 03 55 1D 13; our builder encodes it critical and
      // wraps BasicConstraints { cA TRUE }, so the exact following bytes are:
      // 01 01 FF (critical) 04 05 (octet string len) 30 03 01 01 FF (SEQ{BOOL}).
      const oid: Uint8Array = hexToBytes('0603551d13');
      const pos: number = indexOfBytes(material.certDer, oid, 0);
      expect(pos >= 0).assertTrue();
      const tail: Uint8Array = material.certDer.subarray(pos + oid.length, pos + oid.length + 12);
      expect(bytesToHexLower(tail)).assertEqual('0101ff040530030101ff');
    });
  });
}
