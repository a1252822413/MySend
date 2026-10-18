// 传输历史：收发完成（或失败）后落一条记录，持久化到沙箱 JSON。
// 对应 PC 端 Services/TransferHistoryService.cs。
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Log } from '../common/Logger';

export class HistoryFile {
  name: string = '';
  size: number = 0;
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
      this.records = JSON.parse(text) as HistoryRecord[];
    } catch (e) {
      Log.e(`历史加载失败: ${String(e)}`);
      this.records = [];
    }
  }

  private save(): void {
    try {
      const f = fs.openSync(this.path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify(this.records));
      fs.closeSync(f.fd);
    } catch (e) {
      Log.e(`历史保存失败: ${String(e)}`);
    }
  }
}

export const historyService = new HistoryServiceImpl();
