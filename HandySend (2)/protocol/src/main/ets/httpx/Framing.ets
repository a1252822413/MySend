import { BodyFraming } from './Http';

const CR: number = 0x0d;
const LF: number = 0x0a;

/**
 * FIFO of bytes with the operations the HTTP framing state machine needs: take a bounded run, or
 * read one CRLF-terminated line.
 *
 * Sockets hand over arbitrarily sized chunks and a chunk-size line or a CRLF can straddle two of
 * them, so every read has to be able to say "not enough bytes yet" without losing what it consumed.
 */
export class ByteQueue {
  private chunks: Uint8Array[] = [];
  private headOffset: number = 0;
  private total: number = 0;

  get size(): number {
    return this.total;
  }

  append(bytes: Uint8Array): void {
    if (bytes.length === 0) {
      return;
    }
    this.chunks.push(bytes);
    this.total += bytes.length;
  }

  private compactHead(): void {
    while (this.chunks.length > 0 && this.headOffset >= this.chunks[0].length) {
      this.headOffset -= this.chunks[0].length;
      this.chunks.shift();
    }
    if (this.chunks.length === 0) {
      this.headOffset = 0;
    }
  }

  /** Byte at an offset from the front, or -1 when the queue is shorter. */
  byteAt(offset: number): number {
    if (offset >= this.total) {
      return -1;
    }
    let skipped: number = this.headOffset;
    for (let i = 0; i < this.chunks.length; i++) {
      const chunk: Uint8Array = this.chunks[i];
      const usable: number = chunk.length - (i === 0 ? this.headOffset : 0);
      if (offset < skipped + usable) {
        return chunk[(i === 0 ? this.headOffset : 0) + (offset - skipped)];
      }
      skipped += usable;
    }
    return -1;
  }

  /** Longest common prefix length of `needle` starting at offset 0 of the queue. */
  private matchesAt(needle: Uint8Array): boolean {
    for (let i = 0; i < needle.length; i++) {
      if (this.byteAt(i) !== needle[i]) {
        return false;
      }
    }
    return true;
  }

  startsWith(bytes: Uint8Array): boolean {
    return this.total >= bytes.length && this.matchesAt(bytes);
  }

  /** Index of the first CRLF at or after `from`, or -1. */
  indexOfCrlf(from: number): number {
    let index: number = from;
    while (index + 1 < this.total) {
      if (this.byteAt(index) === CR && this.byteAt(index + 1) === LF) {
        return index;
      }
      index++;
    }
    return -1;
  }

  /**
   * Offset just past the first CRLFCRLF (the end of an HTTP head), or -1 when it has not arrived.
   * A lone CRLF only terminates one line, so a header split across two socket reads must not match.
   */
  indexOfDoubleCrlf(): number {
    let index: number = 0;
    while (index + 3 < this.total) {
      if (this.byteAt(index) === CR && this.byteAt(index + 1) === LF
        && this.byteAt(index + 2) === CR && this.byteAt(index + 3) === LF) {
        return index + 4;
      }
      index++;
    }
    return -1;
  }

  take(count: number): Uint8Array | null {
    const take: number = count > this.total ? this.total : count;
    if (take <= 0) {
      return null;
    }
    const out: Uint8Array = new Uint8Array(take);
    let written: number = 0;
    while (written < take) {
      this.compactHead();
      if (this.chunks.length === 0) {
        break;
      }
      const front: Uint8Array = this.chunks[0];
      const available: number = front.length - this.headOffset;
      const want: number = take - written;
      const n: number = available < want ? available : want;
      out.set(front.subarray(this.headOffset, this.headOffset + n), written);
      written += n;
      this.headOffset += n;
      this.total -= n;
      if (this.headOffset >= front.length) {
        this.headOffset = 0;
        this.chunks.shift();
      }
    }
    return out;
  }

  /** Consumes a CRLF-terminated line and returns it without the terminator, or null if incomplete. */
  takeLine(maxLength: number): Uint8Array | null {
    const end: number = this.indexOfCrlf(0);
    if (end < 0) {
      if (this.total > maxLength) {
        return new Uint8Array(0);
      }
      return null;
    }
    if (end > maxLength) {
      return new Uint8Array(0);
    }
    const line: Uint8Array | null = this.take(end);
    this.take(2);
    return line === null ? new Uint8Array(0) : line;
  }

  clear(): void {
    this.chunks = [];
    this.headOffset = 0;
    this.total = 0;
  }
}

export function asciiToBytes(text: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    out[i] = text.charCodeAt(i) & 0xff;
  }
  return out;
}

export function bytesToAscii(bytes: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

/**
 * Strips body framing so that consumers only ever see payload bytes.
 *
 * `read` returns:
 * - a non-empty Uint8Array of payload;
 * - an empty Uint8Array when more input is required;
 * - null when the body is finished.
 */
export class BodyDecoder {
  private framing: BodyFraming;
  private remaining: number;
  private chunkRemaining: number = 0;
  private inTrailer: boolean = false;
  private finished: boolean = false;
  private failed: boolean = false;

  constructor(framing: BodyFraming, contentLength: number) {
    this.framing = framing;
    this.remaining = framing === BodyFraming.FIXED ? contentLength : 0;
    if (framing === BodyFraming.NONE) {
      this.finished = true;
    }
  }

  isFinished(): boolean {
    return this.finished;
  }

  isFailed(): boolean {
    return this.failed;
  }

  /** Bytes of payload consumed so far, for progress accounting. */
  read(queue: ByteQueue, maxBytes: number): Uint8Array | null {
    if (this.failed) {
      return null;
    }
    if (this.finished) {
      return null;
    }
    if (this.framing === BodyFraming.FIXED) {
      return this.readFixed(queue, maxBytes);
    }
    if (this.framing === BodyFraming.CHUNKED) {
      return this.readChunked(queue, maxBytes);
    }
    this.finished = true;
    return null;
  }

  private readFixed(queue: ByteQueue, maxBytes: number): Uint8Array | null {
    if (this.remaining <= 0) {
      this.finished = true;
      return null;
    }
    if (queue.size === 0) {
      return new Uint8Array(0);
    }
    const want: number = this.remaining < maxBytes ? this.remaining : maxBytes;
    const taken: Uint8Array | null = queue.take(want);
    if (taken === null || taken.length === 0) {
      return new Uint8Array(0);
    }
    this.remaining -= taken.length;
    if (this.remaining <= 0) {
      this.finished = true;
    }
    return taken;
  }

  private readChunked(queue: ByteQueue, maxBytes: number): Uint8Array | null {
    while (true) {
      if (this.inTrailer) {
        const line: Uint8Array | null = queue.takeLine(1024);
        if (line === null) {
          return new Uint8Array(0);
        }
        if (line.length === 0) {
          this.finished = true;
          return null;
        }
        continue;
      }
      if (this.chunkRemaining === 0) {
        const sizeLine: Uint8Array | null = queue.takeLine(128);
        if (sizeLine === null) {
          return new Uint8Array(0);
        }
        const size: number = BodyDecoder.parseChunkSize(bytesToAscii(sizeLine));
        if (size < 0) {
          this.failed = true;
          return null;
        }
        if (size === 0) {
          // Consume the optional trailer part, then CRLFCRLF ends the message.
          this.inTrailer = true;
          continue;
        }
        this.chunkRemaining = size;
      }
      if (queue.size === 0) {
        return new Uint8Array(0);
      }
      const want: number = this.chunkRemaining < maxBytes ? this.chunkRemaining : maxBytes;
      const taken: Uint8Array | null = queue.take(want);
      if (taken === null || taken.length === 0) {
        return new Uint8Array(0);
      }
      this.chunkRemaining -= taken.length;
      if (this.chunkRemaining === 0) {
        // Each chunk is followed by CRLF; drop it before the next size line.
        const crlf: Uint8Array | null = queue.take(2);
        if (crlf !== null && crlf.length === 2 && (crlf[0] !== CR || crlf[1] !== LF)) {
          this.failed = true;
          return null;
        }
      }
      return taken;
    }
  }

  private static parseChunkSize(line: string): number {
    const semi: number = line.indexOf(';');
    const hex: string = (semi >= 0 ? line.substring(0, semi) : line).trim();
    if (hex.length === 0) {
      return -1;
    }
    const value: number = Number.parseInt(hex, 16);
    return Number.isNaN(value) || value < 0 ? -1 : value;
  }
}
