// 传输历史：收发完成（或失败）后落一条记录，持久化到沙箱 JSON。
// 对应 PC 端 Services/TransferHistoryService.cs。
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Log } from '../common/Logger';

export class HistoryFile {
  name: string = '';
  size: number = 0;
  /** 接收文件的绝对路径（用于「打开」；发送记录为空） */
  path: string = '';
}

export class HistoryRecord {
  id: string = '';
  /** 'send' | 'receive' */
  direction: string = 'receive';
  peerAlias: string = '';
  peerIp: string = '';
  files: HistoryFile[] = [];
  totalSize: number = 0;
  timestamp: number = 0;
  success: boolean = true;
}

class HistoryServiceImpl {
  private path: string = '';
  private records: HistoryRecord[] = [];

  init(context: common.Context): void {
    this.path = `${context.filesDir}/history.json`;
    this.load();
    Log.i(`历史记录已加载 ${this.records.length} 条`);
  }

  list(): HistoryRecord[] {
    return this.records;
  }

  add(record: HistoryRecord): void {
    this.records.unshift(record);
    // 只保留最近 200 条，避免文件无限增长
    if (this.records.length > 200) {
      this.records = this.records.slice(0, 200);
    }
    this.save();
  }

  clear(): void {
    this.records = [];
    this.save();
    Log.i('历史记录已清空');
  }

  private load(): void {
    try {
      if (this.path.length === 0 || !fs.accessSync(this.path)) {
        return;
      }
      const text = fs.readTextSync(this.path);
      if (text.length === 0) {
        return;
      }
      const parsed = JSON.parse(text) as HistoryRecord[];
      if (Array.isArray(parsed)) {
        this.records = parsed;
      } else {
        Log.w('历史文件格式不对（不是数组），丢弃');
        this.records = [];
      }
    } catch (e) {
      // 文件损坏时先留一份 .bak 再清空，避免下一次保存把用户唯一的记录覆盖掉
      Log.e(`历史加载失败: ${String(e)}`);
      try {
        fs.copyFileSync(this.path, `${this.path}.bak`);
        Log.w('已备份损坏的历史文件到 history.json.bak');
      } catch (e2) {
        Log.w(`备份历史文件失败: ${String(e2)}`);
      }
      this.records = [];
    }
  }

  /** 原子写：先写临时文件再改名，避免写到一半被打断导致整个历史不可读 */
  private save(): void {
    const tmp = `${this.path}.tmp`;
    try {
      const f = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify(this.records));
      fs.closeSync(f.fd);
      // rename 覆盖旧文件是原子的：要么新内容完整，要么还是旧内容
      fs.renameSync(tmp, this.path);
    } catch (e) {
      Log.e(`历史保存失败: ${String(e)}`);
    }
  }
}

export const historyService = new HistoryServiceImpl();
