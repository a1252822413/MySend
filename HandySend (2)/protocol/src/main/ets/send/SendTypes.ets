import { ProtocolScheme } from '../wire/Constants';

/**
 * Sender-side model. The wire contract is the mirror image of `session/SessionManager`:
 * we choose the file ids, the receiver answers with one upload token per file it accepted,
 * and every /upload must carry that session, file and token.
 */

/**
 * One file the user asked to send.
 *
 * `uri` is whatever the platform handed the app — a sandbox path, a `file://docs/...` document uri
 * or a media library uri — and is passed unchanged to `fileIo.open`, which understands all three.
 */
export interface SendSource {
  uri: string;
  /**
   * Name as it appears on the wire. A folder transfer sends `<folder>/<relative path>`, which is how
   * the reference clients keep a directory tree inside one file entry; the receiver re-roots it.
   */
  fileName: string;
}

/** Where to send. The fingerprint is the peer's claimed identity, proven only by a TLS handshake. */
export interface SendTarget {
  host: string;
  port: number;
  scheme: ProtocolScheme;
  alias: string;
  fingerprint: string;
}

export enum SendFileStatus {
  /** Statted, waiting to be hashed. */
  QUEUED = 'queued',
  HASHING = 'hashing',
  /** The receiver accepted this file; waiting for one of the upload slots. */
  PENDING = 'pending',
  SENDING = 'sending',
  SUCCESS = 'success',
  /** The receiver's user deselected it, so no token came back for it. */
  SKIPPED = 'skipped',
  FAILED = 'failed',
  CANCELED = 'canceled'
}

export class SendFile {
  readonly fileId: string;
  readonly uri: string;
  readonly fileName: string;
  readonly fileType: string;
  readonly size: number;
  /** `metadata.modified` in milliseconds, or 0 when the platform would not tell us. */
  readonly modifiedMs: number;
  sha256: string = '';
  /** Issued by the receiver; empty until the offer is accepted. */
  token: string = '';
  status: SendFileStatus = SendFileStatus.QUEUED;
  sent: number = 0;
  /** Number of /upload attempts made for this file, counting the first. */
  attempts: number = 0;
  error: string = '';

  constructor(fileId: string, uri: string, fileName: string, fileType: string, size: number,
    modifiedMs: number) {
    this.fileId = fileId;
    this.uri = uri;
    this.fileName = fileName;
    this.fileType = fileType;
    this.size = size;
    this.modifiedMs = modifiedMs;
  }
}

export enum SendTaskStatus {
  /** Checksums are being computed; the offer has not been sent yet. */
  HASHING = 'hashing',
  /** The receiver's user has the offer on screen. */
  WAITING = 'waiting',
  UPLOADING = 'uploading',
  SUCCESS = 'success',
  FAILED = 'failed',
  CANCELED = 'canceled'
}

/** One send: a peer, the files it was offered, and how each of them ended. */
export class SendTask {
  readonly target: SendTarget;
  readonly files: SendFile[] = [];
  status: SendTaskStatus = SendTaskStatus.HASHING;
  sessionId: string = '';
  /** Alias reported by the peer in its prepare-upload answer, when it sent one. */
  peerAlias: string;
  error: string = '';

  constructor(target: SendTarget) {
    this.target = target;
    this.peerAlias = target.alias;
  }

  totalBytes(): number {
    let total: number = 0;
    for (let i = 0; i < this.files.length; i++) {
      // A file the receiver declined never travels, so it must not hold the bar back.
      if (this.files[i].status !== SendFileStatus.SKIPPED) {
        total += this.files[i].size;
      }
    }
    return total;
  }

  sentBytes(): number {
    let sent: number = 0;
    for (let i = 0; i < this.files.length; i++) {
      sent += this.files[i].sent;
    }
    return sent;
  }

  /** Files the receiver gave a token for, in the order they were offered. */
  accepted(): SendFile[] {
    const list: SendFile[] = [];
    for (let i = 0; i < this.files.length; i++) {
      if (this.files[i].token.length > 0) {
        list.push(this.files[i]);
      }
    }
    return list;
  }

  isFinished(): boolean {
    return this.status === SendTaskStatus.SUCCESS || this.status === SendTaskStatus.FAILED
      || this.status === SendTaskStatus.CANCELED;
  }
}
