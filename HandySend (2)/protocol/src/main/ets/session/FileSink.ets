import { fileIo } from '@kit.CoreFileKit';
import { tightBuffer } from '../transport/ByteLink';
import { Sha256 } from '../util/Digest';
import { describePlatformError, platformErrorCode } from '../util/Errors';
import { ensureDirectory, parentDir } from './Layout';

/** A write, open or close that the platform refused. Reported as 500 to the peer. */
export class SaveError extends Error {
  readonly code: number;

  constructor(message: string, code: number = -1) {
    super(message);
    this.name = 'SaveError';
    this.code = code;
  }
}

/**
 * Streaming file writer with the checksum computed on the way through, exactly like the
 * reference core: hashing a second time after the write would double the I/O of a folder
 * transfer, and hashing before writing would let a corrupt file land under its real name.
 *
 * The file is opened with TRUNC, so a retry of the same upload replaces its own partial
 * bytes rather than appending to them.
 */
export class FileSink {
  readonly path: string;
  private file: fileIo.File;
  private sha: Sha256 | null;
  private written: number = 0;
  private closed: boolean = false;

  private constructor(path: string, file: fileIo.File, sha: Sha256 | null) {
    this.path = path;
    this.file = file;
    this.sha = sha;
  }

  static async create(path: string, hashed: boolean): Promise<FileSink> {
    await ensureDirectory(parentDir(path));
    let file: fileIo.File;
    try {
      const mode: number = fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC;
      file = await fileIo.open(path, mode);
    } catch (e) {
      throw new SaveError(describePlatformError(e as Object, `open ${path}`), platformErrorCode(e as Object));
    }
    return new FileSink(path, file, hashed ? new Sha256() : null);
  }

  get receivedBytes(): number {
    return this.written;
  }

  async write(chunk: Uint8Array): Promise<void> {
    if (chunk.length === 0) {
      return;
    }
    // The platform writes whole ArrayBuffers; a view into a larger buffer would write its tail too.
    const buffer: ArrayBuffer = tightBuffer(chunk);
    try {
      const written: number = await fileIo.write(this.file.fd, buffer);
      if (written !== chunk.length) {
        throw new SaveError(`short write to ${this.path}: ${written} of ${chunk.length}`, -1);
      }
    } catch (e) {
      if (e instanceof SaveError) {
        throw e;
      }
      throw new SaveError(describePlatformError(e as Object, `write ${this.path}`), platformErrorCode(e as Object));
    }
    if (this.sha !== null) {
      this.sha.update(chunk);
    }
    this.written += chunk.length;
  }

  /** Flushes, hashes what was written and closes. Null when this file is not checksummed. */
  async finish(): Promise<string | null> {
    // digest() finalizes the accumulator, so it must happen before the handle goes away but
    // after the last write; a failed close must not mask a write error.
    const digest: string | null = this.sha === null ? null : await this.sha.digestHexLower();
    await this.close();
    return digest;
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    try {
      await fileIo.close(this.file);
    } catch (e) {
      // Nothing to do: the bytes are on disk, and the peer's answer is decided by them.
    }
  }

  /** Drops a partial file after the sender cancelled; an accepted file is never removed here. */
  async destroy(): Promise<void> {
    await this.close();
    await removeFile(this.path);
  }

  /**
   * Applies the peer's `metadata.modified`. Best effort, like the reference writer: a volume
   * that refuses timestamp changes must not fail a transfer that completed.
   */
  applyModifiedTime(modifiedMs: number): void {
    if (modifiedMs <= 0) {
      return;
    }
    try {
      fileIo.utimes(this.path, modifiedMs);
    } catch (e) {
      // ignored on purpose
    }
  }
}

export async function removeFile(path: string): Promise<void> {
  try {
    await fileIo.unlink(path);
  } catch (e) {
    // Already gone is the desired end state.
  }
}
