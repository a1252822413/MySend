// 系统分享面板接入。
//
// 其他应用（相册、文件管理、微信……）通过「分享」把文件送到快传时，系统会用
// action=ohos.want.action.sendData 拉起 EntryAbility，文件 URI 放在
// want.parameters['ability.params.stream']（string[]）。
//
// 为什么要先复制到沙箱：分享带来的读权限是临时的，而发送可能持续几十秒到大文件
// 传输结束，期间权限可能已过期；复制一份到 cacheDir 后发送全程都稳定。
import { common, Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Log } from '../common/Logger';

/** 分享进来的一个文件（复制到沙箱后的副本） */
export class ShareFile {
  path: string = '';
  name: string = '';
  size: number = 0;
}

class ShareInboxImpl {
  /** 分享副本清理是否已跑过（每个进程一次即可） */
  private static cleaned: boolean = false;

  private pending: ShareFile[] = [];
  private listener: ((files: ShareFile[]) => void) | null = null;

  setListener(cb: (files: ShareFile[]) => void): void {
    this.listener = cb;
  }

  /** 页面首次加载时取走积压的文件（冷启动场景：want 先到，页面后建） */
  take(): ShareFile[] {
    const out = this.pending;
    this.pending = [];
    return out;
  }

  /** 处理分享进来的 want；不是分享场景时直接返回 */
  async intake(want: Want, ctx: common.UIAbilityContext): Promise<void> {
    const uris = ShareInboxImpl.extractUris(want);
    if (uris.length === 0) {
      return;
    }
    Log.i(`收到系统分享：${uris.length} 个文件`);

    const dir = `${ctx.cacheDir}/shares`;
    try {
      fs.mkdirSync(dir, true);
    } catch (e) {
      // 目录已存在
    }
    if (!ShareInboxImpl.cleaned) {
      ShareInboxImpl.cleaned = true;
      ShareInboxImpl.purgeOld(dir);
    }

    const out: ShareFile[] = [];
    for (let i = 0; i < uris.length; i++) {
      const uri = uris[i];
      const file = await this.copyIn(uri, dir);
      if (file !== null) {
        out.push(file);
      }
    }
    if (out.length === 0) {
      Log.w('分享的文件全部导入失败');
      return;
    }
    Log.i(`分享文件已导入 ${out.length} 个`);

    this.pending = out;
    const cb = this.listener;
    if (cb !== null) {
      this.pending = [];
      cb(out);
    }
  }

  /** 清理 3 天前的分享副本，避免缓存无限增长 */
  private static purgeOld(dir: string): void {
    const maxAge = 3 * 24 * 3600 * 1000;
    const now = Date.now();
    try {
      const names = fs.listFileSync(dir);
      let removed = 0;
      for (let i = 0; i < names.length; i++) {
        const path = `${dir}/${names[i]}`;
        try {
          const st = fs.statSync(path);
          if (now - st.mtime * 1000 > maxAge) {
            fs.unlinkSync(path);
            removed++;
          }
        } catch (e) {
          // 单个文件失败不影响其它
        }
      }
      if (removed > 0) {
        Log.i(`已清理 ${removed} 个过期分享副本`);
      }
    } catch (e) {
      // 目录为空或不可读，忽略
    }
  }

  /** 从 want 里取文件 URI 列表 */
  private static extractUris(want: Want): string[] {
    const out: string[] = [];
    const params = want.parameters;
    if (params !== undefined) {
      const raw = params['ability.params.stream'];
      if (Array.isArray(raw)) {
        const arr = raw as string[];
        for (let i = 0; i < arr.length; i++) {
          if (typeof arr[i] === 'string' && arr[i].length > 0) {
            out.push(arr[i]);
          }
        }
      } else if (typeof raw === 'string' && (raw as string).length > 0) {
        out.push(raw as string);
      }
    }
    // 单个文件时有些应用只填 want.uri
    if (out.length === 0 && want.uri !== undefined && want.uri.length > 0) {
      out.push(want.uri);
    }
    return out;
  }

  /** 把一个 URI 复制到沙箱，返回副本信息 */
  private async copyIn(uri: string, dir: string): Promise<ShareFile | null> {
    let name = 'shared_file';
    try {
      const slash = uri.lastIndexOf('/');
      if (slash >= 0 && slash + 1 < uri.length) {
        name = decodeURIComponent(uri.substring(slash + 1));
      }
    } catch (e) {
      // 名字解析失败就用默认名
    }

    const dest = `${dir}/${Date.now()}_${name}`;
    try {
      // 优先用系统 API 直接复制（对 media/docs URI 兼容性最好）
      fs.copyFileSync(uri, dest);
    } catch (e) {
      Log.w(`copyFileSync 失败，改用流式复制: ${String(e)}`);
      const ok = ShareInboxImpl.copyByStream(uri, dest);
      if (!ok) {
        return null;
      }
    }

    const file = new ShareFile();
    file.path = dest;
    file.name = name;
    try {
      const st = fs.statSync(dest);
      file.size = st.size;
    } catch (e) {
      file.size = 0;
    }
    return file;
  }

  /** 兜底：逐块读写（沙箱外的 URI 有时不支持 copyFile） */
  private static copyByStream(uri: string, dest: string): boolean {
    let srcFd = -1;
    let dstFd = -1;
    try {
      srcFd = fs.openSync(uri, fs.OpenMode.READ_ONLY).fd;
      dstFd = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC).fd;
      const buf = new ArrayBuffer(64 * 1024);
      while (true) {
        const n = fs.readSync(srcFd, buf);
        if (n <= 0) {
          break;
        }
        if (n === buf.byteLength) {
          fs.writeSync(dstFd, buf);
        } else {
          fs.writeSync(dstFd, buf.slice(0, n));
        }
      }
      return true;
    } catch (e) {
      Log.e(`流式复制失败: ${String(e)}`);
      return false;
    } finally {
      if (srcFd >= 0) {
        try {
          fs.closeSync(srcFd);
        } catch (e) {
        }
      }
      if (dstFd >= 0) {
        try {
          fs.closeSync(dstFd);
        } catch (e) {
        }
      }
    }
  }
}

export const shareInbox = new ShareInboxImpl();
