import { fileIo } from '@kit.CoreFileKit';

/**
 * Size and modification time of a uri, as far as the platform will tell us.
 *
 * Both halves of a transfer need this before anything moves: the sender must announce the size it
 * claims to send, and the web offer must publish the same numbers so a browser can spot a truncation.
 */
export interface UriStat {
  size: number;
  /** Milliseconds since the Epoch; 0 when the platform would not say. */
  modifiedMs: number;
}

/**
 * Opens the uri only to stat the descriptor, then closes it again.
 *
 * Throws when the uri cannot be opened — a revoked picker grant or a file deleted since it was
 * listed. Callers decide whether that means "skip this file" or "fail the transfer".
 */
export async function statUri(uri: string): Promise<UriStat> {
  const file: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const stat: fileIo.Stat = fileIo.statSync(file.fd);
    const out: UriStat = { size: stat.size, modifiedMs: stat.mtime > 0 ? stat.mtime * 1000 : 0 };
    return out;
  } finally {
    await fileIo.close(file);
  }
}
