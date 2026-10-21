/**
 * SHA-256 over chunks, the checksum the LocalSend upload protocol verifies.
 * Streaming is mandatory: a folder transfer can carry files far larger than
 * the memory a one-shot read would need.
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo } from '@kit.CoreFileKit';
import { CancelledError, DigestError, describePlatformError, platformErrorCode } from './Errors';

const DEFAULT_CHUNK_SIZE: number = 64 * 1024;

function toHexLower(bytes: Uint8Array): string {
  return renderHex(bytes, '0123456789abcdef');
}

function toHexUpper(bytes: Uint8Array): string {
  return renderHex(bytes, '0123456789ABCDEF');
}

function renderHex(bytes: Uint8Array, digits: string): string {
  let hex: string = '';
  for (let i = 0; i < bytes.length; i++) {
    hex += digits.charAt((bytes[i] >> 4) & 0x0f);
    hex += digits.charAt(bytes[i] & 0x0f);
  }
  return hex;
}

/** Lowercase hex rendering; file checksums on the wire use it. */
export function hexLower(bytes: Uint8Array): string {
  return toHexLower(bytes);
}

/** Uppercase hex rendering; the LocalSend certificate fingerprint uses it. */
export function hexUpper(bytes: Uint8Array): string {
  return toHexUpper(bytes);
}

function createSha256Md(): cryptoFramework.Md {
  try {
    return cryptoFramework.createMd('SHA256');
  } catch (e) {
    throw new DigestError(describePlatformError(e as Object, 'createMd(SHA256)'), platformErrorCode(e as Object));
  }
}

async function openForRead(path: string): Promise<fileIo.File> {
  try {
    return await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  } catch (e) {
    throw new DigestError(describePlatformError(e as Object, 'open ' + path), platformErrorCode(e as Object));
  }
}

/**
 * Incremental digest. `update` is synchronous because the platform exposes
 * `updateSync`, and the upload path feeds it from a tight read loop.
 */
export class Sha256 {
  private md: cryptoFramework.Md;
  private finished: boolean = false;

  constructor() {
    this.md = createSha256Md();
  }

  update(buf: Uint8Array): void {
    if (this.finished) {
      throw new DigestError('Digest already finalized', -1);
    }
    if (buf.length === 0) {
      // An empty DataBlob is rejected by the platform as an invalid parameter.
      return;
    }
    const input: cryptoFramework.DataBlob = { data: buf };
    try {
      this.md.updateSync(input);
    } catch (e) {
      throw new DigestError(describePlatformError(e as Object, 'md.update'), platformErrorCode(e as Object));
    }
  }

  async digest(): Promise<Uint8Array> {
    if (this.finished) {
      throw new DigestError('Digest already finalized', -1);
    }
    // digest() consumes the accumulated state, so a second call is meaningless.
    this.finished = true;
    try {
      const out: cryptoFramework.DataBlob = await this.md.digest();
      return out.data;
    } catch (e) {
      throw new DigestError(describePlatformError(e as Object, 'md.digest'), platformErrorCode(e as Object));
    }
  }

  async digestHexLower(): Promise<string> {
    return toHexLower(await this.digest());
  }

  async digestHexUpper(): Promise<string> {
    return toHexUpper(await this.digest());
  }
}

/** One-shot digest of an in-memory buffer. */
export async function sha256Bytes(data: Uint8Array): Promise<Uint8Array> {
  const sha: Sha256 = new Sha256();
  sha.update(data);
  return await sha.digest();
}

/**
 * One-shot hex digest. `upper` selects the certificate-fingerprint alphabet that
 * official LocalSend clients use, `false` selects the wire checksum alphabet.
 */
export async function sha256Hex(data: Uint8Array, upper: boolean = false): Promise<string> {
  const raw: Uint8Array = await sha256Bytes(data);
  return upper ? toHexUpper(raw) : toHexLower(raw);
}

async function closeQuietly(file: fileIo.File): Promise<void> {
  try {
    await fileIo.close(file);
  } catch (e) {
    // Whatever the digest outcome is, it dominates a failed close.
  }
}

async function hashOpenedFile(file: fileIo.File, chunkSize: number, path: string,
  isCancelled?: () => boolean): Promise<string> {
  const sha: Sha256 = new Sha256();
  const window: ArrayBuffer = new ArrayBuffer(chunkSize);
  for (;;) {
    if (isCancelled !== undefined && isCancelled()) {
      throw new CancelledError('Hashing cancelled: ' + path);
    }
    let read: number = 0;
    try {
      // No offset option: the read advances the file pointer itself, while an
      // explicit offset is resolved against that pointer.
      read = await fileIo.read(file.fd, window);
    } catch (e) {
      throw new DigestError(describePlatformError(e as Object, 'read ' + path), platformErrorCode(e as Object));
    }
    if (read <= 0) {
      break;
    }
    sha.update(new Uint8Array(window.slice(0, read)));
  }
  return await sha.digestHexLower();
}

/**
 * Hashes a file without ever holding it in memory, for the pre-upload digest.
 * `isCancelled` is polled once per chunk so an abort lands between reads rather
 * than after the whole file, which is what lets the task be reported as failed.
 */
export async function sha256HexOfFile(path: string, chunkSize?: number,
  isCancelled?: () => boolean): Promise<string> {
  let size: number = DEFAULT_CHUNK_SIZE;
  if (chunkSize !== undefined && chunkSize > 0) {
    size = chunkSize;
  }
  const file: fileIo.File = await openForRead(path);
  try {
    return await hashOpenedFile(file, size, path, isCancelled);
  } finally {
    await closeQuietly(file);
  }
}
