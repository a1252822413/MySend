/**
 * Minimal ASN.1 DER writer + reader. Pure (no Kits, no I/O) so it can be used
 * both by the X.509 builder and by headless unit tests.
 *
 * Only the subset required for a self-signed RSA certificate is implemented:
 * definite-length DER, single- and multi-byte tags, no indefinite lengths.
 */

export const TAG_BOOLEAN: number = 0x01;
export const TAG_INTEGER: number = 0x02;
export const TAG_BIT_STRING: number = 0x03;
export const TAG_OCTET_STRING: number = 0x04;
export const TAG_NULL: number = 0x05;
export const TAG_OID: number = 0x06;
export const TAG_UTF8_STRING: number = 0x0c;
export const TAG_PRINTABLE_STRING: number = 0x13;
export const TAG_UTC_TIME: number = 0x17;
export const TAG_GENERALIZED_TIME: number = 0x18;
export const TAG_SEQUENCE: number = 0x30;
export const TAG_SET: number = 0x31;
export const TAG_CONTEXT_0: number = 0xa0; // [0] EXPLICIT (TBS version)
export const TAG_CONTEXT_3: number = 0xa3; // [3] EXPLICIT (certificate extensions)

export function concatAll(parts: Uint8Array[]): Uint8Array {
  let total: number = 0;
  for (let i = 0; i < parts.length; i++) {
    total += parts[i].length;
  }
  const out: Uint8Array = new Uint8Array(total);
  let offset: number = 0;
  for (let i = 0; i < parts.length; i++) {
    out.set(parts[i], offset);
    offset += parts[i].length;
  }
  return out;
}

/** DER definite length: short form below 0x80, minimal long form above. */
export function encodeDerLength(len: number): Uint8Array {
  if (len < 0) {
    throw new Error(`Asn1: negative length ${len}`);
  }
  if (len < 0x80) {
    return new Uint8Array([len]);
  }
  const reversed: number[] = [];
  let n: number = len;
  while (n > 0) {
    reversed.push(n & 0xff);
    n = Math.floor(n / 256);
  }
  const out: Uint8Array = new Uint8Array(reversed.length + 1);
  out[0] = 0x80 | reversed.length;
  for (let i = 0; i < reversed.length; i++) {
    out[i + 1] = reversed[reversed.length - 1 - i];
  }
  return out;
}

/** Wrap an already-encoded value into a single-byte-tag TLV. */
export function derTlv(tag: number, value: Uint8Array): Uint8Array {
  return concatAll([new Uint8Array([tag]), encodeDerLength(value.length), value]);
}

export function derSequence(items: Uint8Array[]): Uint8Array {
  return derTlv(TAG_SEQUENCE, concatAll(items));
}

export function derSet(items: Uint8Array[]): Uint8Array {
  return derTlv(TAG_SET, concatAll(items));
}

export function derNull(): Uint8Array {
  return derTlv(TAG_NULL, new Uint8Array(0));
}

/**
 * INTEGER from a non-negative number. Only used for small values here
 * (version marker 2); ArkTS number is sufficient.
 */
export function derIntegerNumber(value: number): Uint8Array {
  if (!Number.isInteger(value) || value < 0) {
    throw new Error('Asn1: derIntegerNumber requires a non-negative integer');
  }
  const bytes: number[] = [];
  let n: number = value;
  if (n === 0) {
    bytes.push(0);
  }
  while (n > 0) {
    bytes.unshift(n & 0xff);
    n = Math.floor(n / 256);
  }
  if (bytes[0] & 0x80) {
    bytes.unshift(0); // keep the INTEGER positive
  }
  const arr: Uint8Array = new Uint8Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    arr[i] = bytes[i];
  }
  return derTlv(TAG_INTEGER, arr);
}

/** INTEGER from big-endian magnitude bytes; normalized to canonical DER. */
export function derIntegerPositiveBytes(magnitude: Uint8Array): Uint8Array {
  let start: number = 0;
  while (start < magnitude.length - 1 && magnitude[start] === 0) {
    start++;
  }
  const trimmed: Uint8Array = magnitude.subarray(start);
  let value: Uint8Array;
  if (trimmed.length === 0 || (trimmed[0] & 0x80) !== 0) {
    value = new Uint8Array(trimmed.length + 1);
    value[0] = 0;
    value.set(trimmed, 1);
  } else if (trimmed.length === 1 && trimmed[0] === 0) {
    value = trimmed;
  } else {
    value = trimmed;
  }
  return derTlv(TAG_INTEGER, value);
}

export function derBoolean(value: boolean): Uint8Array {
  return derTlv(TAG_BOOLEAN, new Uint8Array([value ? 0xff : 0x00]));
}

export function derBitString(bytes: Uint8Array, unusedBits: number): Uint8Array {
  const value: Uint8Array = new Uint8Array(bytes.length + 1);
  value[0] = unusedBits;
  value.set(bytes, 1);
  return derTlv(TAG_BIT_STRING, value);
}

export function derOctetString(bytes: Uint8Array): Uint8Array {
  return derTlv(TAG_OCTET_STRING, bytes);
}

/** OBJECT IDENTIFIER from dotted arcs, e.g. [2, 5, 4, 3] for CN. */
export function derOid(arcs: number[]): Uint8Array {
  if (arcs.length < 2 || arcs[0] > 2) {
    throw new Error('Asn1: OID must start with arc 0..2');
  }
  const out: number[] = [];
  out.push(arcs[0] * 40 + arcs[1]);
  for (let i = 2; i < arcs.length; i++) {
    const arc: number = arcs[i];
    if (!Number.isInteger(arc) || arc < 0) {
      throw new Error('Asn1: OID arcs must be non-negative integers');
    }
    // base-128, big-endian, high bit = continuation
    const chunk: number[] = [];
    let n: number = arc;
    chunk.unshift(n & 0x7f);
    n = Math.floor(n / 128);
    while (n > 0) {
      chunk.unshift((n & 0x7f) | 0x80);
      n = Math.floor(n / 128);
    }
    for (let j = 0; j < chunk.length; j++) {
      out.push(chunk[j]);
    }
  }
  const arr: Uint8Array = new Uint8Array(out.length);
  for (let i = 0; i < out.length; i++) {
    arr[i] = out[i];
  }
  return derTlv(TAG_OID, arr);
}

/** Pure UTF-8 encoder (no Kits) for ASN.1 string leaf values. */
export function utf8Bytes(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let cp: number = s.charCodeAt(i);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < s.length) {
      const low: number = s.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
        i++;
      }
    }
    if (cp < 0x80) {
      out.push(cp);
    } else if (cp < 0x800) {
      out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
      out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    } else {
      out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    }
  }
  const arr: Uint8Array = new Uint8Array(out.length);
  for (let i = 0; i < out.length; i++) {
    arr[i] = out[i];
  }
  return arr;
}

export function asciiBytes(s: string): Uint8Array {
  const arr: Uint8Array = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c > 0x7f) {
      throw new Error('Asn1: non-ASCII character in ASCII-only string');
    }
    arr[i] = c;
  }
  return arr;
}

export function derUtf8String(s: string): Uint8Array {
  return derTlv(TAG_UTF8_STRING, utf8Bytes(s));
}

export function derPrintableString(s: string): Uint8Array {
  return derTlv(TAG_PRINTABLE_STRING, asciiBytes(s));
}

/** UTCTime carries the already-formatted "YYMMDDHHMMSSZ" string. */
export function derUtcTime(utc: string): Uint8Array {
  return derTlv(TAG_UTC_TIME, asciiBytes(utc));
}

/** GeneralizedTime carries the already-formatted "YYYYMMDDHHMMSSZ" string. */
export function derGeneralizedTime(gen: string): Uint8Array {
  return derTlv(TAG_GENERALIZED_TIME, asciiBytes(gen));
}

/**
 * A parsed DER element: the tag byte(s) collapse to `tag` (single-byte tags
 * keep their 0x00..0xff value; multi-byte tags are flagged by `multiByteTag`
 * and `tagContinuations` carries the trailing tag octets). `value` is a
 * zero-copy view into the source buffer. `next` is the offset just past this
 * TLV in the source buffer.
 */
export class DerTlv {
  readonly tag: number;
  readonly value: Uint8Array;
  readonly next: number;

  constructor(tag: number, value: Uint8Array, next: number) {
    this.tag = tag;
    this.value = value;
    this.next = next;
  }
}

/** Read one TLV starting at `offset`. Throws on malformed DER. */
export function readDerTlv(buf: Uint8Array, offset: number): DerTlv {
  if (offset < 0 || offset >= buf.length) {
    throw new Error('Asn1: read offset out of bounds');
  }
  let pos: number = offset;
  let tag: number = buf[pos];
  pos++;
  if ((tag & 0x1f) === 0x1f) {
    // multi-byte tag: consume continuation octets, keep only the first class/P-con byte
    while (pos < buf.length && (buf[pos] & 0x80) !== 0) {
      pos++;
    }
    if (pos >= buf.length) {
      throw new Error('Asn1: truncated multi-byte tag');
    }
    pos++; // final tag octet
  }
  if (pos >= buf.length) {
    throw new Error('Asn1: truncated length octet');
  }
  const first: number = buf[pos];
  pos++;
  let len: number = 0;
  if (first < 0x80) {
    len = first;
  } else if (first === 0x80) {
    throw new Error('Asn1: indefinite length is not valid DER');
  } else {
    const count: number = first & 0x7f;
    if (count > 4 || pos + count > buf.length) {
      throw new Error('Asn1: unsupported or truncated length encoding');
    }
    for (let i = 0; i < count; i++) {
      len = len * 256 + buf[pos + i];
    }
    pos += count;
  }
  if (pos + len > buf.length) {
    throw new Error('Asn1: value exceeds buffer');
  }
  return new DerTlv(tag, buf.subarray(pos, pos + len), pos + len);
}

/** Walk the children of a constructed TLV (SEQUENCE/SET/[0]/[3]/...). */
export function readDerChildren(parent: DerTlv): DerTlv[] {
  const children: DerTlv[] = [];
  let off: number = 0;
  while (off < parent.value.length) {
    const child: DerTlv = readDerTlv(parent.value, off);
    children.push(child);
    off = child.next;
  }
  return children;
}

export function indexOfBytes(haystack: Uint8Array, needle: Uint8Array, from: number): number {
  if (needle.length === 0 || haystack.length - from < needle.length) {
    return -1;
  }
  for (let i = from; i + needle.length <= haystack.length; i++) {
    let hit: boolean = true;
    for (let j = 0; j < needle.length; j++) {
      if (haystack[i + j] !== needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) {
      return i;
    }
  }
  return -1;
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

/** Lowercase hex, e.g. '300d0609...'. Handy in golden tests. */
export function bytesToHexLower(bytes: Uint8Array): string {
  const digits: string = '0123456789abcdef';
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    out += digits.charAt((bytes[i] >> 4) & 0x0f);
    out += digits.charAt(bytes[i] & 0x0f);
  }
  return out;
}

export function hexToBytes(hex: string): Uint8Array {
  if (hex.length % 2 !== 0) {
    throw new Error('Asn1: hex string must have even length');
  }
  const out: Uint8Array = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}
