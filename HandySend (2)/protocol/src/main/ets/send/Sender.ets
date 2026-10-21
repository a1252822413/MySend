import { fileIo } from '@kit.CoreFileKit';
import { ApiPath, MAX_UPLOAD_ATTEMPTS, UPLOAD_CONCURRENCY } from '../wire/Constants';
import {
  Dto, WireDeviceInfo, WireFile, WireFileMetadata, WireInfoResponse, WirePrepareUploadRequest,
  WirePrepareUploadResponse
} from '../wire/Dto';
import { parseRecord, readString } from '../wire/JsonValue';
import { ClientCredentials } from '../transport/DialedLinks';
import {
  HttpClient, JsonResponse, SendProgress, StreamingBody, Target, UploadResult
} from '../httpx/Client';
import { Status } from '../httpx/Http';
import { Sha256, hexLower } from '../util/Digest';
import { describeFailure, describePlatformError } from '../util/Errors';
import { UriStat, statUri } from '../util/FileStat';
import { mimeTypeOf } from './MimeTypes';
import {
  SendFile, SendFileStatus, SendSource, SendTarget, SendTask, SendTaskStatus
} from './SendTypes';

const UPLOAD_CHUNK: number = 64 * 1024;
const CONNECT_TIMEOUT_MS: number = 8000;
/** Progress repaints are throttled: a 64 KiB chunk loop would otherwise emit thousands a second. */
const PROGRESS_MIN_INTERVAL_MS: number = 150;

export interface SenderConfig {
  /** Our own announcement: alias, version, fingerprint, port and scheme. */
  self: () => WireDeviceInfo;
  /** Client certificate material, or null when this device sends unencrypted. */
  credentials: () => ClientCredentials | null;
  onChanged: () => void;
  log?: (message: string) => void;
}

/**
 * The sending half of the protocol, mirroring `http/client/v2.rs`:
 * register so the receiver learns us, one prepare-upload carrying every checksum, then
 * `UPLOAD_CONCURRENCY` parallel bodies, and a cancel that either withdraws an unanswered offer or
 * stops a live session.
 *
 * A checksum mismatch (422) is the one failure worth repeating: it means bytes were lost on the way,
 * not that the transfer was refused, and the receiver resets the file to pending so the same token
 * can be used again — until it exhausts its own attempt budget, which is why the loop is capped by
 * the same constant.
 */
export class Sender {
  private readonly config: SenderConfig;
  private task: SendTask | null = null;
  private cancelRequested: boolean = false;
  /** Guards against a second /cancel for one session, and against cancelling nothing at all. */
  private cancelSent: boolean = false;
  private lastEmitMs: number = 0;

  constructor(config: SenderConfig) {
    this.config = config;
  }

  current(): SendTask | null {
    return this.task;
  }

  isBusy(): boolean {
    const task: SendTask | null = this.task;
    return task !== null && !task.isFinished();
  }

  /**
   * Starts a send and returns immediately — hashing a folder takes longer than a tap handler may
   * block, and the page follows progress through `onChanged`.
   */
  start(target: SendTarget, sources: SendSource[], pin: string | null): void {
    if (this.isBusy()) {
      this.log('上一个发送还在进行，请先取消它');
      return;
    }
    const task: SendTask = new SendTask(target);
    this.task = task;
    this.cancelRequested = false;
    this.cancelSent = false;
    this.run(task, sources, pin);
  }

  /** Withdraws an unanswered offer or aborts a live session; the bodies stop on their next chunk. */
  cancel(): void {
    if (!this.isBusy()) {
      return;
    }
    this.cancelRequested = true;
    const task: SendTask | null = this.task;
    if (task === null) {
      return;
    }
    if (task.sessionId.length > 0) {
      this.sendCancel(task.sessionId);
    } else if (task.status === SendTaskStatus.WAITING) {
      // No session id exists yet: an unparametrised cancel is what releases the pending offer.
      this.sendCancel('');
    }
    this.changed(true);
  }

  // -------------------------------------------------------------------- stages

  private async run(task: SendTask, sources: SendSource[], pin: string | null): Promise<void> {
    try {
      await this.statAll(task, sources);
      if (task.files.length === 0) {
        this.fail('没有可发送的文件');
        return;
      }
      if (this.abortIfCancelled(task)) {
        return;
      }
      task.status = SendTaskStatus.HASHING;
      this.changed(true);
      for (let i = 0; i < task.files.length; i++) {
        if (!await this.hashFile(task.files[i])) {
          return;
        }
      }
      if (this.abortIfCancelled(task)) {
        return;
      }
      task.status = SendTaskStatus.WAITING;
      this.changed(true);
      await this.registerToPeer(task);
      if (this.abortIfCancelled(task)) {
        return;
      }
      if (!await this.prepareUpload(task, pin)) {
        return;
      }
      task.status = SendTaskStatus.UPLOADING;
      this.changed(true);
      await this.uploadAccepted(task);
      if (this.abortIfCancelled(task)) {
        return;
      }
      this.summarize(task);
    } catch (e) {
      this.fail(describePlatformError(e as Object, '发送失败'));
    }
  }

  /**
   * Reads size and timestamp out of the platform. A uri we cannot open is dropped rather than
   * offered: sending a zero-length claim for a file that exists would fail its checksum instead.
   */
  private async statAll(task: SendTask, sources: SendSource[]): Promise<void> {
    for (let i = 0; i < sources.length; i++) {
      const source: SendSource = sources[i];
      try {
        const info: UriStat = await statUri(source.uri);
        const entry: SendFile = new SendFile(`f${task.files.length + 1}`, source.uri, source.fileName,
          mimeTypeOf(source.fileName), info.size, info.modifiedMs);
        task.files.push(entry);
      } catch (e) {
        this.log(`跳过读不到的文件 ${source.fileName}: ${describePlatformError(e as Object, 'open')}`);
      }
    }
  }

  /** False only for a hard failure, which has already been reported on the task. */
  private async hashFile(file: SendFile): Promise<boolean> {
    file.status = SendFileStatus.HASHING;
    this.changed(true);
    const sha: Sha256 = new Sha256();
    try {
      file.sha256 = await this.digestFile(file.uri, sha);
    } catch (e) {
      file.status = SendFileStatus.FAILED;
      file.error = describePlatformError(e as Object, `读取 ${file.fileName} 失败`);
      this.fail(file.error);
      return false;
    }
    if (this.cancelRequested) {
      return true;
    }
    file.status = SendFileStatus.QUEUED;
    this.changed(true);
    return true;
  }

  private async digestFile(uri: string, sha: Sha256): Promise<string> {
    const file: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const window: ArrayBuffer = new ArrayBuffer(UPLOAD_CHUNK);
      for (;;) {
        if (this.cancelRequested) {
          throw new Error('发送已取消');
        }
        // No offset option: the read advances the pointer, while an explicit offset is resolved
        // against it.
        const read: number = await fileIo.read(file.fd, window);
        if (read <= 0) {
          break;
        }
        sha.update(new Uint8Array(window, 0, read));
      }
      return hexLower(await sha.digest());
    } finally {
      try {
        await fileIo.close(file);
      } catch (e) {
        // The digest dominates a failed close.
      }
    }
  }

  /**
   * `POST /register` before the offer, so the peer's device list contains us and its user can
   * recognise the incoming transfer. A failure here is not fatal: the receiver answers prepare
   * uploads from addresses it has never seen, and the connect error will surface either way.
   */
  private async registerToPeer(task: SendTask): Promise<void> {
    try {
      const response: JsonResponse = await HttpClient.requestJson({
        target: this.targetOf(task),
        method: 'POST',
        path: ApiPath.REGISTER,
        query: new Map<string, string>(),
        json: Dto.deviceInfoToJson(this.config.self()).build(),
        credentials: this.config.credentials(),
        timeoutMs: CONNECT_TIMEOUT_MS
      });
      const record: Record<string, Object> | null = parseRecord(response.body);
      if (record !== null) {
        const info: WireInfoResponse = Dto.parseInfoResponse(record);
        if (info.alias.length > 0) {
          task.peerAlias = info.alias;
        }
      }
    } catch (e) {
      this.log(`register ${task.target.host}:${task.target.port} failed: ${describeFailure(e)}`);
    }
  }

  /** False when the task reached a final state; the caller must then stop. */
  private async prepareUpload(task: SendTask, pin: string | null): Promise<boolean> {
    const files: Map<string, WireFile> = new Map<string, WireFile>();
    for (let i = 0; i < task.files.length; i++) {
      files.set(task.files[i].fileId, this.wireFile(task.files[i]));
    }
    const request: WirePrepareUploadRequest = { info: this.config.self(), files: files };
    const query: Map<string, string> = new Map<string, string>();
    if (pin !== null && pin.length > 0) {
      query.set('pin', pin);
    }
    let response: JsonResponse;
    try {
      response = await HttpClient.requestJson({
        target: this.targetOf(task),
        method: 'POST',
        path: ApiPath.PREPARE_UPLOAD,
        query: query,
        json: Dto.prepareUploadRequestToJson(request),
        credentials: this.config.credentials(),
        timeoutMs: CONNECT_TIMEOUT_MS
      });
    } catch (e) {
      return this.fail(`无法连接 ${task.target.host}:${task.target.port}: ${describePlatformError(e as Object, 'prepare')}`);
    }
    if (this.abortIfCancelled(task)) {
      return false;
    }
    if (response.status === Status.Ok) {
      const parsed: WirePrepareUploadResponse | null = Dto.parsePrepareUploadResponse(response.body);
      if (parsed === null) {
        return this.fail('接收方的应答无法解析');
      }
      task.sessionId = parsed.sessionId;
      let accepted: number = 0;
      for (let i = 0; i < task.files.length; i++) {
        const fileId: string = task.files[i].fileId;
        if (!parsed.files.has(fileId)) {
          task.files[i].status = SendFileStatus.SKIPPED;
          continue;
        }
        const token: string | undefined = parsed.files.get(fileId);
        if (token === undefined) {
          task.files[i].status = SendFileStatus.SKIPPED;
          continue;
        }
        task.files[i].token = token;
        task.files[i].status = SendFileStatus.PENDING;
        accepted++;
      }
      if (accepted === 0) {
        return this.finish('接收方没有选择任何文件', SendTaskStatus.CANCELED);
      }
      this.changed(true);
      return true;
    }
    if (response.status === Status.NoContent) {
      for (let i = 0; i < task.files.length; i++) {
        task.files[i].status = SendFileStatus.SKIPPED;
      }
      return this.finish('接收方没有选择任何文件', SendTaskStatus.CANCELED);
    }
    const detail: string = this.peerMessage(response.body);
    if (response.status === Status.Conflict) {
      return this.fail('接收方正在处理另一个传输');
    }
    if (response.status === Status.Unauthorized) {
      return this.fail(detail.length > 0 ? detail : '需要 PIN');
    }
    if (response.status === Status.TooManyRequests) {
      return this.fail('PIN 尝试次数过多，接收方已暂时封禁本机');
    }
    if (response.status === Status.Forbidden) {
      return this.fail(detail.length > 0 ? detail : '接收方拒绝了这次发送');
    }
    return this.fail(`接收方返回 ${response.status}${detail.length > 0 ? `: ${detail}` : ''}`);
  }

  private async uploadAccepted(task: SendTask): Promise<void> {
    const queue: SendFile[] = task.accepted();
    const workers: Promise<void>[] = [];
    const count: number = queue.length < UPLOAD_CONCURRENCY ? queue.length : UPLOAD_CONCURRENCY;
    for (let i = 0; i < count; i++) {
      workers.push(this.uploadWorker(task, queue));
    }
    await Promise.all(workers);
  }

  /** Files are pulled off one shared queue, so two big files never starve the smaller ones. */
  private async uploadWorker(task: SendTask, queue: SendFile[]): Promise<void> {
    while (!this.cancelRequested) {
      const file: SendFile | undefined = queue.shift();
      if (file === undefined) {
        return;
      }
      await this.uploadOne(task, file);
    }
  }

  private async uploadOne(task: SendTask, file: SendFile): Promise<void> {
    let lastError: string = '';
    for (let attempt = 1; attempt <= MAX_UPLOAD_ATTEMPTS; attempt++) {
      if (this.cancelRequested) {
        file.status = SendFileStatus.CANCELED;
        return;
      }
      file.attempts = attempt;
      file.sent = 0;
      file.status = SendFileStatus.SENDING;
      this.changed(true);
      const query: Map<string, string> = new Map<string, string>();
      query.set('sessionId', task.sessionId);
      query.set('fileId', file.fileId);
      query.set('token', file.token);
      let result: UploadResult | null = null;
      try {
        result = await HttpClient.upload({
          target: this.targetOf(task),
          method: 'POST',
          path: ApiPath.UPLOAD,
          query: query,
          credentials: this.config.credentials(),
          timeoutMs: CONNECT_TIMEOUT_MS
        }, this.fileBody(file), (sent: number, total: number): void => {
          file.sent = sent < total ? sent : total;
          this.changed(false);
        }, (): boolean => this.cancelRequested);
      } catch (e) {
        file.status = SendFileStatus.FAILED;
        file.error = describePlatformError(e as Object, `上传 ${file.fileName} 失败`);
        this.log(file.error);
        return;
      }
      if (result === null) {
        file.status = SendFileStatus.FAILED;
        file.error = `上传 ${file.fileName} 没有收到应答`;
        this.changed(true);
        return;
      }
      if (this.cancelRequested || result.cancelledLocally) {
        file.status = SendFileStatus.CANCELED;
        return;
      }
      if (result.status === Status.Ok) {
        file.sent = file.size;
        file.status = SendFileStatus.SUCCESS;
        file.error = '';
        this.changed(true);
        return;
      }
      // Only a lost-body corruption is worth another attempt; a rejection will not change its mind.
      if (result.status === Status.UnprocessableEntity) {
        lastError = '校验和不匹配';
        this.log(`${file.fileName} 第 ${attempt} 次上传校验失败`);
        continue;
      }
      file.status = SendFileStatus.FAILED;
      const detail: string = this.peerMessage(result.body);
      file.error = detail.length > 0 ? detail : `接收方返回 ${result.status}`;
      this.changed(true);
      return;
    }
    file.status = SendFileStatus.FAILED;
    file.error = `${lastError}（已重试 ${MAX_UPLOAD_ATTEMPTS} 次）`;
    this.changed(true);
  }

  /**
   * Streams one file into the request body. The receiver already knows the size and the checksum, so
   * the body is framed with Content-Length — chunked encoding would make peers that verify while
   * streaming re-frame the body before hashing it.
   */
  private fileBody(file: SendFile): StreamingBody {
    const body: StreamingBody = {
      length: file.size,
      produce: async (progress: SendProgress, write: (bytes: Uint8Array) => Promise<void>): Promise<void> => {
        const handle: fileIo.File = await fileIo.open(file.uri, fileIo.OpenMode.READ_ONLY);
        try {
          const window: ArrayBuffer = new ArrayBuffer(UPLOAD_CHUNK);
          while (!progress.isCancelled()) {
            const read: number = await fileIo.read(handle.fd, window);
            if (read <= 0) {
              break;
            }
            await write(new Uint8Array(window, 0, read));
            progress.sent += read;
          }
        } finally {
          try {
            await fileIo.close(handle);
          } catch (e) {
            // The response is what decides the outcome, not this close.
          }
        }
      }
    };
    return body;
  }

  private sendCancel(sessionId: string): void {
    if (this.cancelSent || this.task === null) {
      return;
    }
    this.cancelSent = true;
    const task: SendTask = this.task;
    const query: Map<string, string> = new Map<string, string>();
    if (sessionId.length > 0) {
      query.set('sessionId', sessionId);
    }
    // Fire and forget: the sender's own state machine does not wait for the receiver's answer, and
    // a failed cancel is indistinguishable from one that raced the session ending.
    HttpClient.requestJson({
      target: this.targetOf(task),
      method: 'POST',
      path: ApiPath.CANCEL,
      query: query,
      credentials: this.config.credentials(),
      timeoutMs: CONNECT_TIMEOUT_MS
    }).catch((reason: Object): void => {
      this.log(`cancel failed: ${describeFailure(reason)}`);
    });
  }

  // ------------------------------------------------------------------- helpers

  private targetOf(task: SendTask): Target {
    const target: Target = {
      host: task.target.host,
      port: task.target.port,
      scheme: task.target.scheme
    };
    return target;
  }

  private wireFile(file: SendFile): WireFile {
    const entry: WireFile = {
      id: file.fileId,
      fileName: file.fileName,
      size: file.size,
      fileType: file.fileType,
      sha256: file.sha256
    };
    if (file.modifiedMs > 0) {
      const metadata: WireFileMetadata = { modified: new Date(file.modifiedMs).toISOString() };
      entry.metadata = metadata;
    }
    return entry;
  }

  private peerMessage(body: string): string {
    const record: Record<string, Object> | null = parseRecord(body);
    if (record === null) {
      return '';
    }
    const message: string | null = readString(record, 'message');
    return message === null ? '' : message;
  }

  private abortIfCancelled(task: SendTask): boolean {
    if (!this.cancelRequested) {
      return false;
    }
    for (let i = 0; i < task.files.length; i++) {
      const status: SendFileStatus = task.files[i].status;
      if (status !== SendFileStatus.SUCCESS && status !== SendFileStatus.FAILED) {
        task.files[i].status = SendFileStatus.CANCELED;
      }
    }
    task.status = SendTaskStatus.CANCELED;
    this.changed(true);
    // A session was created after we gave up on it: tell the receiver so its slot frees up.
    if (task.sessionId.length > 0 && !this.cancelSent) {
      this.sendCancel(task.sessionId);
    }
    return true;
  }

  /** True, so `if (!await this.prepareUpload(...)) return;` reads as the failure it is. */
  private fail(message: string): boolean {
    this.finish(message, SendTaskStatus.FAILED);
    return false;
  }

  private finish(message: string, status: SendTaskStatus): boolean {
    const task: SendTask | null = this.task;
    if (task !== null) {
      task.error = message;
      task.status = status;
    }
    this.log(message);
    this.changed(true);
    return status === SendTaskStatus.SUCCESS;
  }

  private summarize(task: SendTask): void {
    let failed: string = '';
    for (let i = 0; i < task.files.length; i++) {
      if (task.files[i].status === SendFileStatus.FAILED && failed.length === 0) {
        failed = task.files[i].error;
      }
    }
    if (failed.length > 0) {
      this.finish(failed, SendTaskStatus.FAILED);
      return;
    }
    this.finish('', SendTaskStatus.SUCCESS);
  }

  private log(message: string): void {
    const sink: ((message: string) => void) | undefined = this.config.log;
    if (sink !== undefined) {
      sink(message);
    }
  }

  /** Immediate on a state change, throttled while bytes are only moving. */
  private changed(now: boolean): void {
    const stamp: number = Date.now();
    if (!now && stamp - this.lastEmitMs < PROGRESS_MIN_INTERVAL_MS) {
      return;
    }
    this.lastEmitMs = stamp;
    this.config.onChanged();
  }
}
