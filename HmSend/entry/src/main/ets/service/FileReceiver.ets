// 接收会话与文件落盘。
// 对应 PC 端 Services/ReceiveSessionManager.cs + FileSaver.cs + PathHelper 的安全路径逻辑。
//
// 与 PC 端一致的三条硬规则：
//   1) 路径穿越防护：绝对路径 / ".." / 盘符 一律拒绝
//   2) 文件名冲突自动加 _1/_2 后缀
//   3) 大文件流式写入，绝不整包进内存
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Log } from '../common/Logger';
import { Const } from '../common/Constants';
import { FileDto, PrepareUploadResponseDto } from '../model/Types';
import { historyService, HistoryRecord, HistoryFile } from './HistoryService';

/** 单个接收文件的状态 */
export class ReceiveFile {
  id: string = '';
  fileName: string = '';
  size: number = 0;
  token: string = '';
  /** 已入队字节数（进度用） */
  received: number = 0;
  /** 已真正落盘字节数 */
  written: number = 0;
  /** 待写队列：message 回调里只入队，不在回调内做同步 IO */
  queue: Uint8Array[] = [];
  writing: boolean = false;
  fd: number = -1;
  absPath: string = '';
  sessionId: string = '';
}

/** 一次接收会话（一个发送方 + 一批文件） */
export class ReceiveSession {
  sessionId: string = '';
  senderIp: string = '';
  senderAlias: string = '';
  files: Map<string, ReceiveFile> = new Map<string, ReceiveFile>();
  createdAt: number = 0;
  doneCount: number = 0;
}

/** 接收进度（供界面展示；active=false 表示本次会话已结束） */
export class ReceiveProgress {
  active: boolean = false;
  senderAlias: string = '';
  /** 当前文件 */
  fileName: string = '';
  received: number = 0;
  total: number = 0;
  /** 字节/秒（滑动估算，可能为 0） */
  speed: number = 0;
  doneFiles: number = 0;
  totalFiles: number = 0;
}

export class OpenFileResult {
  statusCode: number = 400;
  message: string = '';
  file: ReceiveFile | null = null;
}

class FileReceiverImpl {
  private baseDir: string = '';
  private sessions: Map<string, ReceiveSession> = new Map<string, ReceiveSession>();
  private progressListener: ((p: ReceiveProgress) => void) | null = null;
  private lastEmitAt: number = 0;
  private lastBytes: number = 0;
  private lastTime: number = 0;

  /** 订阅接收进度（界面用） */
  setProgressListener(cb: (p: ReceiveProgress) => void): void {
    this.progressListener = cb;
  }

  /** 接收目录（设置页展示用） */
  receivedDir(): string {
    return this.baseDir;
  }

  /**
   * 汇总会话进度并回调。
   * 节流 150ms：8KB 一个数据块，全速时每秒上百次回调，不节流会拖慢界面。
   */
  private emitProgress(session: ReceiveSession, fileName: string, active: boolean, force: boolean): void {
    const cb = this.progressListener;
    if (cb === null) {
      return;
    }
    const now = Date.now();
    if (!force && now - this.lastEmitAt < 150) {
      return;
    }
    let received = 0;
    let total = 0;
    session.files.forEach((f: ReceiveFile) => {
      received += f.received;
      total += f.size;
    });
    const dt = now - this.lastTime;
    let speed = 0;
    if (dt > 0 && this.lastTime > 0) {
      speed = Math.round((received - this.lastBytes) * 1000 / dt);
    }
    this.lastEmitAt = now;
    this.lastTime = now;
    this.lastBytes = received;

    const p = new ReceiveProgress();
    p.active = active;
    p.senderAlias = session.senderAlias;
    p.fileName = fileName;
    p.received = received;
    p.total = total;
    p.speed = speed > 0 ? speed : 0;
    p.doneFiles = session.doneCount;
    p.totalFiles = session.files.size;
    cb(p);
  }

  init(context: common.Context): void {
    this.baseDir = `${context.filesDir}/${Const.RECEIVED_DIR_NAME}`;
    try {
      if (!fs.accessSync(this.baseDir)) {
        fs.mkdirSync(this.baseDir);
      }
    } catch (e) {
      Log.e(`接收目录创建失败: ${JSON.stringify(e)}`);
    }
    Log.i(`接收目录: ${this.baseDir}`);
  }

  /** 创建会话并下发每个文件的 token（对应 /prepare-upload 的响应） */
  createSession(files: Record<string, FileDto>, senderIp: string, acceptedIds: string[],
    senderAlias: string): PrepareUploadResponseDto {
    const session = new ReceiveSession();
    session.sessionId = FileReceiverImpl.randomHex(16);
    session.senderIp = senderIp;
    session.senderAlias = senderAlias;
    session.createdAt = Date.now();

    const tokens: Record<string, string> = {};
    // 只给被接受的文件下发 token：发送方只会传有 token 的文件
    const ids = acceptedIds;
    for (let i = 0; i < ids.length; i++) {
      const id = ids[i];
      const dto = files[id];
      const rf = new ReceiveFile();
      rf.id = id;
      rf.fileName = dto.fileName;
      rf.size = dto.size;
      rf.token = FileReceiverImpl.randomHex(8);
      rf.sessionId = session.sessionId;
      session.files.set(id, rf);
      tokens[id] = rf.token;
    }

    this.sessions.set(session.sessionId, session);
    Log.i(`会话建立 ${session.sessionId.substring(0, 8)} 文件数=${ids.length} 发送方=${senderIp}`);

    const resp: PrepareUploadResponseDto = {
      sessionId: session.sessionId,
      files: tokens
    };
    return resp;
  }

  /** 校验 session/token 并打开文件准备写入 */
  openFile(sessionId: string, fileId: string, token: string): OpenFileResult {
    const result = new OpenFileResult();
    const session = this.sessions.get(sessionId);
    if (session === undefined) {
      result.statusCode = 403;
      result.message = 'Invalid session';
      return result;
    }
    const file = session.files.get(fileId);
    if (file === undefined || file.token !== token) {
      result.statusCode = 403;
      result.message = 'Invalid token';
      return result;
    }

    const target = this.resolveSafePath(file.fileName);
    if (target === null) {
      result.statusCode = 400;
      result.message = 'Unsafe file name';
      return result;
    }

    try {
      const handle = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      file.fd = handle.fd;
      file.absPath = target;
      file.received = 0;
      result.statusCode = 200;
      result.file = file;
      Log.i(`开始接收 ${file.fileName} -> ${target}`);
      // 新会话起点：重置速度采样
      this.lastBytes = 0;
      this.lastTime = Date.now();
      this.emitProgress(session, file.fileName, true, true);
    } catch (e) {
      result.statusCode = 500;
      result.message = `Open failed: ${JSON.stringify(e)}`;
      Log.e(result.message);
    }
    return result;
  }

  /**
   * 追加写入（异步队列）。
   * 为什么不在回调里直接 fs.writeSync：鸿蒙的 TLS 数据是按 8KB 一条 message 下发的，
   * 如果回调里做同步磁盘 IO，原生接收环会先填满（实测卡在整 4MB），之后事件不再投递，
   * 传输永久停摆。改成"回调只入队 + 后台异步落盘"，回调立即返回，消费速度跟得上。
   * 返回入队字节数（进度用）。
   */
  write(file: ReceiveFile, data: Uint8Array): number {
    if (file.fd < 0) {
      return 0;
    }
    // 必须复制：底层 ArrayBuffer 会被复用
    const copy = new Uint8Array(data.length);
    copy.set(data, 0);
    file.queue.push(copy);
    file.received += copy.length;
    this.drain(file);
    const session = this.sessions.get(file.sessionId);
    if (session !== undefined) {
      this.emitProgress(session, file.fileName, true, false);
    }
    return copy.length;
  }

  /** 后台排空队列（不阻塞调用方） */
  private async drain(file: ReceiveFile): Promise<void> {
    if (file.writing) {
      return;
    }
    file.writing = true;
    try {
      while (file.queue.length > 0) {
        const chunk = file.queue.shift();
        if (chunk === undefined) {
          break;
        }
        const view = chunk.buffer.slice(0, chunk.length);
        const n = await fs.write(file.fd, view, { offset: file.written });
        file.written += n;
      }
    } catch (e) {
      Log.e(`写入失败 ${file.fileName}: ${JSON.stringify(e)}`);
    } finally {
      file.writing = false;
    }
  }

  /** 等待队列全部落盘（响应 200 之前调用） */
  async flush(file: ReceiveFile): Promise<void> {
    let guard = 0;
    while ((file.queue.length > 0 || file.writing) && guard < 3000) {
      await FileReceiverImpl.sleep(10);
      guard++;
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  close(file: ReceiveFile): void {
    if (file.fd >= 0) {
      try {
        fs.closeSync(file.fd);
      } catch (e) {
        Log.w(`关闭文件失败: ${JSON.stringify(e)}`);
      }
      file.fd = -1;
    }
    Log.i(`接收完成 ${file.fileName} (${file.received}/${file.size})`);
    this.onFileClosed(file);
  }

  /** 一个文件写完：若会话内全部完成，落一条历史记录 */
  private onFileClosed(file: ReceiveFile): void {
    const session = this.sessions.get(file.sessionId);
    if (session === undefined) {
      return;
    }
    session.doneCount++;
    if (session.doneCount < session.files.size) {
      return;
    }

    const record = new HistoryRecord();
    record.id = session.sessionId;
    record.direction = 'receive';
    record.peerAlias = session.senderAlias;
    record.peerIp = session.senderIp;
    record.timestamp = Date.now();
    record.success = true;
    let total = 0;
    session.files.forEach((f: ReceiveFile) => {
      const hf = new HistoryFile();
      hf.name = f.fileName;
      hf.size = f.size;
      hf.path = f.absPath;
      record.files.push(hf);
      total += f.size;
    });
    record.totalSize = total;
    historyService.add(record);
    this.emitProgress(session, '', false, true);
    this.sessions.delete(session.sessionId);
  }

  /** 取消会话：关闭所有句柄并删除残留文件 */
  cancel(sessionId: string): boolean {
    const session = this.sessions.get(sessionId);
    if (session === undefined) {
      return false;
    }
    session.files.forEach((f: ReceiveFile) => {
      this.close(f);
      if (f.absPath.length > 0) {
        try {
          fs.unlinkSync(f.absPath);
        } catch (e) {
          Log.w(`删除半成品失败: ${JSON.stringify(e)}`);
        }
      }
    });
    this.emitProgress(session, '', false, true);
    this.sessions.delete(sessionId);
    Log.i(`会话取消 ${sessionId.substring(0, 8)}`);
    return true;
  }

  /**
   * 安全路径解析（与 PC 端 ResolveSafeDestinationPath 对齐）：
   * 拒绝绝对路径、.. 段、盘符；非法字符替换为 _；冲突自动加后缀。
   */
  private resolveSafePath(rawName: string): string | null {
    if (rawName === undefined || rawName.length === 0) {
      return null;
    }
    const norm = rawName.replace(new RegExp('\\\\', 'g'), '/');
    if (norm.startsWith('/')) {
      return null;
    }
    const parts = norm.split('/');
    const safeParts: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const seg = parts[i].trim();
      if (seg.length === 0) {
        continue;
      }
      if (seg === '.' || seg === '..') {
        return null;
      }
      // 盘符形态（C:）
      if (seg.length === 2 && seg.charAt(1) === ':') {
        return null;
      }
      const cleaned = this.sanitize(seg);
      if (cleaned.length > 0) {
        safeParts.push(cleaned);
      }
    }
    if (safeParts.length === 0) {
      return null;
    }

    let dir = this.baseDir;
    for (let i = 0; i < safeParts.length - 1; i++) {
      dir = `${dir}/${safeParts[i]}`;
      try {
        if (!fs.accessSync(dir)) {
          fs.mkdirSync(dir);
        }
      } catch (e) {
        Log.w(`创建子目录失败 ${dir}: ${JSON.stringify(e)}`);
      }
    }
    const name = this.uniqueName(dir, safeParts[safeParts.length - 1]);
    return `${dir}/${name}`;
  }

  private sanitize(seg: string): string {
    let out = '';
    const invalid = '<>:"/\\|?*';
    for (let i = 0; i < seg.length; i++) {
      const ch = seg.charAt(i);
      out += invalid.indexOf(ch) >= 0 || seg.charCodeAt(i) < 32 ? '_' : ch;
    }
    out = out.trim();
    while (out.endsWith('.')) {
      out = out.substring(0, out.length - 1);
    }
    if (out.length === 0) {
      return '_';
    }
    return out.length > 200 ? out.substring(0, 200) : out;
  }

  private uniqueName(dir: string, name: string): string {
    let candidate = name;
    const dot = name.lastIndexOf('.');
    const stem = dot > 0 ? name.substring(0, dot) : name;
    const ext = dot > 0 ? name.substring(dot) : '';
    let i = 1;
    while (true) {
      try {
        if (!fs.accessSync(`${dir}/${candidate}`)) {
          return candidate;
        }
      } catch (e) {
        return candidate;
      }
      candidate = `${stem}_${i}${ext}`;
      i++;
      if (i > 999) {
        candidate = `${stem}_${Date.now()}${ext}`;
        return candidate;
      }
    }
  }

  private static randomHex(len: number): string {
    let out = '';
    const chars = '0123456789abcdef';
    for (let i = 0; i < len; i++) {
      out += chars.charAt(Math.floor(Math.random() * 16));
    }
    return out;
  }
}

export const fileReceiver = new FileReceiverImpl();
