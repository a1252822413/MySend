// 主页面：底部四 Tab（接收 / 发送 / 历史 / 设置），与 PC 端页面结构对齐。
// 当前为 M0：接收页真实展示组播发现的设备，设置页可改别名/PIN/HTTPS 并即时重启服务。
import { settingsService, Settings } from '../service/SettingsService';
import { deviceRegistry } from '../service/DeviceRegistry';
import { httpServer } from '../service/HttpServer';
import { discoveryService } from '../service/DiscoveryService';
import { Log } from '../common/Logger';
import { Const } from '../common/Constants';
import { DeviceItem } from '../model/Types';
import { sendClient, SendFileItem, SendResult } from '../service/SendClient';
import { receiveRequests, ReceiveRequest } from '../service/ReceiveRequestService';
import { historyService, HistoryRecord } from '../service/HistoryService';
import { subnetScanner } from '../service/SubnetScanner';
import { shareInbox, ShareFile } from '../service/ShareInbox';
import { picker, fileUri } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common, wantConstant } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileReceiver, ReceiveProgress } from '../service/FileReceiver';
import { notifyService } from '../service/NotifyService';
import { AppState } from '../common/AppState';

const GREEN: string = '#16A34A';
const BG: string = '#F3F5F7';
const CARD: string = '#FFFFFF';
const TEXT: string = '#1A1D21';
const SUB: string = '#6B7280';
const LINE: string = '#E5E7EB';

/** 另存结果（把失败原因带回界面，避免只显示一句「失败」） */
class SaveResult {
  ok: boolean = false;
  message: string = '';
}

@Entry
@Component
struct Index {
  @State devices: DeviceItem[] = [];
  @State currentTab: number = 0;

  @State alias: string = '';
  @State port: number = Const.DEFAULT_PORT;
  @State protocolText: string = 'https';
  @State fingerprint: string = '';
  @State httpsOn: boolean = true;
  @State pin: string = '';
  @State autoAccept: boolean = false;
  @State albumAuto: boolean = true;
  @State serverState: string = '';

  // ---- 发送页状态 ----
  @State selectedTargets: string[] = [];
  @State sendFiles: SendFileItem[] = [];
  @State pinInput: string = '';
  @State sending: boolean = false;
  @State sentBytes: number = 0;
  @State totalBytes: number = 0;
  @State currentFile: string = '';
  @State sendTip: string = '';

  // ---- 接收确认弹层状态 ----
  @State hasRequest: boolean = false;
  @State reqAlias: string = '';
  @State reqFiles: ReqFileRow[] = [];
  @State reqTotal: number = 0;
  @State reqChecked: string[] = [];

  // ---- 历史页 ----
  @State history: HistoryRecord[] = [];

  // ---- 子网扫描 ----
  @State scanning: boolean = false;
  @State scanText: string = '';

  // ---- 接收进度 ----
  @State rxActive: boolean = false;
  @State rxName: string = '';
  @State rxReceived: number = 0;
  @State rxTotal: number = 0;
  @State rxSpeed: number = 0;
  @State rxDoneFiles: number = 0;
  @State rxTotalFiles: number = 0;

  private timerId: number = -1;

  aboutToAppear(): void {
    deviceRegistry.setListener(() => {
      this.devices = deviceRegistry.list();
    });
    receiveRequests.setListener((req: ReceiveRequest | null) => {
      this.onReceiveRequest(req);
    });
    // 接收进度（含完成事件）
    fileReceiver.setProgressListener((p: ReceiveProgress) => {
      this.onReceiveProgress(p);
    });
    // 运行中从别的应用分享进来：直接填到发送页
    shareInbox.setListener((files: ShareFile[]) => {
      this.applyShareFiles(files);
    });
    // 冷启动就是分享场景：want 可能比页面更早到达
    const pending = shareInbox.take();
    if (pending.length > 0) {
      this.applyShareFiles(pending);
    }
    this.refreshLocal();
    this.devices = deviceRegistry.list();
    this.history = historyService.list();
    // 每 5 秒刷新一次，保证超时设备自动消失
    this.timerId = setInterval(() => {
      deviceRegistry.purgeOffline();
      this.devices = deviceRegistry.list();
      // 已在历史页时也定期刷新：收到文件后用户可能不切页，靠 onChange 不够
      if (this.currentTab === 2) {
        this.history = historyService.list();
      }
    }, 3000);
  }

  aboutToDisappear(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private onReceiveRequest(req: ReceiveRequest | null): void {
    if (req === null) {
      this.hasRequest = false;
      this.reqFiles = [];
      this.reqChecked = [];
      return;
    }
    const rows: ReqFileRow[] = [];
    const checked: string[] = [];
    for (let i = 0; i < req.files.length; i++) {
      const f = req.files[i];
      const row = new ReqFileRow();
      row.id = f.id;
      row.name = f.fileName;
      row.size = f.size;
      rows.push(row);
      checked.push(f.id);
    }
    this.reqAlias = req.alias;
    this.reqFiles = rows;
    this.reqTotal = req.totalSize;
    this.reqChecked = checked;
    this.hasRequest = true;
  }

  private isChecked(id: string): boolean {
    return this.reqChecked.indexOf(id) >= 0;
  }

  private toggleCheck(id: string): void {
    const next: string[] = [];
    let removed = false;
    for (let i = 0; i < this.reqChecked.length; i++) {
      if (this.reqChecked[i] === id) {
        removed = true;
      } else {
        next.push(this.reqChecked[i]);
      }
    }
    if (!removed) {
      next.push(id);
    }
    this.reqChecked = next;
  }

  private selectAll(on: boolean): void {
    if (!on) {
      this.reqChecked = [];
      return;
    }
    const all: string[] = [];
    for (let i = 0; i < this.reqFiles.length; i++) {
      all.push(this.reqFiles[i].id);
    }
    this.reqChecked = all;
  }

  /** 接收进度浮层：任何页面都能看到（PC 发文件时用户可能不在接收页） */
  @Builder
  RxProgressCard() {
    Column({ space: 6 }) {
      Row() {
        Text('正在接收').fontSize(12).fontColor(Color.White)
        Blank()
        Text(`${this.rxDoneFiles}/${this.rxTotalFiles}`).fontSize(11).fontColor('#D1FAE5')
      }
      .width('100%')

      Text(this.rxName)
        .fontSize(13)
        .fontColor(Color.White)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Progress({
        value: this.rxTotal > 0 ? (this.rxReceived / this.rxTotal) * 100 : 0,
        total: 100,
        type: ProgressType.Linear
      })
        .width('100%')
        .height(4)
        .color('#A7F3D0')
        .backgroundColor('#15803D')

      Row() {
        Text(this.humanSize(this.rxReceived) + ' / ' + this.humanSize(this.rxTotal))
          .fontSize(11).fontColor('#D1FAE5')
        Blank()
        Text(this.rxSpeed > 0 ? `${this.humanSize(this.rxSpeed)}/s` : '')
          .fontSize(11).fontColor('#D1FAE5')
      }
      .width('100%')
    }
    .padding(14)
    .margin({ left: 16, right: 16, bottom: 76 })
    .backgroundColor('#166534')
    .borderRadius(14)
    .width('calc(100% - 32vp)')
  }

  @Builder
  ReceiveRequestLayer() {
    Column() {
      Column({ space: 12 }) {
        Text(`${this.reqAlias} 想发送给你`).fontSize(16).fontWeight(FontWeight.Medium).fontColor(TEXT)
        Text(`${this.reqFiles.length} 个文件 · ${this.humanSize(this.reqTotal)}`)
          .fontSize(12).fontColor(SUB)

        Row({ space: 16 }) {
          Text('全选').fontSize(12).fontColor(GREEN).onClick(() => {
            this.selectAll(true);
          })
          Text('全不选').fontSize(12).fontColor(SUB).onClick(() => {
            this.selectAll(false);
          })
        }
        .width('100%')

        List({ space: 4 }) {
          ForEach(this.reqFiles, (row: ReqFileRow) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(this.isChecked(row.id) ? '●' : '○')
                  .fontSize(14).fontColor(this.isChecked(row.id) ? GREEN : SUB)
                Column({ space: 2 }) {
                  Text(row.name).fontSize(13).fontColor(TEXT).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.humanSize(row.size)).fontSize(11).fontColor(SUB)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              .onClick(() => {
                this.toggleCheck(row.id);
              })
            }
          }, (row: ReqFileRow) => row.id)
        }
        .height(200)
        .width('100%')

        Row({ space: 12 }) {
          Button('拒绝')
            .layoutWeight(1)
            .height(38)
            .backgroundColor('#E9ECEF')
            .fontColor(TEXT)
            .borderRadius(8)
            .onClick(() => {
              receiveRequests.decide([]);
            })
          Button(`接收 (${this.reqChecked.length})`)
            .layoutWeight(1)
            .height(38)
            .backgroundColor(GREEN)
            .borderRadius(8)
            .enabled(this.reqChecked.length > 0)
            .onClick(() => {
              receiveRequests.decide(this.reqChecked);
            })
        }
        .width('100%')
      }
      .padding(20)
      .width('86%')
      .backgroundColor(CARD)
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0,0,0,0.45)')
  }

  /** 接收进度回调：驱动进度卡片；会话结束时提示 + 发通知 */
  private onReceiveProgress(p: ReceiveProgress): void {
    if (p.active) {
      this.rxActive = true;
      this.rxName = p.fileName;
      this.rxReceived = p.received;
      this.rxTotal = p.total;
      this.rxSpeed = p.speed;
      this.rxDoneFiles = p.doneFiles;
      this.rxTotalFiles = p.totalFiles;
      return;
    }

    // 会话结束
    const doneFiles = p.doneFiles;
    const totalFiles = p.totalFiles;
    const total = p.total;
    this.rxActive = false;
    this.rxSpeed = 0;

    if (totalFiles > 0 && doneFiles >= totalFiles) {
      const text = totalFiles === 1
        ? `已接收 ${this.rxName.length > 0 ? this.rxName : '文件'}（${this.humanSize(total)}）`
        : `已接收 ${totalFiles} 个文件（${this.humanSize(total)}）`;
      Log.i(`接收会话完成：${text}`);
      // 图片/视频：完成时提示一下入口（系统保存弹窗必须由用户点击触发，不能自动弹）
      const mediaHint = (this.albumAuto && p.mediaPaths.length > 0) ? '；点历史里的「相册」可存入相册' : '';
      // 应用内：toast（前台才有意义）
      if (AppState.foreground) {
        this.getUIContext().getPromptAction().showToast({ message: text + mediaHint, duration: 3000 });
      }
      // 系统通知：后台/锁屏时靠它提醒
      notifyService.notify(1001, '接收完成',
        `${text}，可在「历史」里另存到下载`);
      this.sendTip = text;
      if (this.currentTab === 2) {
        this.history = historyService.list();
      }
    }
  }

  /** 按扩展名推断 MIME：给不出类型就不要发起打开（否则系统会弹一个选择框，连自己都列进去） */
  private mimeOf(fileName: string): string {
    const dot = fileName.lastIndexOf('.');
    if (dot < 0) {
      return '';
    }
    const ext = fileName.substring(dot + 1).toLowerCase();
    if (ext === 'jpg' || ext === 'jpeg') {
      return 'image/jpeg';
    }
    if (ext === 'png') {
      return 'image/png';
    }
    if (ext === 'gif') {
      return 'image/gif';
    }
    if (ext === 'webp') {
      return 'image/webp';
    }
    if (ext === 'heic' || ext === 'heif') {
      return 'image/heic';
    }
    if (ext === 'mp4') {
      return 'video/mp4';
    }
    if (ext === 'mov') {
      return 'video/quicktime';
    }
    if (ext === 'mp3') {
      return 'audio/mpeg';
    }
    if (ext === 'm4a') {
      return 'audio/mp4';
    }
    if (ext === 'wav') {
      return 'audio/wav';
    }
    if (ext === 'pdf') {
      return 'application/pdf';
    }
    if (ext === 'txt' || ext === 'md' || ext === 'log') {
      return 'text/plain';
    }
    if (ext === 'doc') {
      return 'application/msword';
    }
    if (ext === 'docx') {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (ext === 'xls') {
      return 'application/vnd.ms-excel';
    }
    if (ext === 'xlsx') {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (ext === 'ppt') {
      return 'application/vnd.ms-powerpoint';
    }
    if (ext === 'pptx') {
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    }
    if (ext === 'zip') {
      return 'application/zip';
    }
    if (ext === 'apk') {
      return 'application/vnd.android.package-archive';
    }
    return '';
  }

  /** 用系统应用打开已接收的文件 */
  private openReceivedFile(path: string): void {
    if (path.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '这条记录来自旧版本，没有保存路径' });
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        this.getUIContext().getPromptAction().showToast({ message: '文件已不存在（可能被清理了）' });
        return;
      }
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '文件已不存在（可能被清理了）' });
      return;
    }
    const slash = path.lastIndexOf('/');
    const name = slash >= 0 ? path.substring(slash + 1) : path;
    const mime = this.mimeOf(name);
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const uri = fileUri.getUriFromPath(path);
    Log.i(`打开文件: ${path} type=${mime.length > 0 ? mime : '(未识别)'} uri=${uri}`);

    // 未知类型也试一次：交给系统按扩展名匹配，比直接拒绝更容易成功
    ctx.startAbility({
      action: 'ohos.want.action.viewData',
      uri: uri,
      type: mime.length > 0 ? mime : 'application/octet-stream',
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    }).catch((e: Error) => {
      Log.w(`打开文件失败: ${String(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '没有可打开该文件的应用，可用「另存」导出' });
    });
  }

  /** 打开接收目录（优先让文件管理直达目录，失败则至少把文件管理拉起来） */
  private openReceiveFolder(): void {
    const dir = fileReceiver.receivedDir();
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    Log.i(`打开接收目录: ${dir}`);
    let uri = '';
    try {
      uri = fileUri.getUriFromPath(dir);
    } catch (e) {
      Log.w(`目录转 uri 失败: ${String(e)}`);
    }
    if (uri.length > 0) {
      ctx.startAbility({
        action: 'ohos.want.action.viewData',
        uri: uri,
        type: 'general.directory',
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      }).then(() => {
        Log.i('文件管理已按目录拉起');
      }).catch((e: Error) => {
        Log.w(`按目录拉起失败: ${String(e)}，改为直接启动文件管理`);
        this.launchFileManager(ctx);
      });
      return;
    }
    this.launchFileManager(ctx);
  }

  private launchFileManager(ctx: common.UIAbilityContext): void {
    ctx.startAbility({
      bundleName: 'com.huawei.hmos.files',
      abilityName: 'EntryAbility'
    }).catch((e: Error) => {
      Log.w(`启动文件管理失败: ${String(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '打不开文件管理，可先「复制路径」' });
    });
  }

  /**
   * 把接收到的图片/视频存入相册。
   *
   * 为什么必须弹一次框：手机端第三方应用既不能直接写公共 Download，也不能免授权写相册
   * （WRITE_IMAGEVIDEO 是受限权限，申请会被直接拒）。官方给的免受限权限方案就是
   * showAssetsCreationDialog：弹一次系统确认，返回的 uri 永久可写，且一次能带一批文件。
   */
  private async saveMediaToAlbum(paths: string[]): Promise<void> {
    if (paths.length === 0) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const helper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const srcUris: string[] = [];
      const configs: photoAccessHelper.PhotoCreationConfig[] = [];
      for (let i = 0; i < paths.length; i++) {
        const p = paths[i];
        const slash = p.lastIndexOf('/');
        const name = slash >= 0 ? p.substring(slash + 1) : p;
        const dot = name.lastIndexOf('.');
        const title = dot > 0 ? name.substring(0, dot) : name;
        const ext = dot > 0 ? name.substring(dot + 1) : 'jpg';
        const cfg: photoAccessHelper.PhotoCreationConfig = {
          title: title,
          fileNameExtension: ext,
          photoType: this.isVideoName(name) ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE,
          subtype: photoAccessHelper.PhotoSubtype.DEFAULT
        };
        configs.push(cfg);
        srcUris.push(fileUri.getUriFromPath(p));
      }
      Log.i(`存相册：请求 ${paths.length} 个媒体文件`);
      // 加超时兜底：这个弹窗偶发不返回（系统侧拦截），不能让 Promise 永久悬着
      const dst = await this.withTimeout(helper.showAssetsCreationDialog(srcUris, configs), 20000);
      if (dst.length === 0) {
        Log.i('存相册：用户取消');
        return;
      }
      let ok = 0;
      for (let i = 0; i < dst.length && i < paths.length; i++) {
        // 相册返回的是 media uri，不能直接当路径用：必须开句柄后按 fd 拷贝
        let srcFd = -1;
        let dstFd = -1;
        try {
          srcFd = fs.openSync(paths[i], fs.OpenMode.READ_ONLY).fd;
          dstFd = fs.openSync(dst[i], fs.OpenMode.WRITE_ONLY).fd;
          fs.copyFileSync(srcFd, dstFd);
          ok++;
        } catch (e) {
          const err = e as BusinessError;
          Log.e(`存相册写入失败 ${err.code} ${err.message}`);
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
      Log.i(`存相册完成 ${ok}/${paths.length}`);
      this.getUIContext().getPromptAction().showToast({ message: `已存入相册 ${ok} 个` });
    } catch (e) {
      const err = e as BusinessError;
      Log.e(`存相册失败 ${err.code} ${err.message}`);
      this.getUIContext().getPromptAction().showToast({ message: `存入相册失败(${err.code})` });
    }
  }

  /** 给系统弹窗加超时：不返回时给出明确结果，而不是静默卡住 */
  private withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
    return new Promise<T>((resolve: (v: T) => void, reject: (e: Error) => void) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          reject(new Error('timeout'));
        }
      }, ms);
      p.then((v: T) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(v);
        }
      }).catch((e: Error) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          reject(e);
        }
      });
    });
  }

  private isMediaName(name: string): boolean {
    const dot = name.lastIndexOf('.');
    if (dot < 0) {
      return false;
    }
    const ext = name.substring(dot + 1).toLowerCase();
    return ext === 'jpg' || ext === 'jpeg' || ext === 'png' || ext === 'gif' || ext === 'webp'
      || ext === 'heic' || ext === 'heif' || ext === 'bmp'
      || ext === 'mp4' || ext === 'mov' || ext === 'mkv' || ext === 'webm' || ext === 'm4v' || ext === '3gp';
  }

  private isVideoName(name: string): boolean {
    const dot = name.lastIndexOf('.');
    if (dot < 0) {
      return false;
    }
    const ext = name.substring(dot + 1).toLowerCase();
    return ext === 'mp4' || ext === 'mov' || ext === 'mkv' || ext === 'webm' || ext === 'm4v' || ext === '3gp';
  }

  /**
   * 把一条记录里的文件另存到用户选的位置。
   * 支持整批：picker 的 newFileNames 可以一次给多个名字，用户只确认一次，
   * 之后逐个写入对应 uri（一批 10 个文件也只弹一次框）。
   */
  private async saveAs(paths: string[]): Promise<void> {
    if (paths.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '这条记录来自旧版本，没有保存路径' });
      return;
    }
    const names: string[] = [];
    for (let i = 0; i < paths.length; i++) {
      const slash = paths[i].lastIndexOf('/');
      names.push(slash >= 0 ? paths[i].substring(slash + 1) : `file_${i}`);
    }
    let uris: string[] = [];
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const p = new picker.DocumentViewPicker(ctx);
      uris = await p.save({ newFileNames: names });
      if (uris.length === 0) {
        return;
      }
      Log.i(`另存目标 uri: ${uris.join(' | ')}`);
    } catch (e) {
      const err = e as BusinessError;
      Log.e(`选择保存位置失败 ${err.code} ${err.message}`);
      this.getUIContext().getPromptAction().showToast({ message: `选择保存位置失败(${err.code})` });
      return;
    }

    let ok = 0;
    let lastErr = '';
    const count = Math.min(uris.length, paths.length);
    for (let i = 0; i < count; i++) {
      const res = await this.copyToUri(paths[i], uris[i]);
      Log.i(`另存结果[${i}] ok=${res.ok} ${res.message}`);
      if (res.ok) {
        ok++;
      } else {
        lastErr = res.message;
      }
    }
    this.getUIContext().getPromptAction().showToast({
      message: ok === paths.length
        ? (paths.length > 1 ? `已保存 ${ok} 个，可在文件管理中查看` : '已保存，可在文件管理中查看')
        : `保存 ${ok}/${paths.length} 失败(${lastErr})`
    });
  }

  /**
   * 把文件写进 picker 返回的目标 URI。
   * picker.save() 已经建好空文件并把临时读写权限授予本应用，所以这里：
   *   1) 先用 uri 打开文件句柄，再用 copyFile(源路径, 目标 fd) 交给原生层拷贝（GB 级也不占内存）；
   *   2) 失败再退回流式 read/write；
   *   3) 两步都失败时把错误码带出来，方便定位是权限还是参数问题。
   */
  private async copyToUri(srcPath: string, dstUri: string): Promise<SaveResult> {
    // 1) open + copyFile(fd)
    let handle: fs.File | null = null;
    try {
      handle = fs.openSync(dstUri, fs.OpenMode.READ_WRITE);
      fs.copyFileSync(srcPath, handle.fd);
      Log.i('另存：copyFile(uri fd) 成功');
      return { ok: true, message: 'ok' };
    } catch (e) {
      const err = e as BusinessError;
      Log.w(`另存：copyFile 失败 ${err.code} ${err.message}，改流式写入`);
    } finally {
      if (handle !== null) {
        try {
          fs.closeSync(handle);
        } catch (e) {
        }
        handle = null;
      }
    }

    // 2) 流式读写
    let srcFd = -1;
    let dstFd = -1;
    try {
      srcFd = fs.openSync(srcPath, fs.OpenMode.READ_ONLY).fd;
      dstFd = fs.openSync(dstUri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC).fd;
      const buf = new ArrayBuffer(64 * 1024);
      let total = 0;
      while (true) {
        const n = fs.readSync(srcFd, buf);
        if (n <= 0) {
          break;
        }
        // 最后一次可能读不满，必须按实际长度写，否则会多写脏数据
        if (n === buf.byteLength) {
          fs.writeSync(dstFd, buf);
        } else {
          fs.writeSync(dstFd, buf.slice(0, n));
        }
        total += n;
      }
      Log.i(`另存：流式写入完成 ${total} 字节`);
      return { ok: true, message: 'ok' };
    } catch (e) {
      const err = e as BusinessError;
      Log.e(`另存：流式写入失败 ${err.code} ${err.message}`);
      return { ok: false, message: `${err.code}` };
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

  /** 复制接收目录路径到剪贴板 */
  private copyDir(): void {
    const dir = fileReceiver.receivedDir();
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, dir);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.getUIContext().getPromptAction().showToast({ message: '路径已复制' });
    } catch (e) {
      Log.w(`复制路径失败: ${String(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '复制失败' });
    }
  }

  /** 把分享进来的文件填到发送页，并切过去让用户选设备 */
  private applyShareFiles(files: ShareFile[]): void {
    if (files.length === 0) {
      return;
    }
    const next: SendFileItem[] = [];
    for (let i = 0; i < this.sendFiles.length; i++) {
      next.push(this.sendFiles[i]);
    }
    for (let i = 0; i < files.length; i++) {
      const item = new SendFileItem();
      item.path = files[i].path;
      item.name = files[i].name;
      item.size = files[i].size;
      item.mime = 'application/octet-stream';
      next.push(item);
    }
    this.sendFiles = next;
    this.currentTab = 1;
    this.sendTip = `已从分享添加 ${files.length} 个文件，请选择设备后发送`;
    Log.i(`分享文件已填入发送页，共 ${next.length} 个待发`);
  }

  private refreshLocal(): void {
    const s: Settings = settingsService.value;
    this.alias = s.alias;
    this.port = s.port;
    this.protocolText = s.https ? 'https' : 'http';
    this.fingerprint = settingsService.effectiveFingerprint();
    this.httpsOn = s.https;
    this.pin = s.pin;
    this.autoAccept = s.autoAccept;
    this.albumAuto = s.albumAuto;
    this.serverState = httpServer.isRunning() ? (s.https ? 'HTTPS 服务运行中' : 'HTTP 服务运行中') : '服务未启动';
  }

  @Builder
  SectionTitle(title: string, desc: string) {
    Column({ space: 4 }) {
      Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(TEXT)
      Text(desc).fontSize(12).fontColor(SUB)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  LocalCard() {
    Column({ space: 12 }) {
      Row() {
        Text(this.alias).fontSize(17).fontWeight(FontWeight.Medium).fontColor(TEXT)
        Blank()
        Text(this.protocolText === 'https' ? '加密' : '明文')
          .fontSize(11)
          .fontColor(this.protocolText === 'https' ? GREEN : SUB)
          .backgroundColor(this.protocolText === 'https' ? '#E8F6EE' : '#F1F2F4')
          .borderRadius(8)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      }
      .width('100%')

      Text(`端口 ${this.port} · ${this.serverState}`)
        .fontSize(12).fontColor(SUB).width('100%')

      Text(`指纹 ${this.fingerprint.length > 16 ? this.fingerprint.substring(0, 16) + '…' : this.fingerprint}`)
        .fontSize(11).fontColor(SUB).width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(CARD)
    .borderRadius(12)
    .border({ width: 1, color: LINE })
    .width('100%')
  }

  @Builder
  DeviceRow(item: DeviceItem) {
    Row({ space: 12 }) {
      Stack() {
        Text(item.alias.length > 0 ? item.alias.substring(0, 1) : '?')
          .fontSize(16).fontColor(Color.White).fontWeight(FontWeight.Medium)
      }
      .width(40).height(40).borderRadius(10).backgroundColor(GREEN)

      Column({ space: 4 }) {
        Text(item.alias).fontSize(14).fontWeight(FontWeight.Medium).fontColor(TEXT)
        Text(`${item.ip} · ${item.platformLabel()} · ${item.protocol}`)
          .fontSize(11).fontColor(SUB).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('在线').fontSize(11).fontColor(GREEN)
    }
    .padding(12)
    .backgroundColor(CARD)
    .borderRadius(12)
    .border({ width: 1, color: LINE })
    .width('100%')
  }

  @Builder
  EmptyDevices() {
    Column({ space: 8 }) {
      Text('正在搜索附近设备…').fontSize(14).fontWeight(FontWeight.Medium).fontColor(TEXT)
      Text('确保对方设备已打开快传，并连接同一 Wi-Fi').fontSize(12).fontColor(SUB)

      if (this.scanning) {
        Text(`正在扫描局域网 ${this.scanText}`).fontSize(11).fontColor(SUB).margin({ top: 4 })
      } else {
        Text('一直找不到？点右上角「扫描局域网」').fontSize(12).fontColor(SUB).margin({ top: 6 })
      }
    }
    .width('100%')
    .padding({ top: 32, bottom: 32 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 组播被拦时的兜底：逐个 IP 探测 /info */
  private async doScan(): Promise<void> {
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    this.scanText = '0/254';
    try {
      const found = await subnetScanner.scan((done: number, total: number) => {
        this.scanText = `${done}/${total}`;
      });
      this.devices = deviceRegistry.list();
      if (found > 0) {
        this.sendTip = `扫描完成，新发现 ${found} 台设备`;
      } else if (this.devices.length > 0) {
        this.sendTip = `扫描完成，${this.devices.length} 台设备在线`;
      } else {
        this.sendTip = '扫描完成，没有发现设备';
      }
      Log.i(`扫描结束：新发现 ${found} 台`);
    } catch (e) {
      Log.e(`扫描异常: ${String(e)}`);
      this.sendTip = '扫描失败';
    }
    this.scanning = false;
    this.scanText = '';
  }

  @Builder
  ReceiveTab() {
    Scroll() {
      Column({ space: 16 }) {
        this.SectionTitle('本机设备', '其他设备通过这个名字找到你')
        this.LocalCard()

        Column({ space: 4 }) {
          Text('附近设备').fontSize(15).fontWeight(FontWeight.Medium).fontColor(TEXT)
          Text(this.scanning ? `正在扫描局域网 ${this.scanText}` : `已发现 ${this.devices.length} 台`)
            .fontSize(12).fontColor(SUB)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        Column({ space: 8 }) {
          if (this.devices.length === 0) {
            this.EmptyDevices()
          } else {
            ForEach(this.devices, (item: DeviceItem) => {
              this.DeviceRow(item)
            }, (item: DeviceItem) => item.fingerprint)
          }
        }
        .width('100%')
      }
      .padding(16)
      .width('100%')
    }
    .backgroundColor(BG)
    .width('100%')
    .height('100%')
  }

  @Builder
  SendTab() {
    Column({ space: 12 }) {
      this.SectionTitle('选择目标设备', '点击切换是否勾选（可多选，群发给所有勾选设备）')
      if (this.devices.length === 0) {
        this.EmptyDevices()
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.devices, (item: DeviceItem) => {
            Text(item.alias)
              .fontSize(13)
              .fontColor(this.isTargetSelected(item) ? Color.White : TEXT)
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .backgroundColor(this.isTargetSelected(item) ? GREEN : CARD)
              .borderRadius(16)
              .border({ width: 1, color: this.isTargetSelected(item) ? GREEN : LINE })
              .margin({ right: 8, bottom: 8 })
              .onClick(() => {
                this.toggleTarget(item);
              })
          }, (item: DeviceItem) => item.fingerprint)
        }
        .width('100%')
      }

      Row({ space: 8 }) {
        Button('添加文件')
          .height(36)
          .layoutWeight(1)
          .backgroundColor(GREEN)
          .borderRadius(8)
          .enabled(!this.sending)
          .onClick(() => {
            this.pickFiles();
          })
        Button('清空')
          .height(36)
          .width(72)
          .backgroundColor('#E9ECEF')
          .fontColor(TEXT)
          .borderRadius(8)
          .enabled(!this.sending && this.sendFiles.length > 0)
          .onClick(() => {
            this.sendFiles = [];
          })
      }
      .width('100%')

      if (this.sendFiles.length === 0) {
        Text('还没有选择文件').fontSize(12).fontColor(SUB).width('100%')
      } else {
        Column({ space: 8 }) {
          ForEach(this.sendFiles, (f: SendFileItem, idx: number) => {
            Row() {
              Column({ space: 2 }) {
                Text(f.name).fontSize(13).fontColor(TEXT).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.humanSize(f.size)).fontSize(11).fontColor(SUB)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text('移除')
                .fontSize(12).fontColor(SUB)
                .enabled(!this.sending)
                .onClick(() => {
                  const next: SendFileItem[] = [];
                  for (let i = 0; i < this.sendFiles.length; i++) {
                    if (i !== idx) {
                      next.push(this.sendFiles[i]);
                    }
                  }
                  this.sendFiles = next;
                })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
          }, (f: SendFileItem, idx: number) => `${f.path}_${idx}`)
        }
        .padding(12)
        .backgroundColor(CARD)
        .borderRadius(12)
        .border({ width: 1, color: LINE })
        .width('100%')
      }

      Column({ space: 6 }) {
        Text('接收方 PIN（对方设置了才需要填）').fontSize(12).fontColor(SUB)
        TextInput({ text: this.pinInput, placeholder: '留空表示对方未启用 PIN' })
          .height(36)
          .backgroundColor('#F7F8FA')
          .borderRadius(8)
          .onChange((v: string) => {
            this.pinInput = v;
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      if (this.sending) {
        Column({ space: 6 }) {
          Text(`正在发送：${this.currentFile}`).fontSize(12).fontColor(TEXT).width('100%')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Progress({
            value: this.totalBytes > 0 ? (this.sentBytes / this.totalBytes) * 100 : 0,
            total: 100,
            type: ProgressType.Linear
          })
            .width('100%')
            .color(GREEN)
          Text(`${this.humanSize(this.sentBytes)} / ${this.humanSize(this.totalBytes)}`)
            .fontSize(11).fontColor(SUB).width('100%')
        }
        .padding(12)
        .backgroundColor(CARD)
        .borderRadius(12)
        .border({ width: 1, color: LINE })
        .width('100%')
      }

      if (this.sendTip.length > 0) {
        Text(this.sendTip).fontSize(12).fontColor(SUB).width('100%')
      }

      Button(this.sending ? '发送中…' : '发送')
        .width('100%')
        .height(40)
        .backgroundColor(GREEN)
        .borderRadius(10)
        .enabled(!this.sending && this.sendFiles.length > 0 && this.selectedTargets.length > 0)
        .onClick(() => {
          this.doSend();
        })
    }
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(BG)
    .width('100%')
    .height('100%')
  }

  private isTargetSelected(item: DeviceItem): boolean {
    return this.selectedTargets.indexOf(item.fingerprint) >= 0;
  }

  private toggleTarget(item: DeviceItem): void {
    const next: string[] = [];
    let removed = false;
    for (let i = 0; i < this.selectedTargets.length; i++) {
      if (this.selectedTargets[i] === item.fingerprint) {
        removed = true;
      } else {
        next.push(this.selectedTargets[i]);
      }
    }
    if (!removed) {
      next.push(item.fingerprint);
    }
    this.selectedTargets = next;
  }

  /** 打开系统文件选择器，把选中的文件加进待发送列表 */
  private async pickFiles(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const p = new picker.DocumentViewPicker(ctx);
      const uris = await p.select({ maxSelectNumber: 20 });
      const added: SendFileItem[] = [];
      for (let i = 0; i < this.sendFiles.length; i++) {
        added.push(this.sendFiles[i]);
      }
      for (let i = 0; i < uris.length; i++) {
        const uri = uris[i];
        const item = new SendFileItem();
        item.path = uri;
        const slash = uri.lastIndexOf('/');
        const raw = slash >= 0 ? uri.substring(slash + 1) : uri;
        item.name = decodeURIComponent(raw);
        try {
          const f = fs.openSync(uri, fs.OpenMode.READ_ONLY);
          const st = fs.statSync(f.fd);
          item.size = st.size;
          fs.closeSync(f.fd);
        } catch (e) {
          Log.w(`读取文件信息失败 ${uri}: ${JSON.stringify(e)}`);
          item.size = 0;
        }
        item.mime = 'application/octet-stream';
        added.push(item);
      }
      this.sendFiles = added;
      this.sendTip = `已选择 ${added.length} 个文件`;
    } catch (e) {
      Log.e(`选择文件失败: ${JSON.stringify(e)}`);
      this.sendTip = '选择文件失败';
    }
  }

  /** 逐个目标发送（群发） */
  private async doSend(): Promise<void> {
    if (this.sending) {
      return;
    }
    this.sending = true;
    this.sendTip = '';
    const targets: DeviceItem[] = [];
    for (let i = 0; i < this.devices.length; i++) {
      if (this.isTargetSelected(this.devices[i])) {
        targets.push(this.devices[i]);
      }
    }

    let total = 0;
    for (let i = 0; i < this.sendFiles.length; i++) {
      total += this.sendFiles[i].size;
    }
    Log.i(`开始发送：目标 ${targets.length} 台，文件 ${this.sendFiles.length} 个，共 ${total} 字节`);
    this.totalBytes = total * targets.length;
    this.sentBytes = 0;

    let okCount = 0;
    for (let ti = 0; ti < targets.length; ti++) {
      const t = targets[ti];
      const base = this.sentBytes;
      const result: SendResult = await sendClient.sendFiles(
        t, this.sendFiles, this.pinInput,
        (sent: number, _total: number, current: string) => {
          this.sentBytes = base + sent;
          this.currentFile = current;
        }
      );
      if (result === SendResult.Success) {
        okCount++;
      } else if (result === SendResult.PinRequired) {
        this.sendTip = `「${t.alias}」需要 PIN 码，请输入后重试`;
      } else if (result === SendResult.Declined) {
        this.sendTip = `「${t.alias}」拒绝了接收`;
      } else {
        this.sendTip = `发送到「${t.alias}」失败`;
      }
    }

    this.sending = false;
    this.currentFile = '';
    if (okCount === targets.length && targets.length > 0) {
      this.sendTip = `已发送到 ${okCount} 台设备`;
      this.sendFiles = [];
      this.sentBytes = 0;
      this.totalBytes = 0;
    }
  }

  private humanSize(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    if (bytes < 1024 * 1024 * 1024) {
      return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    }
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }

  @Builder
  HistoryTab() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text('传输历史').fontSize(15).fontWeight(FontWeight.Medium).fontColor(TEXT)
          Text(`${this.history.length} 条记录`).fontSize(12).fontColor(SUB)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.history.length > 0) {
          Text('清空')
            .fontSize(12).fontColor(SUB)
            .onClick(() => {
              historyService.clear();
              this.history = historyService.list();
            })
        }
      }
      .width('100%')

      if (this.history.length === 0) {
        Column({ space: 8 }) {
          Text('暂无传输记录').fontSize(14).fontWeight(FontWeight.Medium).fontColor(TEXT)
          Text('收发文件完成后会自动记录在这里').fontSize(12).fontColor(SUB)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.history, (rec: HistoryRecord) => {
            ListItem() {
              Column({ space: 6 }) {
                Row() {
                  Text(rec.direction === 'send' ? '发送' : '接收')
                    .fontSize(11)
                    .fontColor(Color.White)
                    .backgroundColor(rec.direction === 'send' ? GREEN : '#3B82F6')
                    .borderRadius(6)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  Text(rec.peerAlias.length > 0 ? rec.peerAlias : '未知设备')
                    .fontSize(13).fontColor(TEXT).margin({ left: 8 })
                  Blank()
                  Text(this.humanSize(rec.totalSize)).fontSize(12).fontColor(SUB)
                }
                .width('100%')

                Text(this.summaryOf(rec))
                  .fontSize(11).fontColor(SUB).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')

                Row() {
                  Text(this.timeOf(rec.timestamp)).fontSize(11).fontColor(SUB)
                  Blank()
                  if (rec.direction === 'receive' && this.firstPath(rec).length > 0) {
                    if (this.mediaPathsOf(rec).length > 0) {
                      Text('相册')
                        .fontSize(11)
                        .fontColor('#7C3AED')
                        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                        .borderRadius(10)
                        .border({ width: 1, color: '#7C3AED' })
                        .margin({ right: 8 })
                        .onClick(() => {
                          this.saveMediaToAlbum(this.mediaPathsOf(rec));
                        })
                    }
                    Text('另存')
                      .fontSize(11)
                      .fontColor(SUB)
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .borderRadius(10)
                      .border({ width: 1, color: LINE })
                      .margin({ right: 8 })
                      .onClick(() => {
                        this.saveAs(this.pathsOf(rec));
                      })
                    Text('打开')
                      .fontSize(11)
                      .fontColor(GREEN)
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .borderRadius(10)
                      .border({ width: 1, color: GREEN })
                  }
                }
                .width('100%')
              }
              .padding(12)
              .backgroundColor(CARD)
              .borderRadius(12)
              .border({ width: 1, color: LINE })
              .width('100%')
              .onClick(() => {
                if (rec.direction === 'receive') {
                  this.openReceivedFile(this.firstPath(rec));
                }
              })
            }
          }, (rec: HistoryRecord) => rec.id)
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(BG)
    .width('100%')
    .height('100%')
  }

  /** 历史记录里第一个文件的路径（接收记录才有） */
  private firstPath(rec: HistoryRecord): string {
    for (let i = 0; i < rec.files.length; i++) {
      const f = rec.files[i];
      if (f.path !== undefined && f.path.length > 0) {
        return f.path;
      }
    }
    return '';
  }

  /** 记录里的图片/视频路径（仅这些能进相册） */
  private mediaPathsOf(rec: HistoryRecord): string[] {
    const out: string[] = [];
    for (let i = 0; i < rec.files.length; i++) {
      const f = rec.files[i];
      if (f.path !== undefined && f.path.length > 0 && this.isMediaName(f.name)) {
        out.push(f.path);
      }
    }
    return out;
  }

  /** 记录里所有带路径的文件（旧版本记录没有 path，会被跳过） */
  private pathsOf(rec: HistoryRecord): string[] {
    const out: string[] = [];
    for (let i = 0; i < rec.files.length; i++) {
      const f = rec.files[i];
      if (f.path !== undefined && f.path.length > 0) {
        out.push(f.path);
      }
    }
    return out;
  }

  private summaryOf(rec: HistoryRecord): string {
    if (rec.files.length === 0) {
      return '';
    }
    if (rec.files.length === 1) {
      return rec.files[0].name;
    }
    return `${rec.files[0].name} 等 ${rec.files.length} 个文件`;
  }

  private timeOf(ts: number): string {
    const d = new Date(ts);
    const two = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getMonth() + 1}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`;
  }

  @Builder
  SettingRow(label: string, hint: string) {
    Column({ space: 4 }) {
      Text(label).fontSize(14).fontColor(TEXT)
      Text(hint).fontSize(11).fontColor(SUB)
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  @Builder
  SettingsTab() {
    Scroll() {
      Column({ space: 16 }) {
        this.SectionTitle('设备身份', '对方看到的设备名')

        Column({ space: 8 }) {
          Text('本机显示名').fontSize(13).fontColor(TEXT)
          TextInput({ text: this.alias, placeholder: '例如：我的手机' })
            .onChange((v: string) => {
              this.alias = v;
            })
            .backgroundColor('#F7F8FA')
            .borderRadius(8)
        }
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(12)
        .border({ width: 1, color: LINE })
        .width('100%')

        this.SectionTitle('接收目录', fileReceiver.isPublicDir()
          ? '文件直接存到系统「下载」，可在文件管理中查看'
          : '「下载/文档」是受限权限，系统默认不授权，文件先落应用沙箱')
        Column({ space: 8 }) {
          Text(fileReceiver.receivedDir())
            .fontSize(11)
            .fontColor(SUB)
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(fileReceiver.isPublicDir()
            ? '在「文件管理 → 我的手机 → Download → 快传」中可以看到这些文件。'
            : '要放到「下载」：历史记录里点「另存」（多文件也只弹一次框），选择器默认停在 Download，大文件走原生拷贝。图片/视频建议开启下面的「存入相册」。')
            .fontSize(11)
            .fontColor(SUB)
            .width('100%')
          Row({ space: 8 }) {
            Blank()
            Text('打开文件夹')
              .fontSize(12)
              .fontColor(SUB)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(12)
              .border({ width: 1, color: LINE })
              .onClick(() => {
                this.openReceiveFolder();
              })
            Text('复制路径')
              .fontSize(12)
              .fontColor(GREEN)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(12)
              .border({ width: 1, color: GREEN })
              .onClick(() => {
                this.copyDir();
              })
          }
          .width('100%')
        }
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(12)
        .border({ width: 1, color: LINE })
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        this.SectionTitle('相册', '图片/视频可以存进系统相册，任何应用都能看到')
        Column({ space: 10 }) {
          Row() {
            this.SettingRow('接收后提示存入相册', '系统要求由用户点确认，不能全自动；开启后完成时会提示入口，在历史里点「相册」一次入库')
            Toggle({ type: ToggleType.Switch, isOn: this.albumAuto })
              .onChange((on: boolean) => {
                this.albumAuto = on;
              })
          }
          .width('100%')
        }
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(12)
        .border({ width: 1, color: LINE })
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        this.SectionTitle('连接与安全', '改完即时生效')

        Column({ space: 16 }) {
          Row() {
            this.SettingRow('使用 HTTPS', '默认开启（原生 TLS 实现）。关闭后以明文传输，仅用于与不支持 https 的设备互通')
            Toggle({ type: ToggleType.Switch, isOn: this.httpsOn })
              .onChange((on: boolean) => {
                this.httpsOn = on;
              })
          }
          .width('100%')

          Row() {
            this.SettingRow('自动接收', '开启后不再逐次询问，直接接收全部文件')
            Toggle({ type: ToggleType.Switch, isOn: this.autoAccept })
              .onChange((on: boolean) => {
                this.autoAccept = on;
              })
          }
          .width('100%')

          Column({ space: 8 }) {
            Text('接收 PIN 码').fontSize(13).fontColor(TEXT)
            TextInput({ text: this.pin, placeholder: '留空 = 不启用' })
              .type(InputType.Password)
              .onChange((v: string) => {
                this.pin = v;
              })
              .backgroundColor('#F7F8FA')
              .borderRadius(8)
            Text('设置后，对方发送前必须输入相同 PIN').fontSize(11).fontColor(SUB)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
        }
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(12)
        .border({ width: 1, color: LINE })
        .width('100%')

        Button('保存并重启服务')
          .width('100%')
          .height(40)
          .backgroundColor(GREEN)
          .borderRadius(10)
          .onClick(() => {
            this.applySettings();
          })

        Text(`当前服务：${this.serverState}`).fontSize(11).fontColor(SUB).width('100%')
        Text('快传鸿蒙版 v1.0.0 · 协议 LocalSend v2.2').fontSize(11).fontColor(SUB).width('100%')
      }
      .padding(16)
      .width('100%')
    }
    .backgroundColor(BG)
    .width('100%')
    .height('100%')
  }

  /** 保存设置并重启服务（HTTPS 开关、端口变更必须重启监听才生效） */
  private applySettings(): void {
    settingsService.save((s: Settings) => {
      s.alias = this.alias;
      s.https = this.httpsOn;
      s.pin = this.pin;
      s.autoAccept = this.autoAccept;
      s.albumAuto = this.albumAuto;
    });
    this.refreshLocal();

    httpServer.stop().then(() => {
      httpServer.start().then(() => {
        this.refreshLocal();
        Log.i('服务已按新设置重启');
      });
    });
    discoveryService.announce();
  }

  build() {
    Stack() {
      Column() {
      Row({ space: 8 }) {
        Text('快传').fontSize(22).fontWeight(FontWeight.Medium).fontColor(TEXT)
        Blank()
        // 扫描入口放在 Scroll 之外：实测放在 Scroll 内的 Text/Button 点击不响应，
        // 这里固定在标题栏，任何页面状态下都能点。
        if (this.currentTab === 0) {
          Button(this.scanning ? '扫描中…' : '扫描局域网')
            .fontSize(11)
            .fontColor(this.scanning ? SUB : GREEN)
            .height(28)
            .padding({ left: 12, right: 12 })
            .backgroundColor(Color.Transparent)
            .borderRadius(14)
            .border({ width: 1, color: this.scanning ? LINE : GREEN })
            .enabled(!this.scanning)
            .onClick(() => {
              Log.i('点击「扫描局域网」');
              this.doScan();
            })
        }
        Text(this.devices.length > 0 ? `${this.devices.length} 台在线` : '搜索中…')
          .fontSize(12).fontColor(SUB)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
        TabContent() {
          this.ReceiveTab()
        }.tabBar('接收')

        TabContent() {
          this.SendTab()
        }.tabBar('发送')

        TabContent() {
          this.HistoryTab()
        }.tabBar('历史')

        TabContent() {
          this.SettingsTab()
        }.tabBar('设置')
      }
      .onChange((index: number) => {
        this.currentTab = index;
        if (index === 0 || index === 1) {
          this.refreshLocal();
        }
        if (index === 2) {
          this.history = historyService.list();
        }
      })
        .barMode(BarMode.Fixed)
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(BG)

      if (this.rxActive) {
        Column() {
          this.RxProgressCard()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      if (this.hasRequest) {
        this.ReceiveRequestLayer()
      }
    }
    .width('100%')
    .height('100%')
  }
}

/** 接收请求里的文件行 */
class ReqFileRow {
  id: string = '';
  name: string = '';
  size: number = 0;
}
