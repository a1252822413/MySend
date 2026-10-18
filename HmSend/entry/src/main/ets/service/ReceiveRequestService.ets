// 接收请求仲裁：把"等用户点接收/拒绝"这件事从 HTTP 处理线程里剥离出来。
//
// 协议要求：prepare-upload 收到后必须**挂住连接**，等用户决策完再回 200（含 token）
// 或 403（拒绝）。所以这里用一个 Promise + 超时来桥接服务端逻辑与 UI。
import { FileDto } from '../model/Types';
import { Log } from '../common/Logger';

export class ReceiveRequest {
  id: string = '';
  alias: string = '';
  ip: string = '';
  files: FileDto[] = [];
  totalSize: number = 0;

  private resolver: ((accepted: string[]) => void) | null = null;
  private timer: number = -1;

  /** 等 UI 决策；超时视为拒绝（否则发送方会一直挂着） */
  waitForDecision(timeoutMs: number): Promise<string[]> {
    return new Promise<string[]>((resolve: (v: string[]) => void) => {
      this.resolver = resolve;
      this.timer = setTimeout(() => {
        Log.w(`接收请求 ${this.id} 等待超时，自动拒绝`);
        this.settle([]);
      }, timeoutMs);
    });
  }

  settle(accepted: string[]): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    const r = this.resolver;
    this.resolver = null;
    if (r !== null) {
      r(accepted);
    }
  }

  isPending(): boolean {
    return this.resolver !== null;
  }
}

class ReceiveRequestServiceImpl {
  private current: ReceiveRequest | null = null;
  private listener: ((req: ReceiveRequest | null) => void) | null = null;

  setListener(cb: (req: ReceiveRequest | null) => void): void {
    this.listener = cb;
  }

  getCurrent(): ReceiveRequest | null {
    return this.current;
  }

  /** 发起一次待决策请求，返回被接受的文件 id 列表（空数组 = 拒绝） */
  async ask(alias: string, ip: string, files: Record<string, FileDto>, timeoutMs: number): Promise<string[]> {
    // 同一时刻只处理一个请求：若已有待决策，先拒绝旧的，避免发送方无限等待
    const old = this.current;
    if (old !== null && old.isPending()) {
      Log.w('已有待决策请求，拒绝旧请求');
      old.settle([]);
    }

    const req = new ReceiveRequest();
    req.id = `${Date.now()}`;
    req.alias = alias;
    req.ip = ip;
    req.files = [];
    let total = 0;
    const ids = Object.keys(files);
    for (let i = 0; i < ids.length; i++) {
      const f = files[ids[i]];
      req.files.push(f);
      total += f.size;
    }
    req.totalSize = total;

    this.current = req;
    this.notify(req);

    const accepted = await req.waitForDecision(timeoutMs);
    this.current = null;
    this.notify(null);
    Log.i(`接收请求 ${req.id} 决策结果：接受 ${accepted.length}/${ids.length} 个文件`);
    return accepted;
  }

  /** UI 调用：传入被接受的文件 id；传空数组表示整体拒绝 */
  decide(accepted: string[]): void {
    const c = this.current;
    if (c !== null) {
      c.settle(accepted);
    }
  }

  private notify(req: ReceiveRequest | null): void {
    const cb = this.listener;
    if (cb !== null) {
      cb(req);
    }
  }
}

export const receiveRequests = new ReceiveRequestServiceImpl();
