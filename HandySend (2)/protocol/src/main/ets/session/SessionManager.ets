import { util } from '@kit.ArkTS';
import { ApiPath, MAX_UPLOAD_ATTEMPTS } from '../wire/Constants';
import {
  Dto, WireDeviceInfo, WireFile, WirePrepareUploadRequest, WirePrepareUploadResponse
} from '../wire/Dto';
import { Exchange, RequestHandler, ServerReply, replyEmpty, replyWithJson, replyWithMessage } from '../httpx/Exchange';
import { Status } from '../httpx/Http';
import { describeFailure } from '../util/Errors';
import { concatBytes } from '../util/ByteBuffers';
import { LayoutPlanner, PlannedPath } from './Layout';
import { FileSink } from './FileSink';
import { PinGuard, PinResult } from './PinGuard';
import { uuidV4 } from './RandomIds';
import {
  CandidateFile, DecisionOutcome, DestinationContext, FileProgressEvent, FileStatus, PendingOffer, PrepareContext,
  PrepareDecision, ReceiveSession, ReceivedFile, SaveResult, SessionEndReason, SessionManagerConfig
} from './SessionTypes';

/** prepare-upload carries only metadata, but a folder offer can hold thousands of entries. */
const MAX_PREPARE_BODY: number = 4 * 1024 * 1024;
const PREPARE_READ_STEP: number = 64 * 1024;
/** Upload bodies are streamed, so the chunk size is a memory/latency trade, not a limit. */
const UPLOAD_CHUNK: number = 256 * 1024;

const utf8Decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

/**
 * The receiver's session engine: `POST /prepare-upload`, `POST /upload` and `POST /cancel`.
 *
 * Structure follows the reference core (packages/core/src/http/server/v2.rs) request for request,
 * because official senders are written against those exact transitions — the single session slot,
 * the PIN gate that runs before the body is read, 204 for an accepted-but-empty selection, the
 * token-and-IP binding of every upload, and the 422 that lets one file be retried three times.
 * Where the reference uses drop guards, this uses explicit release points, so every early return
 * frees what it claimed.
 */
export class SessionManager {
  private config: SessionManagerConfig;
  /** A prepare-upload waiting for the user. It holds the slot so a second sender gets 409. */
  private pending: PendingOffer | null = null;
  private active: ReceiveSession | null = null;
  private pinGuard: PinGuard = new PinGuard();
  /** Listeners keyed by pending session id, woken by a cancel from the sender's address. */
  private cancelListeners: Map<string, Array<() => void>> = new Map<string, Array<() => void>>();

  constructor(config: SessionManagerConfig) {
    this.config = config;
  }

  routes(): Map<string, RequestHandler> {
    const routes: Map<string, RequestHandler> = new Map<string, RequestHandler>();
    routes.set(ApiPath.PREPARE_UPLOAD, this.prepareUploadHandler());
    routes.set(ApiPath.UPLOAD, this.uploadHandler());
    routes.set(ApiPath.CANCEL, this.cancelHandler());
    return routes;
  }

  activeSession(): ReceiveSession | null {
    return this.active;
  }

  /** True while a sender holds the slot, either waiting for a decision or transferring. */
  isBusy(): boolean {
    return this.pending !== null || this.active !== null;
  }

  /** The user stopped the transfer on this device; the sender sees its upload fail. */
  cancelActiveLocally(): void {
    const session: ReceiveSession | null = this.active;
    if (session === null) {
      return;
    }
    session.cancelled = true;
    this.active = null;
    this.config.onSessionEnded(session, SessionEndReason.CANCELLED_LOCALLY);
  }

  /** Forgets state without touching files on disk; used when the server stops. */
  reset(): void {
    this.pending = null;
    this.active = null;
    this.cancelListeners.clear();
    this.pinGuard.reset();
  }

  // ------------------------------------------------------------- prepare-upload

  prepareUploadHandler(): RequestHandler {
    return async (exchange: Exchange): Promise<ServerReply> => {
      // Before the body: a peer that has not earned the right to send must not cost us the
      // bandwidth of the files it offered, and must not be able to fill our memory with them.
      const pinReply: ServerReply | null = this.checkPin(exchange);
      if (pinReply !== null) {
        return pinReply;
      }

      const text: string | null = await this.readTextBody(exchange);
      if (text === null) {
        return replyWithMessage(Status.BadRequest, 'Invalid body');
      }
      const request: WirePrepareUploadRequest | null = Dto.parsePrepareUploadRequest(text);
      if (request === null) {
        return replyWithMessage(Status.BadRequest, 'Invalid body');
      }
      const info: WireDeviceInfo = request.info;
      const files: Map<string, WireFile> = request.files;
      if (files.size === 0) {
        return replyWithMessage(Status.BadRequest, 'No files provided');
      }

      const destination: string | null = await this.config.destination(summarize(info, files, exchange));
      if (destination === null || destination.length === 0) {
        return replyWithMessage(Status.Forbidden, 'Rejected');
      }

      const planner: LayoutPlanner = new LayoutPlanner(destination);
      const candidates: CandidateFile[] = [];
      let plannedPaths: Map<string, PlannedPath> | null = null;
      try {
        plannedPaths = planAll(planner, files);
      } catch (e) {
        // A name that tries to escape the destination fails the offer rather than misfiling.
        this.config.log(`prepare-upload rejected by name: ${describeFailure(e)}`);
        return replyWithMessage(Status.BadRequest, 'Invalid file name');
      }
      const paths: Map<string, PlannedPath> = plannedPaths === null ? new Map<string, PlannedPath>() : plannedPaths;
      paths.forEach((value: PlannedPath, fileId: string) => {
        candidates.push(toCandidate(files.get(fileId) as WireFile, fileId, value));
      });

      // Claim the slot before asking the user, exactly like the reference: a second sender that
      // arrives while the dialog is open must be told 409, not queued behind the first.
      const sessionId: string = await uuidV4();
      const offer: PendingOffer = { sessionId: sessionId, senderIp: exchange.peerHost, cancelled: false };
      if (this.isBusy()) {
        return replyWithMessage(Status.Conflict, 'Blocked by another session');
      }
      this.pending = offer;

      const context: PrepareContext = {
        sessionId: sessionId,
        senderIp: exchange.peerHost,
        senderFingerprint: senderIdentity(exchange, info),
        info: info,
        destination: destination,
        candidates: candidates
      };
      const outcome: DecisionOutcome = await this.decideOrCancel(offer, context);

      if (this.pending === null || this.pending.sessionId !== sessionId) {
        // A cancel from the sender already freed the slot and woke this handler.
        this.config.onPrepareAborted(sessionId);
        return replyWithMessage(Status.Forbidden, 'Cancelled by sender');
      }
      this.pending = null;

      if (outcome.cancelledBySender) {
        this.config.onPrepareAborted(sessionId);
        return replyWithMessage(Status.Forbidden, 'Cancelled by sender');
      }
      const decision: PrepareDecision | null = outcome.decision;
      if (decision === null || decision.declined) {
        return replyWithMessage(Status.Forbidden, 'Rejected');
      }

      const accepted: string[] = decision.acceptedFileIds;
      if (accepted.length === 0) {
        // Nothing to transfer. The reference answers 204 and leaves no session behind.
        return replyEmpty(Status.NoContent);
      }

      const sessionFiles: Map<string, ReceivedFile> = new Map<string, ReceivedFile>();
      const tokens: Map<string, string> = new Map<string, string>();
      for (let i = 0; i < accepted.length; i++) {
        const fileId: string = accepted[i];
        const metadata: WireFile | undefined = files.get(fileId);
        const path: PlannedPath | undefined = paths.get(fileId);
        if (metadata === undefined || path === undefined) {
          // An id the peer never offered: ignore rather than fail the whole selection.
          continue;
        }
        const token: string = await uuidV4();
        const file: ReceivedFile = {
          fileId: fileId,
          fileName: metadata.fileName,
          relativePath: path.relative,
          path: path.absolute,
          size: metadata.size,
          fileType: metadata.fileType,
          sha256: metadata.sha256,
          modifiedMs: modifiedTimeMs(metadata),
          token: token,
          status: FileStatus.PENDING,
          receivedBytes: 0,
          attempts: 0
        };
        sessionFiles.set(fileId, file);
        tokens.set(fileId, token);
      }
      if (sessionFiles.size === 0) {
        return replyEmpty(Status.NoContent);
      }

      const session: ReceiveSession = {
        sessionId: sessionId,
        senderIp: exchange.peerHost,
        senderFingerprint: senderIdentity(exchange, info),
        senderAlias: info.alias,
        info: info,
        destination: destination,
        files: sessionFiles,
        createdAtMs: Date.now(),
        cancelled: false
      };
      this.active = session;
      this.config.onSessionCreated(session);
      this.config.log(`upload session ${sessionId} from ${session.senderIp} (${sessionFiles.size} file(s))`);

      const response: WirePrepareUploadResponse = { sessionId: sessionId, files: tokens };
      return replyWithJson(Status.Ok, Dto.prepareUploadResponseToJson(response));
    };
  }

  /**
   * Resolves with the user's answer, or with `cancelledBySender` as soon as the sender
   * withdraws. The reference does the same with a tokio select over the decision channel and
   * a cancellation token; a dialog nobody is going to answer must not hold the slot open.
   */
  private decideOrCancel(offer: PendingOffer, context: PrepareContext): Promise<DecisionOutcome> {
    return new Promise<DecisionOutcome>((resolve: (value: DecisionOutcome) => void) => {
      // fireCancelListeners clears the table before it invokes its listeners, so which branch
      // wins has to be decided here rather than by whether removal still finds us.
      let settled: boolean = false;
      const finish: (outcome: DecisionOutcome) => void = (outcome: DecisionOutcome): void => {
        if (settled) {
          return;
        }
        settled = true;
        this.removeCancelListener(offer.sessionId, onCancel);
        resolve(outcome);
      };
      const onCancel: () => void = (): void => {
        finish({ cancelledBySender: true, decision: null });
      };
      this.addCancelListener(offer.sessionId, onCancel);
      this.config.decide(context).then((decision: PrepareDecision): void => {
        finish({ cancelledBySender: false, decision: decision });
      }, (reason: Object): void => {
        this.config.log(`decision handler failed: ${describeFailure(reason)}`);
        finish({ cancelledBySender: false, decision: { declined: true, acceptedFileIds: [] } });
      });
    });
  }

  private addCancelListener(sessionId: string, listener: () => void): void {
    const existing: Array<() => void> | undefined = this.cancelListeners.get(sessionId);
    if (existing === undefined) {
      this.cancelListeners.set(sessionId, [listener]);
      return;
    }
    existing.push(listener);
  }

  /** Returns false when the outcome was already settled by the other branch. */
  private removeCancelListener(sessionId: string, listener: () => void): boolean {
    const existing: Array<() => void> | undefined = this.cancelListeners.get(sessionId);
    if (existing === undefined) {
      return false;
    }
    const at: number = existing.indexOf(listener);
    if (at < 0) {
      return false;
    }
    existing.splice(at, 1);
    if (existing.length === 0) {
      this.cancelListeners.delete(sessionId);
    }
    return true;
  }

  private fireCancelListeners(sessionId: string): void {
    const existing: Array<() => void> | undefined = this.cancelListeners.get(sessionId);
    if (existing === undefined) {
      return;
    }
    const snapshot: Array<() => void> = existing.slice(0);
    this.cancelListeners.delete(sessionId);
    snapshot.forEach((listener: () => void) => {
      listener();
    });
  }

  // --------------------------------------------------------------------- upload

  uploadHandler(): RequestHandler {
    return async (exchange: Exchange): Promise<ServerReply> => {
      const query: Map<string, string> = exchange.request.query;
      const sessionId: string = query.get('sessionId') ?? '';
      const fileId: string = query.get('fileId') ?? '';
      const token: string = query.get('token') ?? '';
      if (sessionId.length === 0 || fileId.length === 0 || token.length === 0) {
        return replyWithMessage(Status.BadRequest, 'Missing parameters');
      }

      const session: ReceiveSession | null = this.active;
      if (session === null || session.sessionId !== sessionId || session.senderIp !== exchange.peerHost) {
        return invalidToken();
      }
      const file: ReceivedFile | undefined = session.files.get(fileId);
      if (file === undefined || file.token !== token || file.status !== FileStatus.PENDING) {
        // Only a Pending file may start; in-progress and finished files reject a second stream.
        return invalidToken();
      }

      file.status = FileStatus.IN_PROGRESS;
      file.attempts += 1;
      file.receivedBytes = 0;
      this.config.onFileUpdated(session, file);

      // No sha256 on the wire, or verification turned off: the bytes are taken as they arrive.
      const expected: string | null = this.config.verifyChecksums() ? file.sha256 ?? null : null;

      let sink: FileSink;
      try {
        sink = await FileSink.create(file.path, expected !== null);
      } catch (e) {
        this.config.log(`cannot open ${file.path}: ${describeFailure(e)}`);
        this.finalizeFile(session, file, SaveResult.FAILED);
        return replyWithMessage(Status.InternalError, 'Failed to save file');
      }

      const result: SaveResult = await this.saveBody(exchange, session, file, sink, expected);
      switch (result) {
        case SaveResult.CANCELLED:
          // The slot was already freed by the cancel request; only the file state is left to report.
          return replyWithMessage(Status.Forbidden, 'Cancelled by sender');
        case SaveResult.HASH_MISMATCH:
          this.finalizeFile(session, file, result);
          return replyWithMessage(Status.UnprocessableEntity, 'Checksum mismatch');
        case SaveResult.FAILED:
          this.finalizeFile(session, file, result);
          return replyWithMessage(Status.InternalError, 'Failed to save file');
        default:
          this.finalizeFile(session, file, result);
          return replyEmpty(Status.Ok);
      }
    };
  }

  /**
   * Streams the request body into `sink`, hashing as it goes, and reports the outcome.
   * Nothing is written back to the peer here: the answer is decided by the caller.
   */
  private async saveBody(exchange: Exchange, session: ReceiveSession, file: ReceivedFile, sink: FileSink,
    expectedSha: string | null): Promise<SaveResult> {
    let broken: boolean = false;
    let oversized: boolean = false;
    for (;;) {
      if (session.cancelled) {
        // The sender cancelled while bytes were still arriving; the partial file is ours to drop.
        await sink.destroy();
        return SaveResult.CANCELLED;
      }
      let chunk: Uint8Array | null;
      try {
        chunk = await exchange.body.read(UPLOAD_CHUNK);
      } catch (e) {
        this.config.log(`body of ${file.fileName} aborted: ${describeFailure(e)}`);
        broken = true;
        break;
      }
      if (chunk === null) {
        break;
      }
      if (sink.receivedBytes + chunk.length > file.size) {
        // More bytes than the metadata promised: the transfer is a failure, and stopping here
        // keeps a hostile sender from filling the volume.
        oversized = true;
        break;
      }
      try {
        await sink.write(chunk);
      } catch (e) {
        this.config.log(`write of ${file.fileName} failed: ${describeFailure(e)}`);
        await sink.close();
        return SaveResult.FAILED;
      }
      file.receivedBytes = sink.receivedBytes;
      const event: FileProgressEvent = {
        sessionId: session.sessionId,
        fileId: file.fileId,
        fileName: file.fileName,
        receivedBytes: file.receivedBytes,
        totalBytes: file.size
      };
      this.config.onProgress(event);
    }

    if (broken || oversized) {
      await sink.close();
      return SaveResult.FAILED;
    }
    if (sink.receivedBytes !== file.size) {
      // A clean end of body that is short of the promised size is a truncated upload.
      this.config.log(`${file.fileName}: expected ${file.size} bytes, got ${sink.receivedBytes}`);
      await sink.close();
      return SaveResult.FAILED;
    }

    let actual: string | null;
    try {
      actual = await sink.finish();
    } catch (e) {
      this.config.log(`digest of ${file.fileName} failed: ${describeFailure(e)}`);
      return SaveResult.FAILED;
    }
    if (expectedSha !== null && actual !== null && !equalsIgnoreHexCase(expectedSha, actual)) {
      this.config.log(`checksum mismatch for ${file.fileName}: expected ${expectedSha}, got ${actual}`);
      return SaveResult.HASH_MISMATCH;
    }
    if (file.modifiedMs !== undefined) {
      sink.applyModifiedTime(file.modifiedMs);
    }
    return SaveResult.SUCCESS;
  }

  /**
   * Sets the file's final state and ends the session once every file is done.
   *
   * A checksum mismatch puts the file back to Pending while attempts remain, which is what lets
   * the official sender retry it with the same token; the reference allows three attempts in total.
   */
  private finalizeFile(session: ReceiveSession, file: ReceivedFile, result: SaveResult): void {
    if (this.active === null || this.active.sessionId !== session.sessionId) {
      // Cancelled and freed underneath us: there is no session left to finalize.
      return;
    }
    if (file.status === FileStatus.IN_PROGRESS) {
      if (result === SaveResult.SUCCESS) {
        file.status = FileStatus.FINISHED;
      } else if (result === SaveResult.HASH_MISMATCH && file.attempts < MAX_UPLOAD_ATTEMPTS) {
        file.status = FileStatus.PENDING;
      } else {
        file.status = FileStatus.FAILED;
      }
    }
    this.config.onFileUpdated(session, file);

    let complete: boolean = true;
    session.files.forEach((entry: ReceivedFile) => {
      if (entry.status !== FileStatus.FINISHED && entry.status !== FileStatus.FAILED) {
        complete = false;
      }
    });
    if (!complete) {
      return;
    }
    this.active = null;
    this.config.log(`upload session ${session.sessionId} finished`);
    this.config.onSessionEnded(session, SessionEndReason.FINISHED);
  }

  // --------------------------------------------------------------------- cancel

  cancelHandler(): RequestHandler {
    return async (exchange: Exchange): Promise<ServerReply> => {
      const sessionId: string | null = exchange.request.query.get('sessionId') ?? null;

      const offer: PendingOffer | null = this.pending;
      if (offer !== null && offer.senderIp === exchange.peerHost
        && (sessionId === null || sessionId === offer.sessionId)) {
        // A sender that is still waiting for the prepare-upload answer cannot know the session id,
        // so a cancel from that address is honoured without one.
        offer.cancelled = true;
        this.pending = null;
        this.fireCancelListeners(offer.sessionId);
        return replyEmpty(Status.Ok);
      }

      const session: ReceiveSession | null = this.active;
      if (sessionId !== null && session !== null && session.sessionId === sessionId
        && session.senderIp === exchange.peerHost) {
        session.cancelled = true;
        this.active = null;
        this.config.onSessionEnded(session, SessionEndReason.CANCELLED_BY_SENDER);
        return replyEmpty(Status.Ok);
      }

      if (sessionId !== null) {
        // Not ours: the peer is cancelling a transfer this device is sending to it.
        this.config.onCancelReceived(exchange.peerHost, sessionId);
      }
      return replyEmpty(Status.Ok);
    };
  }

  // -------------------------------------------------------------------- helpers

  private checkPin(exchange: Exchange): ServerReply | null {
    const required: string | null = this.config.pin();
    if (required === null) {
      return null;
    }
    // The reference checks the PIN on every prepare-upload, certificate or not: the PIN is the
    // receiver's own gate, and an authenticated transport must not silently waive it.
    const provided: string | undefined = exchange.request.query.get('pin');
    const result: PinResult = this.pinGuard.check(required, provided === undefined ? null : provided,
      exchange.peerHost);
    switch (result) {
      case PinResult.OK:
        return null;
      case PinResult.LOCKED:
        return replyWithMessage(Status.TooManyRequests, 'Too many requests');
      case PinResult.MISSING:
        return replyWithMessage(Status.Unauthorized, 'PIN required');
      default:
        return replyWithMessage(Status.Unauthorized, 'Invalid PIN');
    }
  }

  private async readTextBody(exchange: Exchange): Promise<string | null> {
    const parts: Uint8Array[] = [];
    let total: number = 0;
    for (;;) {
      let chunk: Uint8Array | null;
      try {
        chunk = await exchange.body.read(PREPARE_READ_STEP);
      } catch (e) {
        this.config.log(`prepare-upload body aborted: ${describeFailure(e)}`);
        return null;
      }
      if (chunk === null) {
        break;
      }
      parts.push(chunk);
      total += chunk.length;
      if (total > MAX_PREPARE_BODY) {
        this.config.log('prepare-upload body too large');
        return null;
      }
    }
    if (total === 0) {
      return null;
    }
    return utf8Decoder.decodeToString(concatBytes(parts));
  }
}

// ------------------------------------------------------------------- module helpers

function invalidToken(): ServerReply {
  return replyWithMessage(Status.Forbidden, 'Invalid token or IP address');
}

/** Over TLS the certificate wins; the payload fingerprint only counts in plaintext. */
function senderIdentity(exchange: Exchange, info: WireDeviceInfo): string {
  return exchange.peerCertFingerprint !== null ? exchange.peerCertFingerprint : info.fingerprint;
}

function summarize(info: WireDeviceInfo, files: Map<string, WireFile>, exchange: Exchange): DestinationContext {
  let total: number = 0;
  files.forEach((file: WireFile) => {
    total += file.size;
  });
  const context: DestinationContext = {
    senderIp: exchange.peerHost,
    senderFingerprint: senderIdentity(exchange, info),
    info: info,
    totalBytes: total,
    fileCount: files.size
  };
  return context;
}

function planAll(planner: LayoutPlanner, files: Map<string, WireFile>): Map<string, PlannedPath> {
  const out: Map<string, PlannedPath> = new Map<string, PlannedPath>();
  files.forEach((file: WireFile, fileId: string) => {
    out.set(fileId, planner.plan(file.fileName));
  });
  return out;
}

function toCandidate(file: WireFile, fileId: string, path: PlannedPath): CandidateFile {
  const candidate: CandidateFile = {
    fileId: fileId,
    fileName: file.fileName,
    relativePath: path.relative,
    size: file.size,
    fileType: file.fileType,
    preview: file.preview
  };
  return candidate;
}

/** `metadata.modified` is an ISO-8601 string; anything unusable simply keeps the local time. */
function modifiedTimeMs(file: WireFile): number | undefined {
  const raw: string | undefined = file.metadata === undefined ? undefined : file.metadata.modified;
  if (raw === undefined || raw.length === 0) {
    return undefined;
  }
  const ms: number = Date.parse(raw);
  return Number.isNaN(ms) ? undefined : ms;
}

function equalsIgnoreHexCase(expected: string, actual: string): boolean {
  return expected.toLowerCase() === actual.toLowerCase();
}
