import { WireDeviceInfo } from '../wire/Dto';

/**
 * Receiver-side session model, mirroring the state machine of the reference core
 * (packages/core/src/http/server/v2.rs + common/session.rs): one session slot per
 * server, files that move Pending -> InProgress -> Finished|Failed, and a checksum
 * mismatch that resets a file to Pending so the sender can retry it with the same token.
 */

export enum FileStatus {
  PENDING = 'pending',
  IN_PROGRESS = 'in_progress',
  FINISHED = 'finished',
  FAILED = 'failed'
}

export enum SessionEndReason {
  /** Every accepted file reached a final state. */
  FINISHED = 'finished',
  /** The receiver declined the offer. */
  DECLINED = 'declined',
  /** The sender withdrew the offer or cancelled the transfer. */
  CANCELLED_BY_SENDER = 'cancelled-by-sender',
  /** The user stopped the transfer on this device. */
  CANCELLED_LOCALLY = 'cancelled-locally'
}

/** One accepted file: the wire metadata plus where it is written and how far we got. */
export interface ReceivedFile {
  fileId: string;
  /** The name as it arrived on the wire, kept for the UI. */
  fileName: string;
  /** Path relative to the session destination, after sanitizing and de-duplication. */
  relativePath: string;
  /** Absolute destination path, decided once at prepare time. */
  path: string;
  size: number;
  fileType: string;
  sha256?: string;
  /** `metadata.modified`, in milliseconds since the Epoch, when the peer sent it. */
  modifiedMs?: number;
  /** Per-file upload token; the sender must echo it back on /upload. */
  token: string;
  status: FileStatus;
  receivedBytes: number;
  attempts: number;
}

export interface ReceiveSession {
  sessionId: string;
  /** Uploads are only accepted from this address. */
  senderIp: string;
  /** TLS handshake fingerprint when encrypted; the body's claim otherwise. */
  senderFingerprint: string;
  senderAlias: string;
  info: WireDeviceInfo;
  destination: string;
  /** Accepted files, keyed by fileId. */
  files: Map<string, ReceivedFile>;
  createdAtMs: number;
  /** Set when the sender cancels; an in-flight body stops on the next chunk. */
  cancelled: boolean;
}

/**
 * A prepare-upload request that is waiting for the user. It occupies the session slot
 * before a session exists, which is what makes a second concurrent sender get 409.
 */
export interface PendingOffer {
  sessionId: string;
  senderIp: string;
  cancelled: boolean;
}

/** A file the user may accept, already named for the destination directory. */
export interface CandidateFile {
  fileId: string;
  fileName: string;
  relativePath: string;
  size: number;
  fileType: string;
  preview?: string;
}

export interface DestinationContext {
  senderIp: string;
  senderFingerprint: string;
  info: WireDeviceInfo;
  totalBytes: number;
  fileCount: number;
}

export interface PrepareContext {
  sessionId: string;
  senderIp: string;
  senderFingerprint: string;
  info: WireDeviceInfo;
  destination: string;
  candidates: CandidateFile[];
}

export interface PrepareDecision {
  declined: boolean;
  /** Accepted fileIds. An empty list answers 204 and frees the slot. */
  acceptedFileIds: string[];
}

/** The decision, or the fact that the sender withdrew the offer while we were asking. */
export interface DecisionOutcome {
  cancelledBySender: boolean;
  decision: PrepareDecision | null;
}

/** Outcome of one upload attempt, mapped onto the wire status the peer gets back. */
export enum SaveResult {
  /** 200 */
  SUCCESS = 'success',
  /** 422 — the sender may retry the same file with the same token. */
  HASH_MISMATCH = 'hash-mismatch',
  /** 500 */
  FAILED = 'failed',
  /** 403, and the partial file is dropped. */
  CANCELLED = 'cancelled'
}

export interface FileProgressEvent {
  sessionId: string;
  fileId: string;
  fileName: string;
  receivedBytes: number;
  totalBytes: number;
}

/**
 * Everything the session engine asks the application for. Deliberately callbacks, not
 * an interface with methods: the engine never needs a subclass, and the app wires one
 * object per server start.
 */
export interface SessionManagerConfig {
  /** Our own fingerprint, so a self-offered session can be refused. */
  selfFingerprint: () => string;
  /**
   * PIN required by /prepare-upload, or null. Only meaningful on a plaintext connection —
   * an encrypted peer is already identified by its certificate, and the reference client
   * uses the PIN for the browser upload page.
   */
  pin: () => string | null;
  /** Where this offer should be written; null refuses before the user is even asked. */
  destination: (context: DestinationContext) => Promise<string | null>;
  /** The user's accept/decline. */
  decide: (context: PrepareContext) => Promise<PrepareDecision>;
  /** Compare the wire sha256 against what was actually written. */
  verifyChecksums: () => boolean;
  onSessionCreated: (session: ReceiveSession) => void;
  onSessionEnded: (session: ReceiveSession, reason: SessionEndReason) => void;
  onFileUpdated: (session: ReceiveSession, file: ReceivedFile) => void;
  onProgress: (event: FileProgressEvent) => void;
  /** The waiting decision is pointless now — close the dialog. */
  onPrepareAborted: (sessionId: string) => void;
  /** A cancel for a session we do not own: the peer is cancelling our outgoing transfer. */
  onCancelReceived: (senderIp: string, sessionId: string) => void;
  log: (message: string) => void;
}
