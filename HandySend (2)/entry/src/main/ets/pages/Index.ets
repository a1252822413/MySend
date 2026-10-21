import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { describeFailure } from '@lsnext/protocol';
import {
  FavoriteRow, FileRow, HistoryRow, LocalSendService, PeerRow, ReceivedRow, ServiceSnapshot
} from '../service/LocalSendService';

/** One controller for the whole app: the page is rebuilt on rotation and must not restart it. */
const service: LocalSendService = new LocalSendService();

/** How many files one pick may carry; the picker dialogs enforce the same ceiling. */
const MAX_PICK: number = 20;

function formatBytes(bytes: number): string {
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

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** Compact local timestamp for staged text files: 1012-1530. */
function stampName(): string {
  const now: Date = new Date();
  return `${pad2(now.getMonth() + 1)}${pad2(now.getDate())}-`
    + `${pad2(now.getHours())}${pad2(now.getMinutes())}${pad2(now.getSeconds())}`;
}

/** The history page's `MM-dd HH:mm`, matching what the official list shows. */
function timeText(ms: number): string {
  const at: Date = new Date(ms);
  return `${pad2(at.getMonth() + 1)}-${pad2(at.getDate())} `
    + `${pad2(at.getHours())}:${pad2(at.getMinutes())}`;
}

/** Last octet of an IPv4 address — the official '#229' style short id. */
function visualIdOf(ip: string): string {
  const dot: number = ip.lastIndexOf('.');
  return dot < 0 ? ip : ip.substring(dot + 1);
}

function sendStatusLabel(status: string): string {
  if (status === 'hashing') {
    return '计算校验';
  }
  if (status === 'sending') {
    return '上传中';
  }
  if (status === 'success') {
    return '完成';
  }
  if (status === 'skipped') {
    return '对方未选';
  }
  if (status === 'failed') {
    return '失败';
  }
  if (status === 'canceled') {
    return '已取消';
  }
  if (status === 'pending') {
    return '排队';
  }
  return '准备中';
}

/** Task-level states share the row vocabulary; only the waiting and uploading phases differ. */
function taskStatusLabel(status: string): string {
  if (status === 'waiting') {
    return '等待对方确认';
  }
  if (status === 'uploading') {
    return '上传中';
  }
  return sendStatusLabel(status);
}

/** The web rows count bytes out, so they need their own three words. */
function webStatusLabel(status: string): string {
  if (status === 'done') {
    return '已下载';
  }
  if (status === 'partial') {
    return '下载中';
  }
  return '未下载';
}

/** Four digits, which is the shape the official clients hand out for web transfers. */
function randomPin(): string {
  return `${Math.floor(1000 + Math.random() * 9000)}`;
}

const RANDOM_ADJECTIVES: string[] = ['快乐的', '安静的', '勇敢的', '灵巧的', '明亮的', '悠闲的'];
const RANDOM_NOUNS: string[] = ['海豚', '水獭', '翠鸟', '狐狸', '云朵', '小舟'];

function randomAlias(): string {
  const adjective: string = RANDOM_ADJECTIVES[Math.floor(Math.random() * RANDOM_ADJECTIVES.length)];
  const noun: string = RANDOM_NOUNS[Math.floor(Math.random() * RANDOM_NOUNS.length)];
  return `${adjective}${noun}`;
}

function iconOfDevice(deviceType: string): Resource {
  if (deviceType === 'mobile') {
    return $r('app.media.ic_phone');
  }
  if (deviceType === 'web') {
    return $r('app.media.ic_globe');
  }
  return $r('app.media.ic_computer');
}

function iconOfFileType(fileType: string): Resource {
  if (fileType.startsWith('image/') || fileType.startsWith('video/')) {
    return $r('app.media.ic_image');
  }
  if (fileType.startsWith('text/')) {
    return $r('app.media.ic_text');
  }
  return $r('app.media.ic_document');
}

/** Picked rows carry no mime type yet, so the name's extension is the only hint. */
function iconOfName(name: string): Resource {
  const dot: number = name.lastIndexOf('.');
  const ext: string = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  if (ext === 'jpg' || ext === 'jpeg' || ext === 'png' || ext === 'gif' || ext === 'webp'
    || ext === 'bmp' || ext === 'heic' || ext === 'mp4' || ext === 'mov' || ext === 'mkv') {
    return $r('app.media.ic_image');
  }
  if (ext === 'txt' || ext === 'md' || ext === 'json' || ext === 'log') {
    return $r('app.media.ic_text');
  }
  return $r('app.media.ic_document');
}

/** The receive page's slowly rotating logo; its own timer keeps the rest of the page still. */
@Component
struct RadarLogo {
  @Prop @Watch('onSpinningChanged') spinning: boolean = false;
  @State angle: number = 0;
  private timerId: number = -1;

  aboutToAppear(): void {
    if (this.spinning) {
      this.start();
    }
  }

  aboutToDisappear(): void {
    this.stop();
  }

  onSpinningChanged(): void {
    if (this.spinning) {
      this.start();
    } else {
      this.stop();
    }
  }

  private start(): void {
    if (this.timerId >= 0) {
      return;
    }
    // One full turn per 15 seconds, the speed the official client uses.
    this.timerId = setInterval((): void => {
      this.angle = (this.angle + 1.2) % 360;
    }, 50);
  }

  private stop(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  build() {
    Column() {
      Image($r('app.media.locallsend_logo'))
        .width(180)
        .height(180)
        .rotate({ angle: this.angle })
        .opacity(this.spinning ? 1 : 0.45)
    }
    .width(200)
    .height(200)
    .justifyContent(FlexAlign.Center)
  }
}

@Entry
@Component
struct Index {
  @State snap: ServiceSnapshot = new ServiceSnapshot();
  /** Everything overlay-shaped shares one slot: a full page or a centered dialog. */
  @State sheet: string = 'none';
  /** The alias the settings field edits; only overwritten when the stored alias itself changes. */
  @State aliasDraft: string = '';
  @State hostDraft: string = '';
  @State pinDraft: string = '';
  @State pinEdit: string = '';
  @State textDraft: string = '';
  @State favName: string = '';
  @State favHost: string = '';
  @State favPort: string = '';
  /** The history entry the actions/info dialogs point at. */
  @State entryId: string = '';
  /** The peer a tap selected; an empty fingerprint means none. */
  @State sendTarget: PeerRow = new PeerRow();
  /** Set when the send flow should end in a browser link rather than a device upload. */
  private pendingShare: boolean = false;
  private lastAlias: string = '';
  /** Current tab; the name avoids clashing with CommonMethod.tabIndex. */
  @State tab: number = 0;

  aboutToAppear(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    service.attach((snapshot: ServiceSnapshot): void => {
      this.snap = snapshot;
      if (snapshot.alias !== this.lastAlias) {
        this.lastAlias = snapshot.alias;
        this.aliasDraft = snapshot.alias;
      }
      // A tap on a device with nothing selected first opens the picker; once files are in,
      // continue into the PIN/confirm step the tap intended.
      if (this.sendTarget.fingerprint.length > 0 && snapshot.picked.length > 0
        && this.sheet !== 'sendConfirm' && this.sheet !== 'pickedEdit') {
        this.sheet = 'sendConfirm';
      }
      if (this.pendingShare && snapshot.picked.length > 0) {
        this.pendingShare = false;
        this.startLinkShare();
      }
    });
    service.open(context).catch((reason: Object): void => {
      service.reportError(`${describeFailure(reason)}`);
    });
  }

  aboutToDisappear(): void {
    // The ability owns the listener slot; the page must not leave a dead one behind.
    service.attach((): void => undefined);
  }

  build() {
    Stack() {
      Column() {
        // Plain if/else, not a Swiper: Swiper caches its children and a cached tab stops
        // re-rendering on snapshot changes (the theme row kept showing a stale label).
        Column() {
          if (this.tab === 0) {
            this.receivePage()
          } else if (this.tab === 1) {
            this.sendPage()
          } else {
            this.settingsPage()
          }
        }
        .width('100%')
        .layoutWeight(1)
        this.navBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg'))

      if (this.snap.hasOffer) {
        this.offerSheet()
      } else if (this.snap.hasWebOffer) {
        this.webOfferSheet()
      } else if (this.sheet !== 'none') {
        this.sheetOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ------------------------------------------------------------------ chrome

  @Builder navBar() {
    Row() {
      this.navItem('接收', $r('app.media.ic_wifi'), 0)
      this.navItem('发送', $r('app.media.ic_send'), 1)
      this.navItem('设置', $r('app.media.ic_settings'), 2)
    }
    .width('100%')
    .height(78)
    .padding({ top: 6, bottom: 12 })
    .backgroundColor($r('app.color.nav_bar'))
    .border({ width: { top: 0.5 }, color: $r('app.color.outline') })
  }

  @Builder navItem(label: string, icon: Resource, index: number) {
    Column({ space: 4 }) {
      Row() {
        Image(icon)
          .width(22)
          .height(22)
          .fillColor(this.tab === index ? $r('app.color.on_soft') : $r('app.color.text_dim'))
      }
      .width(64)
      .height(32)
      .justifyContent(FlexAlign.Center)
      .borderRadius(16)
      .backgroundColor(this.tab === index ? $r('app.color.primary_soft') : Color.Transparent)

      Text(label)
        .fontSize(12)
        .fontWeight(this.tab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.tab === index ? $r('app.color.text') : $r('app.color.text_dim'))
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick((): void => {
      this.tab = index;
    })
  }

  @Builder iconButton(icon: Resource, tint: ResourceColor, action: () => void) {
    // Padding on an Image shrinks the drawn content, so the box needs to be size + 2 * padding.
    Image(icon)
      .width(40)
      .height(40)
      .padding(9)
      .fillColor(tint)
      .onClick(action)
  }

  @Builder overlayHeader(title: string) {
    Row({ space: 6 }) {
      this.iconButton($r('app.media.ic_back'), $r('app.color.text'), (): void => {
        this.closeSheet();
      })
      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(56)
    .padding({ right: 12 })
    .backgroundColor($r('app.color.bg'))
  }

  // ----------------------------------------------------------------- receive

  @Builder receivePage() {
    Scroll() {
      Column() {
        Row({ space: 6 }) {
          Blank()
          this.iconButton($r('app.media.ic_history'), $r('app.color.text_dim'), (): void => {
            this.sheet = 'history';
          })
          this.iconButton($r('app.media.ic_info'), $r('app.color.text_dim'), (): void => {
            this.sheet = 'info';
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })

        Column() {
          RadarLogo({
            spinning: this.snap.running && this.snap.animations && this.tab === 0
          })
        }
        .width('100%')
        .height(210)
        .justifyContent(FlexAlign.Center)

        Text(this.snap.alias)
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24 })
          .fontColor($r('app.color.text'))

        Text(this.visualText())
          .fontSize(22)
          .fontColor($r('app.color.text_dim'))
          .margin({ top: 6 })

        Text('自动保存')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_dim'))
          .textAlign(TextAlign.Center)
          .margin({ top: 36, bottom: 8 })

        Row() {
          this.quickSaveSegment()
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)

        Text(this.quickSaveHint())
          .fontSize(11)
          .fontColor($r('app.color.warning_text'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16, top: 6 })
          .visibility(this.quickSaveHint().length > 0 ? Visibility.Visible : Visibility.None)

        Row({ space: 6 }) {
          Image($r('app.media.ic_link'))
            .width(18)
            .height(18)
            .fillColor($r('app.color.primary'))
          Text('通过链接接收')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.primary'))
        }
        .height(38)
        .padding({ left: 18, right: 18 })
        .borderRadius(19)
        .border({ width: 1, color: $r('app.color.primary') })
        .backgroundColor(Color.Transparent)
        .margin({ top: 20 })
        .onClick((): void => {
          this.openWebUpload();
        })

        if (!this.snap.running) {
          Text('接收已停止，可在「设置 - 网络」中开启服务器')
            .fontSize(12)
            .fontColor($r('app.color.text_faint'))
            .margin({ top: 12 })
        }

        this.sessionCard()
        this.finishedCard()
        this.receivedCard()
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder quickSaveSegment() {
    Row() {
      this.quickSaveCell('关', 'off', true, false)
      Divider().vertical(true).height(20).color($r('app.color.outline'))
      this.quickSaveCell('收藏夹', 'paired', false, false)
      Divider().vertical(true).height(20).color($r('app.color.outline'))
      this.quickSaveCell('开', 'on', false, true)
    }
    .height(38)
    .borderRadius(19)
    .border({ width: 1, color: $r('app.color.outline') })
    .backgroundColor(Color.Transparent)
  }

  @Builder quickSaveCell(label: string, mode: string, isFirst: boolean, isLast: boolean) {
    Text(label)
      .fontSize(14)
      .fontWeight(this.snap.quickSave === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.snap.quickSave === mode ? $r('app.color.on_soft') : $r('app.color.text'))
      .backgroundColor(this.snap.quickSave === mode ? $r('app.color.primary_soft') : Color.Transparent)
      .height('100%')
      .padding({ left: 18, right: 18 })
      .borderRadius({
        topLeft: isFirst ? 19 : 0,
        bottomLeft: isFirst ? 19 : 0,
        topRight: isLast ? 19 : 0,
        bottomRight: isLast ? 19 : 0
      })
      .onClick((): void => {
        this.run(service.setQuickSave(mode));
      })
  }

  @Builder sessionCard() {
    if (this.snap.hasSession) {
      Column({ space: 8 }) {
        Row() {
          Text(`正在接收 · ${this.snap.sessionSender}`)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text'))
            .layoutWeight(1)
          Button('停止')
            .fontSize(13)
            .height(32)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.danger'))
            .onClick((): void => {
              service.stopSession();
            })
        }
        .width('100%')

        ForEach(this.snap.sessionFiles, (file: FileRow) => {
          Column({ space: 2 }) {
            Row() {
              Text(file.name)
                .fontSize(13)
                .fontColor($r('app.color.text'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${formatBytes(file.received)} / ${formatBytes(file.size)}`)
                .fontSize(11)
                .fontColor($r('app.color.text_dim'))
            }
            .width('100%')
            Progress({ value: file.size === 0 ? 100 : file.received * 100 / file.size })
              .color($r('app.color.primary'))
              .width('100%')
          }
          .width('100%')
        }, (file: FileRow) => `${file.id}:${file.status}:${file.received}`)
      }
      .width('100%')
      .padding(14)
      .borderRadius(16)
      .backgroundColor($r('app.color.card'))
      .margin({ left: 16, right: 16, top: 16 })
    }
  }

  @Builder finishedCard() {
    if (this.snap.hasFinished) {
      Column({ space: 8 }) {
        Row() {
          Text(`已完成 · ${this.snap.finishedSender}`)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text'))
            .layoutWeight(1)
          Button('完成')
            .fontSize(13)
            .height(32)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              service.dismissFinished();
            })
        }
        .width('100%')

        ForEach(this.snap.finishedFiles, (file: FileRow) => {
          Row() {
            Text(file.name)
              .fontSize(13)
              .fontColor($r('app.color.text'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(formatBytes(file.size))
              .fontSize(11)
              .fontColor($r('app.color.text_dim'))
          }
          .width('100%')
        }, (file: FileRow) => `${file.id}:${file.status}`)
      }
      .width('100%')
      .padding(14)
      .borderRadius(16)
      .backgroundColor($r('app.color.card'))
      .margin({ left: 16, right: 16, top: 16 })
    }
  }

  /**
   * The last finished receive, with a save button per file: files land in the app's own
   * directory first, and getting them out of it is a user-driven step.
   */
  @Builder receivedCard() {
    if (this.snap.lastReceived.length > 0) {
      Column({ space: 6 }) {
        Text('最近接收')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
        ForEach(this.snap.lastReceived, (file: ReceivedRow) => {
          Row({ space: 8 }) {
            Image(iconOfFileType(file.fileType))
              .width(20)
              .height(20)
              .fillColor($r('app.color.text_dim'))
            Column({ space: 2 }) {
              Text(file.name)
                .fontSize(13)
                .fontColor($r('app.color.text'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(formatBytes(file.size))
                .fontSize(10)
                .fontColor($r('app.color.text_dim'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Button(file.saved ? '已保存' : '保存')
              .fontSize(12)
              .height(30)
              .backgroundColor($r('app.color.primary'))
              .fontColor($r('app.color.on_primary'))
              .enabled(!file.saved && this.snap.savingId === '')
              .onClick((): void => {
                service.saveReceived(file.id);
              })
          }
          .width('100%')
        }, (file: ReceivedRow) => `${file.id}:${file.saved}`)
        Text('「保存」把文件移出应用目录：图片和视频存入相册，其他文件由你选择位置')
          .fontSize(10)
          .fontColor($r('app.color.text_faint'))
      }
      .width('100%')
      .padding(14)
      .borderRadius(16)
      .backgroundColor($r('app.color.card'))
      .margin({ left: 16, right: 16, top: 16 })
      .alignItems(HorizontalAlign.Start)
    }
  }

  private visualText(): string {
    const ips: string[] = this.snap.localIps;
    if (!this.snap.running || ips.length === 0) {
      return '离线';
    }
    return `#${visualIdOf(ips[0])}`;
  }

  private quickSaveHint(): string {
    if (this.snap.quickSave === 'on') {
      return '已开启自动保存：将自动接受所有文件请求';
    }
    if (this.snap.quickSave === 'paired') {
      return '将自动接受收藏夹设备的文件请求';
    }
    return '';
  }

  // -------------------------------------------------------------------- send

  @Builder sendPage() {
    Scroll() {
      Column() {
        if (this.snap.picked.length === 0) {
          Text('选择')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 16 })

          Row({ space: 8 }) {
            this.bigButton('文件', $r('app.media.ic_document'), (): void => {
              this.beginPick();
              this.pickDocuments();
            })
            this.bigButton('媒体', $r('app.media.ic_image'), (): void => {
              this.beginPick();
              this.pickPhotos();
            })
            this.bigButton('剪贴板', $r('app.media.ic_clipboard'), (): void => {
              this.beginPick();
              this.pickClipboard();
            })
            this.bigButton('文本', $r('app.media.ic_text'), (): void => {
              this.beginPick();
              this.textDraft = '';
              this.sheet = 'text';
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10 })
        } else {
          this.pickedCard()
        }

        this.sendProgressCard()

        Row() {
          Text('附近的设备')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text'))
            .layoutWeight(1)
          this.iconButton($r('app.media.ic_refresh'), $r('app.color.text_dim'), (): void => {
            this.run(service.refresh());
          })
          this.iconButton($r('app.media.ic_target'), $r('app.color.text_dim'), (): void => {
            this.hostDraft = '';
            this.sheet = 'address';
          })
          this.iconButton($r('app.media.ic_heart'), $r('app.color.text_dim'), (): void => {
            this.sheet = 'favorites';
          })
          this.iconButton($r('app.media.ic_settings'), $r('app.color.text_dim'), (): void => {
            this.sheet = 'sendMode';
          })
        }
        .width('100%')
        .padding({ left: 16, right: 8, top: 20, bottom: 6 })

        if (this.snap.peers.length === 0) {
          this.devicePlaceholder()
          this.devicePlaceholder()
        } else {
          ForEach(this.snap.peers, (peer: PeerRow) => {
            this.deviceCard(peer)
          }, (peer: PeerRow) => `${peer.fingerprint}:${peer.name}:${peer.host}:${peer.port}:${peer.model}:${peer.deviceType}:${service.isFavorite(peer.fingerprint)}`)
        }

        Row() {
          Text('故障排除')
            .fontSize(15)
            .fontColor($r('app.color.primary'))
            .onClick((): void => {
              this.sheet = 'troubleshoot';
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding(14)

        Text('请确保目标连接到同一个 Wi-Fi 网络。')
          .fontSize(12)
          .fontColor($r('app.color.text_faint'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16, bottom: 24 })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder bigButton(label: string, icon: Resource, action: () => void) {
    Column({ space: 6 }) {
      Image(icon)
        .width(26)
        .height(26)
        .fillColor($r('app.color.primary'))
      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text'))
    }
    .layoutWeight(1)
    .height(68)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor($r('app.color.card'))
    .border({ width: 0.5, color: $r('app.color.outline') })
    .onClick(action)
  }

  @Builder pickedCard() {
    Column({ space: 8 }) {
      Row() {
        Text('选择')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
          .layoutWeight(1)
        this.iconButton($r('app.media.ic_close'), $r('app.color.text_dim'), (): void => {
          service.clearPicked();
        })
      }
      .width('100%')

      Text(`文件：${this.snap.picked.length}`)
        .fontSize(14)
        .fontColor($r('app.color.text_dim'))
        .width('100%')
      Text(`大小：${formatBytes(this.pickedSize())}`)
        .fontSize(14)
        .fontColor($r('app.color.text_dim'))
        .width('100%')

      List({ space: 8 }) {
        ForEach(this.snap.picked, (file: FileRow) => {
          ListItem() {
            Row({ space: 6 }) {
              Image(iconOfName(file.name))
                .width(16)
                .height(16)
                .fillColor($r('app.color.primary'))
              Text(file.name)
                .fontSize(12)
                .fontColor($r('app.color.text'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 120 })
            }
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .borderRadius(10)
            .backgroundColor($r('app.color.input_fill'))
          }
        }, (file: FileRow) => `${file.id}:${file.size}`)
      }
      .listDirection(Axis.Horizontal)
      .height(36)
      .width('100%')
      .scrollBar(BarState.Off)

      Row({ space: 8 }) {
        Blank()
        Button('编辑')
          .fontSize(13)
          .height(34)
          .backgroundColor($r('app.color.input_fill'))
          .fontColor($r('app.color.text'))
          .onClick((): void => {
            this.sheet = 'pickedEdit';
          })
        Button('添加')
          .fontSize(13)
          .height(34)
          .backgroundColor($r('app.color.primary'))
          .fontColor($r('app.color.on_primary'))
          .onClick((): void => {
            this.beginPick();
            this.sheet = 'pickChooser';
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('app.color.card'))
    .margin({ left: 16, right: 16, top: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder deviceCard(peer: PeerRow) {
    Row({ space: 12 }) {
      Column() {
        Image(iconOfDevice(peer.deviceType))
          .width(24)
          .height(24)
          .fillColor($r('app.color.primary'))
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .borderRadius(22)
      .backgroundColor($r('app.color.primary_soft'))

      Column({ space: 2 }) {
        Text(this.peerName(peer))
          .fontSize(16)
          .fontColor($r('app.color.text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.peerSubtitle(peer))
          .fontSize(12)
          .fontColor($r('app.color.text_dim'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Image(service.isFavorite(peer.fingerprint)
        ? $r('app.media.ic_heart') : $r('app.media.ic_heart_outline'))
        .width(30)
        .height(30)
        .padding(4)
        .fillColor(service.isFavorite(peer.fingerprint)
          ? $r('app.color.primary') : $r('app.color.text_faint'))
        .onClick((): void => {
          this.run(service.toggleFavorite(peer));
        })
    }
    .width('100%')
    .padding(12)
    .borderRadius(16)
    .backgroundColor($r('app.color.card'))
    .margin({ left: 16, right: 16, bottom: 10 })
    .onClick((): void => {
      this.onTapDevice(peer);
    })
  }

  @Builder devicePlaceholder() {
    Row({ space: 16 }) {
      Column() {
        Image($r('app.media.ic_phone'))
          .width(26)
          .height(26)
          .fillColor($r('app.color.text_dim'))
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .borderRadius(22)
      .backgroundColor($r('app.color.input_fill'))

      Column({ space: 8 }) {
        Row()
          .width(110)
          .height(14)
          .borderRadius(7)
          .backgroundColor($r('app.color.outline'))
        Row()
          .width(70)
          .height(12)
          .borderRadius(6)
          .backgroundColor($r('app.color.outline'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.card'))
    .opacity(0.35)
    .margin({ left: 16, right: 16, bottom: 12 })
  }

  @Builder sendProgressCard() {
    if (this.snap.sendFiles.length > 0) {
      Column({ space: 8 }) {
        Row() {
          Text(this.snap.sendActive ? `正在发送 · ${this.snap.sendPeer}` : '发送结果')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.snap.sendActive) {
            Button('取消')
              .fontSize(13)
              .height(32)
              .backgroundColor($r('app.color.input_fill'))
              .fontColor($r('app.color.danger'))
              .onClick((): void => {
                service.cancelSend();
              })
          }
        }
        .width('100%')

        Row() {
          Text(`进度 ${formatBytes(this.snap.sendSent)} / ${formatBytes(this.snap.sendTotal)}`)
            .fontSize(12)
            .fontColor($r('app.color.text_dim'))
            .layoutWeight(1)
          Text(taskStatusLabel(this.snap.sendState))
            .fontSize(12)
            .fontColor($r('app.color.text_dim'))
        }
        .width('100%')

        Progress({
          value: this.snap.sendTotal === 0 ? 0 : this.snap.sendSent * 100 / this.snap.sendTotal
        })
          .color($r('app.color.primary'))
          .width('100%')

        ForEach(this.snap.sendFiles, (file: FileRow) => {
          Row() {
            Text(file.name)
              .fontSize(12)
              .fontColor($r('app.color.text'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${formatBytes(file.received)} / ${formatBytes(file.size)}`)
              .fontSize(11)
              .fontColor($r('app.color.text_dim'))
            Text(sendStatusLabel(file.status))
              .fontSize(11)
              .fontColor(file.status === 'failed' ? $r('app.color.danger') : $r('app.color.primary'))
              .margin({ left: 8 })
          }
          .width('100%')
        // ForEach only re-renders a row when its key changes, so every value the row draws belongs
        // in the key — a stable id alone leaves the row frozen at whatever it first showed.
        }, (file: FileRow) => `${file.id}:${file.status}:${file.received}`)

        if (this.snap.sendError.length > 0) {
          Text(this.snap.sendError)
            .fontSize(11)
            .fontColor($r('app.color.danger'))
            .width('100%')
        }
      }
      .width('100%')
      .padding(14)
      .borderRadius(16)
      .backgroundColor($r('app.color.card'))
      .margin({ left: 16, right: 16, top: 16 })
    }
  }

  private pickedSize(): number {
    let total: number = 0;
    for (let i = 0; i < this.snap.picked.length; i++) {
      total += this.snap.picked[i].size;
    }
    return total;
  }

  private peerName(peer: PeerRow): string {
    const favs: FavoriteRow[] = this.snap.favorites;
    for (let i = 0; i < favs.length; i++) {
      if (favs[i].fingerprint.length > 0 && favs[i].fingerprint === peer.fingerprint) {
        return favs[i].name;
      }
    }
    return peer.name;
  }

  private peerSubtitle(peer: PeerRow): string {
    const where: string = `${peer.host}:${peer.port}`;
    return peer.model.length > 0 ? `${peer.model} · ${where}` : where;
  }

  // ----------------------------------------------------------------- settings

  @Builder settingsPage() {
    Scroll() {
      Column() {
        Text('设置')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 16, bottom: 8 })

        // 通用
        Column() {
          Text('通用')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
            .width('100%')
            .margin({ bottom: 8 })
          this.settingsValueRow('主题', 'theme', (): void => {
            this.sheet = 'theme';
          })
          this.settingsToggle('动画效果', 'animations', (value: boolean): void => {
            this.run(service.setAnimations(value));
          })
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card'))
        .margin({ left: 16, right: 16, top: 10, bottom: 4 })

        // 接收
        Column() {
          Text('接收')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
            .width('100%')
            .margin({ bottom: 8 })
          this.settingsValueRow('自动保存', 'quickSave', (): void => {
            this.sheet = 'quickSave';
          })
          Row({ space: 4 }) {
            Column({ space: 2 }) {
              Text('需要一个 PIN')
                .fontSize(15)
                .fontColor($r('app.color.text'))
              Text(this.snap.receivePin.length > 0
                ? `当前 PIN：${this.snap.receivePin}` : '未设置')
                .fontSize(12)
                .fontColor(this.snap.receivePin.length > 0
                  ? $r('app.color.warning_text') : $r('app.color.text_dim'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            if (this.snap.receivePin.length > 0) {
              Button('清除')
                .fontSize(13)
                .height(30)
                .borderRadius(8)
                .backgroundColor($r('app.color.input_fill'))
                .fontColor($r('app.color.text'))
                .onClick((): void => {
                  this.run(service.setReceivePin(''));
                })
            }
            Button(this.snap.receivePin.length > 0 ? '修改' : '设置')
              .fontSize(13)
              .height(30)
              .borderRadius(8)
              .backgroundColor($r('app.color.primary'))
              .fontColor($r('app.color.on_primary'))
              .onClick((): void => {
                this.pinEdit = this.snap.receivePin.length > 0 ? this.snap.receivePin : randomPin();
                this.sheet = 'pin';
              })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          this.settingsToggle('自动完成传输任务', 'autoFinish', (value: boolean): void => {
            this.run(service.setAutoFinish(value));
          })
          this.settingsToggle('保存到历史记录', 'saveToHistory', (value: boolean): void => {
            this.run(service.setSaveToHistory(value));
          })
          this.settingsActionRow('保存目录', '应用目录/LocalSend', (): void => {
            service.openFolder();
          })
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card'))
        .margin({ left: 16, right: 16, top: 10, bottom: 4 })

        // 发送
        Column() {
          Text('发送')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
            .width('100%')
            .margin({ bottom: 8 })
          this.settingsToggle('通过链接分享：自动同意请求', 'webAutoAccept',
            (value: boolean): void => {
              this.run(service.setWebAutoAccept(value));
            })
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card'))
        .margin({ left: 16, right: 16, top: 10, bottom: 4 })

        // 网络
        Column() {
          Text('网络')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
            .width('100%')
            .margin({ bottom: 8 })

          Row({ space: 4 }) {
            Column({ space: 2 }) {
              Text('服务器')
                .fontSize(15)
                .fontColor($r('app.color.text'))
              Text(this.snap.running ? '在线' : '不在线')
                .fontSize(12)
                .fontColor(this.snap.running ? $r('app.color.primary') : $r('app.color.text_dim'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Row({ space: 6 }) {
              if (this.snap.running) {
                this.iconButton($r('app.media.ic_refresh'), $r('app.color.text_dim'), (): void => {
                  this.run(service.restart());
                })
                this.iconButton($r('app.media.ic_stop'), $r('app.color.text_dim'), (): void => {
                  this.run(service.setReceiving(false));
                })
              } else {
                this.iconButton($r('app.media.ic_play'), $r('app.color.primary'), (): void => {
                  this.run(service.setReceiving(true));
                })
              }
            }
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          Column({ space: 6 }) {
            Row() {
              Text('设备名称')
                .fontSize(15)
                .fontColor($r('app.color.text'))
                .layoutWeight(1)
              this.iconButton($r('app.media.ic_dice'), $r('app.color.text_dim'), (): void => {
                this.aliasDraft = randomAlias();
              })
            }
            .width('100%')

            Row({ space: 8 }) {
              TextInput({ text: this.aliasDraft, placeholder: '设备名称，留空用系统名称' })
                .layoutWeight(1)
                .fontSize(14)
                .backgroundColor($r('app.color.input_fill'))
                .borderRadius(8)
                .onChange((value: string): void => {
                  this.aliasDraft = value;
                })
              Button('应用')
                .fontSize(13)
                .height(36)
                .borderRadius(8)
                .backgroundColor($r('app.color.primary'))
                .fontColor($r('app.color.on_primary'))
                .onClick((): void => {
                  this.run(service.setAlias(this.aliasDraft.trim()));
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .alignItems(HorizontalAlign.Start)

          this.settingsToggle('加密传输 (HTTPS/TLS)', 'encryption', (value: boolean): void => {
            this.run(service.setEncryption(value));
          })
          if (this.snap.encryption) {
            Text('当前系统的 TLS 服务端会乱序投递大文件，请仅在局域网可信环境下使用')
              .fontSize(11)
              .fontColor($r('app.color.warning_text'))
              .width('100%')
              .padding({ top: 4, bottom: 6 })
          }
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card'))
        .margin({ left: 16, right: 16, top: 10, bottom: 4 })

        // 其他
        Column() {
          Text('其他')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
            .width('100%')
            .margin({ bottom: 8 })
          this.settingsActionRow('关于 LocalSend', '打开', (): void => {
            this.sheet = 'about';
          })
          this.settingsActionRow('支持 LocalSend', '捐赠', (): void => {
            service.openExternalUrl('https://localsend.org/donate');
          })
          this.settingsActionRow('隐私政策', '打开', (): void => {
            service.openExternalUrl('https://localsend.org/privacy');
          })
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card'))
        .margin({ left: 16, right: 16, top: 10, bottom: 4 })

        // 高级设置复选框
        Row({ space: 8 }) {
          Text('高级设置')
            .fontSize(15)
            .fontColor($r('app.color.text'))
          Checkbox()
            .select(this.snap.advanced)
            .selectedColor($r('app.color.primary'))
            .onChange((value: boolean): void => {
              this.run(service.setAdvanced(value));
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 16, bottom: 12 })

        if (this.snap.advanced) {
          Column() {
            this.kvRow('服务器端口', `${this.snap.port}`)
            this.kvRow('网络协议', this.snap.scheme.toUpperCase())
            this.kvRow('多播', this.snap.multicast ? '可用' : '不可用')
            this.kvRow('指纹', this.snap.fingerprint)
            if (this.snap.hosts.length > 0) {
              Text('手动添加的地址')
                .fontSize(12)
                .fontColor($r('app.color.text_dim'))
                .width('100%')
                .margin({ top: 6, bottom: 4 })
              ForEach(this.snap.hosts, (host: string) => {
                Text(host)
                  .fontSize(13)
                  .fontColor($r('app.color.text'))
                  .width('100%')
              }, (host: string) => host)
            }
            this.settingsActionRow('日志', '查看', (): void => {
              this.sheet = 'log';
            })
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('app.color.card'))
          .margin({ left: 16, right: 16, bottom: 12 })
        }

        Column({ space: 6 }) {
          Image($r('app.media.locallsend_logo'))
            .width(56)
            .height(56)
          Text('LocalSend-HarmonyNext 0.1.0')
            .fontSize(12)
            .fontColor($r('app.color.text_dim'))
          Text('LocalSend 协议 v2.2 · 界面参考官方 LocalSend (Apache-2.0)')
            .fontSize(10)
            .fontColor($r('app.color.text_faint'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ top: 24, bottom: 32 })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder settingsActionRow(label: string, buttonText: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text'))
        .layoutWeight(1)
      Row({ space: 4 }) {
        Text(buttonText)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
        Image($r('app.media.ic_chevron_right'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.text_dim'))
      }
      .padding({ left: 12, right: 10, top: 6, bottom: 6 })
      .borderRadius(8)
      .backgroundColor($r('app.color.input_fill'))
      .onClick(action)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder settingsRow(label: string, value: string, action: () => void) {
    this.settingsActionRow(label, value, action);
  }

  /**
   * The boolean is selected by name, not passed as a value: ArkUI freezes by-value @Builder
   * params, so a toggle that takes `this.snap.x` directly stops following the snapshot.
   */
  @Builder settingsToggle(label: string, kind: string, action: (value: boolean) => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.toggleValue(kind) })
        .selectedColor($r('app.color.primary'))
        .switchPointColor(Color.White)
        .onChange(action)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  private toggleValue(kind: string): boolean {
    if (kind === 'animations') {
      return this.snap.animations;
    }
    if (kind === 'autoFinish') {
      return this.snap.autoFinish;
    }
    if (kind === 'saveToHistory') {
      return this.snap.saveToHistory;
    }
    if (kind === 'encryption') {
      return this.snap.encryption;
    }
    return this.snap.webAutoAccept;
  }

  /** Same by-value freeze as settingsToggle: the value is looked up in the body, not passed in. */
  @Builder settingsValueRow(label: string, kind: string, action: () => void) {
    this.settingsActionRow(label, this.rowValue(kind), action);
  }

  private rowValue(kind: string): string {
    return kind === 'theme' ? this.themeLabel() : this.quickSaveLabel();
  }

  @Builder kvRow(key: string, value: string) {
    Row({ space: 8 }) {
      Text(key)
        .fontSize(14)
        .fontColor($r('app.color.text_dim'))
        .width(90)
      Text(value)
        .fontSize(13)
        .fontColor($r('app.color.text'))
        .layoutWeight(1)
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Top)
  }

  private themeLabel(): string {
    if (this.snap.themeMode === 'dark') {
      return '深色';
    }
    if (this.snap.themeMode === 'light') {
      return '浅色';
    }
    return '跟随系统';
  }

  private quickSaveLabel(): string {
    if (this.snap.quickSave === 'on') {
      return '开';
    }
    if (this.snap.quickSave === 'paired') {
      return '收藏夹';
    }
    return '关';
  }

  // ---------------------------------------------------------------- overlays

  @Builder sheetOverlay() {
    Stack() {
      if (this.sheet === 'history') {
        this.historyPage()
      } else if (this.sheet === 'web') {
        this.webPage()
      } else if (this.sheet === 'troubleshoot') {
        this.troubleshootPage()
      } else if (this.sheet === 'about') {
        this.aboutPage()
      } else if (this.sheet === 'log') {
        this.logPage()
      } else if (this.sheet === 'info') {
        this.infoDialog()
      } else if (this.sheet === 'pin') {
        this.pinDialog()
      } else if (this.sheet === 'text') {
        this.textDialog()
      } else if (this.sheet === 'address') {
        this.addressDialog()
      } else if (this.sheet === 'favorites') {
        this.favoritesDialog()
      } else if (this.sheet === 'favAdd') {
        this.favAddDialog()
      } else if (this.sheet === 'pickChooser') {
        this.pickChooserDialog()
      } else if (this.sheet === 'pickedEdit') {
        this.pickedEditDialog()
      } else if (this.sheet === 'sendConfirm') {
        this.sendConfirmDialog()
      } else if (this.sheet === 'sendMode') {
        this.sendModeDialog()
      } else if (this.sheet === 'theme') {
        this.themeDialog()
      } else if (this.sheet === 'quickSave') {
        this.quickSaveDialog()
      } else if (this.sheet === 'entryActions') {
        this.entryActionsDialog()
      } else if (this.sheet === 'entryInfo') {
        this.entryInfoDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  private closeSheet(): void {
    if (this.sheet === 'web') {
      service.stopWebShare();
    }
    this.sheet = 'none';
  }

  @Builder infoDialog() {
    Column() {
      Column({ space: 12 }) {
        Text('信息')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        this.kvRow('设备名称', this.snap.alias)
        this.kvRow('IP 地址', this.snap.localIps.length > 0 ? this.snap.localIps.join(', ') : '离线')
        this.kvRow('端口', `${this.snap.port}`)
        this.kvRow('协议', this.snap.scheme.toUpperCase())
        this.kvRow('状态', this.snap.running ? '在线' : '不在线')
        Text(this.snap.fingerprint)
          .fontSize(10)
          .fontColor($r('app.color.text_dim'))
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
        Row() {
          Blank()
          Button('关闭')
            .fontSize(13)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'none';
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder pinDialog() {
    Column() {
      Column({ space: 12 }) {
        Text('接收 PIN')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        Text('开启后，其他设备和浏览器上传前都必须输入这串数字')
          .fontSize(12)
          .fontColor($r('app.color.text_dim'))
          .width('100%')
        TextInput({ text: this.pinEdit, placeholder: '至少 4 位数字' })
          .type(InputType.Number)
          .maxLength(8)
          .backgroundColor($r('app.color.input_fill'))
          .onChange((value: string): void => {
            this.pinEdit = value;
          })
        Row({ space: 8 }) {
          Button('随机生成')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.pinEdit = randomPin();
            })
          Blank()
          Button('取消')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'none';
            })
          Button('确定')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.on_primary'))
            .onClick((): void => {
              this.confirmPin();
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder textDialog() {
    Column() {
      Column({ space: 12 }) {
        Text('文本')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        TextArea({ text: this.textDraft, placeholder: '输入要发送的文本' })
          .height(140)
          .backgroundColor($r('app.color.input_fill'))
          .onChange((value: string): void => {
            this.textDraft = value;
          })
        Row({ space: 8 }) {
          Blank()
          Button('取消')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'none';
            })
          Button('确定')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.on_primary'))
            .onClick((): void => {
              const text: string = this.textDraft;
              if (text.trim().length === 0) {
                service.reportError('文本为空');
                return;
              }
              service.stageText(text, `文本-${stampName()}.txt`);
              this.sheet = 'none';
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder addressDialog() {
    Column() {
      Column({ space: 12 }) {
        Text('手动发送')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        Text('输入目标设备的地址，例如 192.168.1.10 或 https://192.168.1.10:53317')
          .fontSize(12)
          .fontColor($r('app.color.text_dim'))
          .width('100%')
        TextInput({ text: this.hostDraft, placeholder: '地址' })
          .backgroundColor($r('app.color.input_fill'))
          .onChange((value: string): void => {
            this.hostDraft = value;
          })
        Row({ space: 8 }) {
          Blank()
          Button('取消')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'none';
            })
          Button('添加')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.on_primary'))
            .onClick((): void => {
              const spec: string = this.hostDraft.trim();
              if (spec.length === 0) {
                return;
              }
              this.run(service.addKnownHost(spec));
              this.sheet = 'none';
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder favoritesDialog() {
    Column() {
      Column({ space: 10 }) {
        Text('收藏夹')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        if (this.snap.favorites.length === 0) {
          Text('还没有收藏的设备。点击设备卡片上的心形图标即可收藏。')
            .fontSize(12)
            .fontColor($r('app.color.text_dim'))
            .width('100%')
        } else {
          Scroll() {
            Column({ space: 4 }) {
              ForEach(this.snap.favorites, (favorite: FavoriteRow) => {
                Row({ space: 8 }) {
                  Image($r('app.media.ic_heart'))
                    .width(18)
                    .height(18)
                    .fillColor($r('app.color.primary'))
                  Column({ space: 2 }) {
                    Text(favorite.name)
                      .fontSize(14)
                      .fontColor($r('app.color.text'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(favorite.fingerprint.length > 0
                      ? `${favorite.host}:${favorite.port}`
                      : `${favorite.host}:${favorite.port} · 手动添加`)
                      .fontSize(11)
                      .fontColor($r('app.color.text_dim'))
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  this.iconButton($r('app.media.ic_delete'), $r('app.color.text_faint'), (): void => {
                    this.run(service.removeFavorite(this.favoriteKeyOf(favorite)));
                  })
                }
                .width('100%')
                .padding({ top: 4, bottom: 4 })
              }, (favorite: FavoriteRow) => `${favorite.host}:${favorite.port}:${favorite.fingerprint}:${favorite.name}`)
            }
            .width('100%')
          }
          .constraintSize({ maxHeight: 240 })
          .width('100%')
          .scrollBar(BarState.Off)
        }
        Row({ space: 8 }) {
          Button('添加设备')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.favName = '';
              this.favHost = '';
              this.favPort = '53317';
              this.sheet = 'favAdd';
            })
          Blank()
          Button('关闭')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'none';
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder favAddDialog() {
    Column() {
      Column({ space: 12 }) {
        Text('添加收藏')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        TextInput({ text: this.favName, placeholder: '名称' })
          .backgroundColor($r('app.color.input_fill'))
          .onChange((value: string): void => {
            this.favName = value;
          })
        TextInput({ text: this.favHost, placeholder: 'IP 地址' })
          .backgroundColor($r('app.color.input_fill'))
          .onChange((value: string): void => {
            this.favHost = value;
          })
        TextInput({ text: this.favPort, placeholder: '端口' })
          .type(InputType.Number)
          .maxLength(5)
          .backgroundColor($r('app.color.input_fill'))
          .onChange((value: string): void => {
            this.favPort = value;
          })
        Row({ space: 8 }) {
          Blank()
          Button('取消')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'favorites';
            })
          Button('添加')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.on_primary'))
            .onClick((): void => {
              this.run(service.addFavoriteManual(this.favName.trim(), this.favHost.trim(),
                Number.parseInt(this.favPort, 10)));
              this.sheet = 'favorites';
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder pickChooserDialog() {
    Column() {
      Column({ space: 10 }) {
        Text('你想添加什么？')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        this.chooserRow('文件', $r('app.media.ic_document'), (): void => {
          this.sheet = 'none';
          this.pickDocuments();
        })
        this.chooserRow('媒体', $r('app.media.ic_image'), (): void => {
          this.sheet = 'none';
          this.pickPhotos();
        })
        this.chooserRow('剪贴板', $r('app.media.ic_clipboard'), (): void => {
          this.sheet = 'none';
          this.pickClipboard();
        })
        this.chooserRow('文本', $r('app.media.ic_text'), (): void => {
          this.textDraft = '';
          this.sheet = 'text';
        })
        Row() {
          Blank()
          Button('取消')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'none';
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder chooserRow(label: string, icon: Resource, action: () => void) {
    Row({ space: 12 }) {
      Image(icon)
        .width(22)
        .height(22)
        .fillColor($r('app.color.text_dim'))
      Text(label)
        .fontSize(16)
        .fontColor($r('app.color.text'))
        .layoutWeight(1)
      Image($r('app.media.ic_chevron_right'))
        .width(18)
        .height(18)
        .fillColor($r('app.color.text_faint'))
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(action)
  }

  @Builder pickedEditDialog() {
    Column() {
      Column({ space: 10 }) {
        Text('编辑')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        Scroll() {
          Column({ space: 4 }) {
            ForEach(this.snap.picked, (file: FileRow) => {
              Row({ space: 8 }) {
                Image(iconOfName(file.name))
                  .width(18)
                  .height(18)
                  .fillColor($r('app.color.text_dim'))
                Text(file.name)
                  .fontSize(14)
                  .fontColor($r('app.color.text'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(formatBytes(file.size))
                  .fontSize(11)
                  .fontColor($r('app.color.text_dim'))
                this.iconButton($r('app.media.ic_close'), $r('app.color.text_faint'), (): void => {
                  service.removePicked(file.id);
                })
              }
              .width('100%')
            }, (file: FileRow) => `${file.id}:${file.size}`)
          }
          .width('100%')
        }
        .constraintSize({ maxHeight: 260 })
        .width('100%')
        .scrollBar(BarState.Off)

        Row({ space: 8 }) {
          Button('清空全部')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.danger'))
            .onClick((): void => {
              service.clearPicked();
              this.sheet = 'none';
            })
          Blank()
          Button('完成')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'none';
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder sendConfirmDialog() {
    Column() {
      Column({ space: 12 }) {
        Text(`发送到 ${this.peerName(this.sendTarget)}`)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${this.sendTarget.host}:${this.sendTarget.port}`)
          .fontSize(12)
          .fontColor($r('app.color.text_dim'))
          .width('100%')
        Text(`${this.snap.picked.length} 个文件 · ${formatBytes(this.pickedSize())}`)
          .fontSize(14)
          .fontColor($r('app.color.text_dim'))
          .width('100%')
        TextInput({ text: this.pinDraft, placeholder: '接收方 PIN（如需要）' })
          .type(InputType.Number)
          .maxLength(8)
          .backgroundColor($r('app.color.input_fill'))
          .onChange((value: string): void => {
            this.pinDraft = value;
          })
        Row({ space: 8 }) {
          Blank()
          Button('取消')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sendTarget = new PeerRow();
              this.sheet = 'none';
            })
          Button('发送')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.on_primary'))
            .onClick((): void => {
              this.confirmSend();
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder sendModeDialog() {
    Column() {
      Column({ space: 10 }) {
        Text('发送模式')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        this.modeRow('一个接收者', true, (): void => {
          this.sheet = 'none';
        })
        this.modeRow('通过链接分享', false, (): void => {
          this.sheet = 'none';
          this.startLinkShare();
        })
        Text('选中文件后点击设备即可发送；「通过链接分享」会让同一网络里的浏览器下载这些文件。')
          .fontSize(11)
          .fontColor($r('app.color.text_faint'))
          .width('100%')
        Row() {
          Blank()
          Button('关闭')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'none';
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder modeRow(label: string, selected: boolean, action: () => void) {
    Row({ space: 10 }) {
      Image(selected ? $r('app.media.ic_check') : $r('app.media.ic_chevron_right'))
        .width(20)
        .height(20)
        .fillColor(selected ? $r('app.color.primary') : $r('app.color.text_faint'))
      Text(label)
        .fontSize(16)
        .fontColor($r('app.color.text'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(action)
  }

  @Builder themeDialog() {
    Column() {
      Column({ space: 10 }) {
        Text('主题')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        this.themeRow('跟随系统', 'system')
        this.themeRow('深色', 'dark')
        this.themeRow('浅色', 'light')
        Row() {
          Blank()
          Button('关闭')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'none';
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder themeRow(label: string, mode: string) {
    Row({ space: 10 }) {
      Image(this.snap.themeMode === mode ? $r('app.media.ic_check') : $r('app.media.ic_chevron_right'))
        .width(20)
        .height(20)
        .fillColor(this.snap.themeMode === mode ? $r('app.color.primary') : $r('app.color.text_faint'))
      Text(label)
        .fontSize(16)
        .fontColor($r('app.color.text'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick((): void => {
      this.run(service.setThemeMode(mode));
      this.sheet = 'none';
    })
  }

  @Builder quickSaveDialog() {
    Column() {
      Column({ space: 10 }) {
        Text('自动保存')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        this.quickSaveRow('关', '', 'off')
        this.quickSaveRow('收藏夹', '自动保存来自「收藏夹(白名单)」设备的文件', 'paired')
        this.quickSaveRow('开', '自动接受所有文件传输请求。请注意，这会让此网络中的所有人都可以向你发送文件。', 'on')
        Row() {
          Blank()
          Button('关闭')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'none';
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder quickSaveRow(label: string, subtitle: string, mode: string) {
    Row({ space: 10 }) {
      Image(this.snap.quickSave === mode ? $r('app.media.ic_check') : $r('app.media.ic_chevron_right'))
        .width(20)
        .height(20)
        .fillColor(this.snap.quickSave === mode ? $r('app.color.primary') : $r('app.color.text_faint'))
      Column({ space: 2 }) {
        Text(label)
          .fontSize(16)
          .fontColor($r('app.color.text'))
          .width('100%')
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(11)
            .fontColor($r('app.color.text_dim'))
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick((): void => {
      this.run(service.setQuickSave(mode));
      this.sheet = 'none';
    })
  }

  // ----------------------------------------------------------- history page

  @Builder historyPage() {
    Column() {
      this.overlayHeader('历史')

      Row({ space: 10 }) {
        Button('打开目录')
          .fontSize(13)
          .height(38)
          .backgroundColor($r('app.color.primary_soft'))
          .fontColor($r('app.color.on_soft'))
          .onClick((): void => {
            service.openFolder();
          })
        Button('删除历史记录')
          .fontSize(13)
          .height(38)
          .backgroundColor($r('app.color.primary_soft'))
          .fontColor($r('app.color.on_soft'))
          .enabled(this.snap.history.length > 0)
          .onClick((): void => {
            AlertDialog.show({
              title: '删除历史记录',
              message: '将清空全部历史记录，已接收的文件不会被删除。',
              autoCancel: true,
              primaryButton: {
                value: '取消',
                action: (): void => {
                }
              },
              secondaryButton: {
                value: '删除',
                fontColor: $r('app.color.danger'),
                action: (): void => {
                  service.clearHistory();
                }
              }
            });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 10 })

      if (this.snap.history.length === 0) {
        Column() {
          Text('无历史记录。')
            .fontSize(22)
            .fontColor($r('app.color.text_faint'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 0 }) {
          ForEach(this.snap.history, (entry: HistoryRow) => {
            ListItem() {
              Row({ space: 10 }) {
                Image(iconOfFileType(entry.fileType))
                  .width(22)
                  .height(22)
                  .fillColor($r('app.color.text_dim'))
                Column({ space: 2 }) {
                  Text(entry.name)
                    .fontSize(15)
                    .fontColor($r('app.color.text'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${timeText(entry.timeMs)} - ${formatBytes(entry.size)} - ${entry.sender}`)
                    .fontSize(11)
                    .fontColor($r('app.color.text_dim'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                if (!entry.saved) {
                  Button('保存')
                    .fontSize(12)
                    .height(28)
                    .backgroundColor($r('app.color.primary'))
                    .fontColor($r('app.color.on_primary'))
                    .enabled(this.snap.savingId === '')
                    .onClick((): void => {
                      this.run(service.saveHistoryEntry(entry.id));
                    })
                }
                Image($r('app.media.ic_chevron_right'))
                  .width(18)
                  .height(18)
                  .fillColor($r('app.color.text_faint'))
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .onClick((): void => {
                this.entryId = entry.id;
                this.sheet = 'entryActions';
              })
            }
          }, (entry: HistoryRow) => `${entry.id}:${entry.saved}:${entry.name}:${entry.timeMs}`)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  @Builder entryActionsDialog() {
    Column() {
      Column({ space: 8 }) {
        Text(this.entryName())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.actionRow('打开文件', $r('app.media.ic_document'), false, (): void => {
          const entry: HistoryRow | null = this.entryOf();
          if (entry !== null) {
            service.openFile(entry.path, entry.fileType);
          }
          this.sheet = 'none';
        })
        this.actionRow('在文件管理器中显示', $r('app.media.ic_folder'), false, (): void => {
          const entry: HistoryRow | null = this.entryOf();
          if (entry !== null) {
            service.openFolderOf(entry.path);
          }
          this.sheet = 'none';
        })
        this.actionRow('信息', $r('app.media.ic_info'), false, (): void => {
          this.sheet = 'entryInfo';
        })
        this.actionRow('从历史记录中删除', $r('app.media.ic_delete'), true, (): void => {
          service.removeHistoryEntry(this.entryId);
          this.sheet = 'none';
        })
        Row() {
          Blank()
          Button('取消')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'none';
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder actionRow(label: string, icon: Resource, danger: boolean, action: () => void) {
    Row({ space: 12 }) {
      Image(icon)
        .width(20)
        .height(20)
        .fillColor(danger ? $r('app.color.danger') : $r('app.color.text_dim'))
      Text(label)
        .fontSize(16)
        .fontColor(danger ? $r('app.color.danger') : $r('app.color.text'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(action)
  }

  @Builder entryInfoDialog() {
    Column() {
      Column({ space: 10 }) {
        Text('信息')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        this.kvRow('名称', this.entryField('name'))
        this.kvRow('大小', this.entryField('size'))
        this.kvRow('类型', this.entryField('type'))
        this.kvRow('来源', this.entryField('sender'))
        this.kvRow('时间', this.entryField('time'))
        Text(this.entryField('path'))
          .fontSize(10)
          .fontColor($r('app.color.text_dim'))
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
        Row({ space: 8 }) {
          Blank()
          Button('关闭')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              this.sheet = 'entryActions';
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  private favoriteKeyOf(favorite: FavoriteRow): string {
    return favorite.fingerprint.length > 0
      ? favorite.fingerprint
      : `${favorite.host}:${favorite.port}`;
  }

  private entryOf(): HistoryRow | null {
    const entries: HistoryRow[] = this.snap.history;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].id === this.entryId) {
        return entries[i];
      }
    }
    return null;
  }

  private entryName(): string {
    const entry: HistoryRow | null = this.entryOf();
    return entry === null ? '' : entry.name;
  }

  /** One field of the entry dialog; '' beats crashing on a row that vanished. */
  private entryField(field: string): string {
    const entry: HistoryRow | null = this.entryOf();
    if (entry === null) {
      return '';
    }
    if (field === 'name') {
      return entry.name;
    }
    if (field === 'size') {
      return formatBytes(entry.size);
    }
    if (field === 'type') {
      return entry.fileType.length > 0 ? entry.fileType : '未知';
    }
    if (field === 'sender') {
      return entry.sender;
    }
    if (field === 'time') {
      return timeText(entry.timeMs);
    }
    return entry.path;
  }

  // ------------------------------------------------------- web share page

  /**
   * Its own header instead of overlayHeader: the title depends on the mode, which flips
   * right after the sheet mounts, and a by-value param would keep the first title forever.
   */
  @Builder webPageHeader() {
    Row({ space: 6 }) {
      this.iconButton($r('app.media.ic_back'), $r('app.color.text'), (): void => {
        this.closeSheet();
      })
      Text(this.snap.webUploading && !this.snap.webSharing ? '通过链接接收' : '分享为链接')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(56)
    .padding({ right: 12 })
    .backgroundColor($r('app.color.bg'))
  }

  @Builder webPage() {
    Column() {
      this.webPageHeader()

      Scroll() {
        Column({ space: 12 }) {
          if (this.snap.webUrls.length === 0) {
            Text('正在启动服务器……')
              .fontSize(14)
              .fontColor($r('app.color.text_dim'))
          } else {
            Text(this.snap.webUrls.length > 1 ? '在浏览器中打开其中一个链接：' : '在浏览器中打开链接：')
              .fontSize(13)
              .fontColor($r('app.color.text_dim'))
              .width('100%')
            ForEach(this.snap.webUrls, (url: string) => {
              Text(url)
                .fontSize(13)
                .fontFamily('monospace')
                .fontColor($r('app.color.primary'))
                .copyOption(CopyOptions.LocalDevice)
                .width('100%')
            }, (url: string) => url)
          }

          if (this.snap.webUploading) {
            Text('同一网络的电脑浏览器打开上面的地址即可上传；收到的文件会像普通接收一样弹出确认。')
              .fontSize(12)
              .fontColor($r('app.color.text_dim'))
              .width('100%')
            if (this.snap.receivePin.length > 0) {
              Text(`浏览器上传时需要输入 PIN：${this.snap.receivePin}`)
                .fontSize(12)
                .fontColor($r('app.color.warning_text'))
                .width('100%')
            }
          }

          if (this.snap.webSharing) {
            Text(this.snap.webAutoAccept
              ? '已开启自动同意：浏览器请求将直接放行'
              : '有浏览器请求下载时会弹出确认')
              .fontSize(12)
              .fontColor($r('app.color.text_dim'))
              .width('100%')
            Text(`共 ${this.snap.webFiles.length} 个文件 · 已送出 ${formatBytes(this.snap.webSent)} · `
              + `已允许 ${this.snap.webClients} 台浏览器`)
              .fontSize(12)
              .fontColor($r('app.color.text_dim'))
              .width('100%')

            ForEach(this.snap.webFiles, (item: FileRow) => {
              Row() {
                Text(item.name)
                  .fontSize(13)
                  .fontColor($r('app.color.text'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${formatBytes(item.received)} / ${formatBytes(item.size)}`)
                  .fontSize(11)
                  .fontColor($r('app.color.text_dim'))
                Text(webStatusLabel(item.status))
                  .fontSize(11)
                  .fontColor(item.status === 'done' ? $r('app.color.primary') : $r('app.color.text_dim'))
                  .margin({ left: 8 })
              }
              .width('100%')
            // As in the send rows: every value drawn here belongs in the key, or the row never updates.
            }, (item: FileRow) => `${item.id}:${item.status}:${item.received}`)
          }

          Button('停止')
            .fontSize(13)
            .height(38)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.danger'))
            .onClick((): void => {
              service.stopWebShare();
              this.sheet = 'none';
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  // ---------------------------------------------------------- info pages

  @Builder troubleshootPage() {
    Column() {
      this.overlayHeader('故障排除')
      Scroll() {
        Column({ space: 10 }) {
          Text('应用没有按预期工作？您可以在这里找到常用解决方案。')
            .fontSize(13)
            .fontColor($r('app.color.text_dim'))
            .width('100%')

          this.troubleshootItem('此设备未能发现其他设备。',
            '确保所有设备都处于同一个 Wi-Fi 网络上，且共享相同的网络配置（端口、多播地址、加密选项）。'
              + '您可以尝试手动输入目标设备的 IP 地址——如果起到了效果，请考虑将此设备添加到收藏夹中，'
              + '以便将来可以自动发现。')
          this.troubleshootItem('双方设备均无法发现对方或者分享文件。',
            '请先确认双方设备处于同一个 Wi-Fi 网络上，且共享相同的网络配置（端口、多播地址、加密选项）。'
              + '若因 Wi-Fi 不允许参与者间通信，那么请在路由器中关闭「接入点(AP)隔离」选项。')
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  @Builder troubleshootItem(symptom: string, solution: string) {
    Column({ space: 8 }) {
      Text(symptom)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text'))
        .width('100%')
      Text('解决方案：')
        .fontSize(13)
        .fontColor($r('app.color.text_dim'))
        .width('100%')
      Text(solution)
        .fontSize(13)
        .fontColor($r('app.color.text_dim'))
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('app.color.card'))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder aboutPage() {
    Column() {
      this.overlayHeader('关于 LocalSend')
      Scroll() {
        Column({ space: 12 }) {
          Image($r('app.media.locallsend_logo'))
            .width(88)
            .height(88)
            .alignSelf(ItemAlign.Center)
          Text('LocalSend-HarmonyNext 0.1.0')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text'))
            .width('100%')
            .textAlign(TextAlign.Center)
          Text('本应用是 LocalSend 协议的独立 HarmonyOS 实现，可与官方 LocalSend 客户端在局域网内直接互传文件，'
            + '不经过任何服务器，也不收集任何数据。')
            .fontSize(13)
            .fontColor($r('app.color.text_dim'))
            .width('100%')
          Text('界面与图标参考官方应用 LocalSend（Apache-2.0 许可）。')
            .fontSize(13)
            .fontColor($r('app.color.text_dim'))
            .width('100%')
          Text('协议版本 v2.2 · 端口 53317')
            .fontSize(12)
            .fontColor($r('app.color.text_faint'))
            .width('100%')
          Row({ space: 10 }) {
            Button('官方项目')
              .fontSize(13)
              .height(38)
              .backgroundColor($r('app.color.input_fill'))
              .fontColor($r('app.color.text'))
              .onClick((): void => {
                service.openExternalUrl('https://localsend.org');
              })
            Button('关闭')
              .fontSize(13)
              .height(38)
              .backgroundColor($r('app.color.input_fill'))
              .fontColor($r('app.color.text'))
              .onClick((): void => {
                this.sheet = 'none';
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  @Builder logPage() {
    Column() {
      this.overlayHeader('日志')
      Scroll() {
        Text(this.logText())
          .fontSize(10)
          .fontFamily('monospace')
          .fontColor($r('app.color.text_dim'))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 20 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  private logText(): string {
    const lines: string[] = this.snap.log;
    let text: string = '';
    for (let i = lines.length - 1; i >= 0; i--) {
      text += `${lines[i]}\n`;
    }
    return text;
  }

  // ------------------------------------------------------------ incoming

  @Builder offerSheet() {
    Column() {
      Column({ space: 10 }) {
        Text(`${this.snap.offerSender}`)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text('想要发送以下文件')
          .fontSize(13)
          .fontColor($r('app.color.text_dim'))
          .width('100%')
        Scroll() {
          Column({ space: 4 }) {
            ForEach(this.snap.offerFiles, (file: FileRow) => {
              Row() {
                Text(file.name)
                  .fontSize(12)
                  .fontColor($r('app.color.text'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(formatBytes(file.size))
                  .fontSize(11)
                  .fontColor($r('app.color.text_dim'))
              }
              .width('100%')
            }, (file: FileRow) => `${file.id}:${file.name}`)
          }
          .width('100%')
        }
        .constraintSize({ maxHeight: 200 })
        .width('100%')
        .scrollBar(BarState.Off)

        Text(`保存到 ${this.snap.offerDestination}`)
          .fontSize(10)
          .fontColor($r('app.color.text_faint'))
          .width('100%')

        Row({ space: 8 }) {
          Blank()
          Button('拒绝')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              service.declineOffer();
            })
          Button('接受')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.on_primary'))
            .onClick((): void => {
              service.acceptOffer(this.allOfferIds());
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  @Builder webOfferSheet() {
    Column() {
      Column({ space: 10 }) {
        Text('有浏览器想下载分享的文件')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
        Text(`来源 ${this.snap.webOfferClient}`)
          .fontSize(13)
          .fontColor($r('app.color.text_dim'))
          .width('100%')
        Text(`${this.snap.webOfferFiles} 个文件 · ${formatBytes(this.snap.webOfferBytes)}`)
          .fontSize(13)
          .fontColor($r('app.color.text_dim'))
          .width('100%')
        if (this.snap.webOfferAgent.length > 0) {
          Text(this.snap.webOfferAgent)
            .fontSize(10)
            .fontColor($r('app.color.text_faint'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        Row({ space: 8 }) {
          Blank()
          Button('拒绝')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.input_fill'))
            .fontColor($r('app.color.text'))
            .onClick((): void => {
              service.denyWebVisitor();
            })
          Button('允许')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.on_primary'))
            .onClick((): void => {
              service.allowWebVisitor();
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.sheet_dim'))
  }

  private allOfferIds(): string[] {
    const rows: FileRow[] = this.snap.offerFiles;
    const ids: string[] = [];
    for (let i = 0; i < rows.length; i++) {
      ids.push(rows[i].id);
    }
    return ids;
  }

  // ------------------------------------------------------------------ flows

  /** Every action is fire-and-forget on screen; a rejected one still has to be reported. */
  private run(action: Promise<void>): void {
    action.catch((reason: Object): void => {
      service.reportError(`${describeFailure(reason)}`);
    });
  }

  /** A pick that starts outside the device flow must not inherit a pending target. */
  private beginPick(): void {
    this.sendTarget = new PeerRow();
    this.pendingShare = false;
  }

  private onTapDevice(peer: PeerRow): void {
    this.pendingShare = false;
    this.sendTarget = peer;
    if (this.snap.picked.length === 0) {
      this.sheet = 'pickChooser';
    } else {
      this.sheet = 'sendConfirm';
    }
  }

  private confirmSend(): void {
    if (this.snap.sendActive) {
      service.reportError('已有发送任务在进行');
      return;
    }
    service.startSend(this.sendTarget.fingerprint, this.pinDraft.trim());
    this.pinDraft = '';
    this.sendTarget = new PeerRow();
    this.sheet = 'none';
  }

  private startLinkShare(): void {
    if (this.snap.picked.length === 0) {
      this.pendingShare = true;
      this.sheet = 'pickChooser';
      return;
    }
    this.sheet = 'web';
    if (!this.snap.webSharing) {
      this.run(service.startWebShare());
    }
  }

  private openWebUpload(): void {
    this.sheet = 'web';
    if (!this.snap.webUploading) {
      this.run(service.toggleWebUpload());
    }
  }

  private confirmPin(): void {
    const pin: string = this.pinEdit.trim();
    if (pin.length < 4) {
      service.reportError('PIN 至少 4 位');
      return;
    }
    this.sheet = 'none';
    this.run(service.setReceivePin(pin));
  }

  /**
   * Both pickers are the system ones, so no media or file permission is requested: the returned uris
   * carry the temporary read grant with them.
   */
  private pickDocuments(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    // The picker may answer with a single uri per invocation on a phone, so picks accumulate in the
    // service rather than replacing each other.
    const options: picker.DocumentSelectOptions = {
      maxSelectNumber: MAX_PICK
    };
    const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    docPicker.select(options).then((uris: string[]): void => {
      this.applyPicked(uris);
    }).catch((reason: BusinessError): void => {
      service.reportError(`选择文档失败: ${reason.message}`);
    });
  }

  private pickPhotos(): void {
    const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
    options.maxSelectNumber = MAX_PICK;
    const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    photoPicker.select(options).then((result: photoAccessHelper.PhotoSelectResult): void => {
      this.applyPicked(result.photoUris);
    }).catch((reason: BusinessError): void => {
      service.reportError(`选择媒体失败: ${reason.message}`);
    });
  }

  private pickClipboard(): void {
    pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData): void => {
      const text: string = data.getPrimaryText();
      if (text.length === 0) {
        service.reportError('剪贴板为空');
        return;
      }
      service.stageText(text, `剪贴板-${stampName()}.txt`);
    }).catch((): void => {
      service.reportError('剪贴板为空');
    });
  }

  /** An empty result is a dismissed dialog, not a failure worth a red line. */
  private applyPicked(uris: string[]): void {
    if (uris.length === 0) {
      return;
    }
    service.addPicked(uris);
  }
}
