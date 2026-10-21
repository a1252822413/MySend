/**
 * Byte-level helpers for the socket layer: the HTTP/1.1 parser and the UDP
 * datagram path both need to stitch reads together and find a CRLF boundary.
 * Deliberately free of Kit imports so it can be unit-tested without a device.
 */

/** ASCII CR / LF as code units; the parser compares numbers, not strings. */
export const CR: number = 0x0d;
export const LF: number = 0x0a;

/** First index of `needle` at or after `from`, -1 when it does not occur. */
export function indexOfSequence(haystack: Uint8Array, needle: Uint8Array, from: number): number {
  const start: number = from > 0 ? from : 0;
  const needleLength: number = needle.length;
  if (needleLength === 0) {
    return start < haystack.length ? start : haystack.length;
  }
  const last: number = haystack.length - needleLength;
  for (let i = start; i <= last; i++) {
    let matched: boolean = true;
    for (let j = 0; j < needleLength; j++) {
      if (haystack[i + j] !== needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return i;
    }
  }
  return -1;
}

/** End-to-end copy of `chunks`; empty input yields a zero-length array. */
export function concatBytes(chunks: Uint8Array[]): Uint8Array {
  let total: number = 0;
  for (let i = 0; i < chunks.length; i++) {
    total += chunks[i].length;
  }
  const out: Uint8Array = new Uint8Array(total);
  let offset: number = 0;
  for (let i = 0; i < chunks.length; i++) {
    out.set(chunks[i], offset);
    offset += chunks[i].length;
  }
  return out;
}

/**
 * Decodes header bytes. RFC 9110 pins the request line and headers to
 * ISO-8859-1, so code-unit-per-byte is the correct mapping here; UTF-8 never
 * reaches this function.
 */
export function asciiDecode(bytes: Uint8Array): string {
  let text: string = '';
  for (let i = 0; i < bytes.length; i++) {
    text += String.fromCharCode(bytes[i]);
  }
  return text;
}

/** `asciiDecode` inverse; code units above 0xff are truncated, so ASCII-only. */
export function asciiEncode(text: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    out[i] = text.charCodeAt(i) & 0xff;
  }
  return out;
}

/**
 * Growable byte buffer with a compacted front: `consume` shifts the remaining
 * bytes down, so a partially received HTTP message can be appended to without
 * ever holding a stale prefix.
 */
export class ByteBuffer {
  private data: Uint8Array;
  private size: number = 0;

  constructor(initialCapacity?: number) {
    let capacity: number = 1024;
    if (initialCapacity !== undefined && initialCapacity > capacity) {
      capacity = initialCapacity;
    }
    this.data = new Uint8Array(capacity);
  }

  get length(): number {
    return this.size;
  }

  append(bytes: Uint8Array): void {
    const needed: number = this.size + bytes.length;
    if (needed > this.data.length) {
      let capacity: number = this.data.length === 0 ? 64 : this.data.length;
      while (capacity < needed) {
        capacity *= 2;
      }
      const grown: Uint8Array = new Uint8Array(capacity);
      grown.set(this.data, 0);
      this.data = grown;
    }
    this.data.set(bytes, this.size);
    this.size = needed;
  }

  /** Drops the first `n` bytes; `n` beyond what is held drops everything. */
  consume(n: number): void {
    if (n <= 0) {
      return;
    }
    const taken: number = n < this.size ? n : this.size;
    this.data.copyWithin(0, taken, this.size);
    this.size -= taken;
  }

  /** Copy of `[from, to)` clamped to what is held. */
  slice(from: number, to: number): Uint8Array {
    const start: number = from > 0 && from < this.size ? from : 0;
    const end: number = to > this.size || to < 0 ? this.size : to;
    const out: Uint8Array = new Uint8Array(end > start ? end - start : 0);
    out.set(this.data.subarray(start, end), 0);
    return out;
  }

  /** All buffered bytes as a copy; the parser never sees the internal array. */
  peek(): Uint8Array {
    return this.slice(0, this.size);
  }

  /** Byte at `index` of the live region, -1 when out of range. */
  at(index: number): number {
    if (index < 0 || index >= this.size) {
      return -1;
    }
    return this.data[index];
  }

  indexOf(needle: Uint8Array, from: number): number {
    const start: number = from > 0 ? from : 0;
    const needleLength: number = needle.length;
    if (needleLength === 0) {
      return start;
    }
    for (let i = start; i + needleLength <= this.size; i++) {
      let matched: boolean = true;
      for (let j = 0; j < needleLength; j++) {
        if (this.data[i + j] !== needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return i;
      }
    }
    return -1;
  }
}

const CRLF_BYTES: Uint8Array = new Uint8Array([CR, LF]);

/** Index of the next CRLF at or after `from`, -1 when no line is complete. */
export function findCrlf(buffer: ByteBuffer, from: number): number {
  return buffer.indexOf(CRLF_BYTES, from);
}

/**
 * Removes and returns one CRLF-terminated line, CRLF excluded. Returns null
 * when the terminator has not arrived yet, leaving the buffer untouched so the
 * caller can keep appending.
 */
export function readCrlfLine(buffer: ByteBuffer): Uint8Array | null {
  const end: number = buffer.indexOf(CRLF_BYTES, 0);
  if (end === -1) {
    return null;
  }
  const line: Uint8Array = buffer.slice(0, end);
  buffer.consume(end + 2);
  return line;
}

/** `readCrlfLine` decoded as header text; null while the line is incomplete. */
export function readCrlfLineAsString(buffer: ByteBuffer): string | null {
  const line: Uint8Array | null = readCrlfLine(buffer);
  if (line === null) {
    return null;
  }
  return asciiDecode(line);
}
