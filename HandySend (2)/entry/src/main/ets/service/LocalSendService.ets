import { common, ConfigurationConstant, wantConstant, Want, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import {
  ApiPath, ClientCredentials, DEFAULT_PORT, DestinationContext, DeviceTypeValue, Discovery,
  FileProgressEvent, FileStatus, HttpServer, Identity, IdentityRepository, KnownChannel, LocalInterface,
  PrepareContext, PrepareDecision, PROTOCOL_VERSION, Peer, ProtocolScheme, ReceivedFile, ReceiveSession,
  RequestHandler, SendFile, SendFileStatus, SendSource, SendTarget, SendTask, SendTaskStatus, Sender,
  SenderConfig, SessionEndReason, SessionManager, SessionManagerConfig, TlsMaterial, WireDeviceInfo,
  WebOfferContext, WebOfferFile, WebShare, WebShareConfig, describeFailure
} from '@lsnext/protocol';
import { AppPrefs } from './AppPrefs';
import { formatHostSpec, parseHostSpec, sameHost } from './HostSpec';
/** hilog tag; 0x0000 keeps us inside the app's own log domain. */
const TAG: string = 'LocalSendNext';

/** What the page draws. A fresh snapshot per change keeps ArkUI's @State diffing honest. */
export class PeerRow {
  name: string = '';
  host: string = '';
  port: number = 0;
  scheme: string = 'http';
  download: boolean = false;
  fingerprint: string = '';
  /** Shown under the name on the send tab; empty while discovery has not enriched the peer. */
  model: string = '';
  deviceType: string = '';
}

export class FileRow {
  /** fileId, so an accept can name exactly the rows the page showed. */
  id: string = '';
  name: string = '';
  size: number = 0;
  /** Bytes received while downloading; bytes handed to the socket while sending. */
  received: number = 0;
  status: string = '';
}

/** What a system save picker needs; a just-received row and a history line both provide it. */
export interface SaveTarget {
  name: string;
  fileType: string;
  path: string;
}

/** A file of the last finished session, with what a save target needs to take it from the sandbox. */
export class ReceivedRow extends FileRow implements SaveTarget {
  path: string = '';
  fileType: string = '';
  saved: boolean = false;
}

/** A device the user starred; manual entries have no fingerprint and never quick-save. */
export interface FavoriteRow {
  name: string;
  host: string;
  port: number;
  fingerprint: string;
}

/** One line of the persistent receive history. */
export interface HistoryRow extends SaveTarget {
  id: string;
  size: number;
  sender: string;
  timeMs: number;
  saved: boolean;
}

export class ServiceSnapshot {
  running: boolean = false;
  alias: string = '';
  fingerprint: string = '';
  scheme: string = 'http';
  port: number = DEFAULT_PORT;
  multicast: boolean = false;
  encryption: boolean = false;
  peers: PeerRow[] = [];
  hasOffer: boolean = false;
  offerSender: string = '';
  offerDestination: string = '';
  offerFiles: FileRow[] = [];
  hasSession: boolean = false;
  sessionSender: string = '';
  sessionFiles: FileRow[] = [];
  /** Files from the last finished session that are still sitting in the sandbox. */
  lastReceived: ReceivedRow[] = [];
  /** The row whose save target is open, so the page can disable the other save buttons. */
  savingId: string = '';
  hosts: string[] = [];
  /** Files the user has picked to send, not sent yet. */
  picked: FileRow[] = [];
  sendActive: boolean = false;
  sendPeer: string = '';
  sendState: string = '';
  sendFiles: FileRow[] = [];
  sendTotal: number = 0;
  sendSent: number = 0;
  sendError: string = '';
  /** The web share (Download API): what is offered, where to open it, and who got in. */
  webSharing: boolean = false;
  webUploading: boolean = false;
  webFiles: FileRow[] = [];
  webTotal: number = 0;
  webSent: number = 0;
  webClients: number = 0;
  webUrls: string[] = [];
  hasWebOffer: boolean = false;
  webOfferClient: string = '';
  webOfferAgent: string = '';
  webOfferFiles: number = 0;
  webOfferBytes: number = 0;
  /** The receive PIN, or empty while senders need none. */
  receivePin: string = '';
  log: string[] = [];
  /** 'off' | 'paired' | 'on' — the receive page's quick-save control. */
  quickSave: string = 'off';
  favorites: FavoriteRow[] = [];
  /** Persistent receive history, newest first. */
  history: HistoryRow[] = [];
  /** 'system' | 'light' | 'dark'. */
  themeMode: string = 'system';
  animations: boolean = true;
  /** On: a finished transfer disappears by itself. Off: it waits for 完成. */
  autoFinish: boolean = true;
  saveToHistory: boolean = true;
  advanced: boolean = false;
  /** On: browsers downloading the shared files are let in without a per-request dialog. */
  webAutoAccept: boolean = false;
  /** Every local IPv4 address; the receive page derives the official '#<last octet>' from them. */
  localIps: string[] = [];
  /** The finished session kept on screen while autoFinish is off. */
  hasFinished: boolean = false;
  finishedSender: string = '';
  finishedFiles: FileRow[] = [];
}

/** A staged pick, with the metadata the UI shows before any hashing has happened. */
class PickedItem {
  uri: string = '';
  name: string = '';
  size: number = 0;
}

/** The directory files land in, decided once per app run. */
const RECEIVE_SUBDIR: string = '/LocalSend';

// How long a save button keeps waiting on a system dialog before unlocking. The photo dialog is a
// single confirm; the document picker means browsing folders, where a person can legitimately take
// minutes. A picker that answers after its deadline still completes on its own (see withDeadline).
const GALLERY_TIMEOUT_MS: number = 60000;
const DOCUMENT_TIMEOUT_MS: number = 300000;

/**
 * The app-side controller: identity, HTTP server, discovery and the receive session
 * engine, wired together and mirrored into one snapshot for the page.
 *
 * Everything protocol-shaped lives in the HAR; this class only owns lifecycle and the
 * answers the protocol asks the application for (where to save, what the user accepted).
 */
export class LocalSendService {
  private prefs: AppPrefs | null = null;
  private identity: Identity | null = null;
  private server: HttpServer | null = null;
  private discovery: Discovery | null = null;
  private sessions: SessionManager | null = null;
  private filesDir: string = '';
  private abilityContext: common.UIAbilityContext | null = null;
  /** True while the receive service holds a `dataTransfer` background task declaration. */
  private backgroundRunning: boolean = false;
  private logLines: string[] = [];
  private listener: ((snapshot: ServiceSnapshot) => void) | null = null;
  /** Set while an offer is on screen; the page's accept/decline resolves it. */
  private resolveOffer: ((decision: PrepareDecision) => void) | null = null;
  private offer: PrepareContext | null = null;
  private session: ReceiveSession | null = null;
  private received: ReceivedRow[] = [];
  private savingId: string = '';
  private running: boolean = false;
  private aliasText: string = '';
  private encryption: boolean = false;
  private known: KnownChannel[] = [];
  private sender: Sender | null = null;
  private picked: PickedItem[] = [];
  private web: WebShare | null = null;
  /** Set while a browser's download request is on screen. */
  private webOffer: WebOfferContext | null = null;
  private resolveWebOffer: ((accepted: boolean) => void) | null = null;
  private quickSaveMode: string = 'off';
  private favs: FavoriteRow[] = [];
  private historyEntries: HistoryRow[] = [];
  private themeModeValue: string = 'system';
  private animationsValue: boolean = true;
  private autoFinishValue: boolean = true;
  private saveToHistoryValue: boolean = true;
  private advancedValue: boolean = false;
  private webAutoAcceptValue: boolean = false;
  private finishedRows: FileRow[] = [];
  private finishedSender: string = '';

  /** Called by the page in aboutToAppear; the service never holds a UI object. */
  attach(listener: (snapshot: ServiceSnapshot) => void): void {
    this.listener = listener;
    this.emit();
  }

  async open(context: common.UIAbilityContext): Promise<void> {
    if (this.prefs !== null) {
      return;
    }
    this.prefs = await AppPrefs.open(context);
    this.filesDir = context.filesDir;
    this.abilityContext = context;
    this.aliasText = this.prefs.alias();
    this.encryption = this.prefs.encryption();
    this.known = this.readKnown();
    this.quickSaveMode = this.prefs.quickSave();
    this.favs = this.readFavorites();
    this.historyEntries = this.readHistory();
    this.themeModeValue = this.prefs.themeMode();
    this.animationsValue = this.prefs.animations();
    this.autoFinishValue = this.prefs.autoFinish();
    this.saveToHistoryValue = this.prefs.saveToHistory();
    this.advancedValue = this.prefs.advanced();
    this.webAutoAcceptValue = this.prefs.webAutoAccept();
    this.applyColorMode();
    // Resolve the identity now so the UI can show a fingerprint before the server runs.
    this.identity = await new IdentityRepository(this.prefs).resolve(this.encryption, '');
    if (this.prefs.receiving()) {
      await this.startReceiving();
    }
    this.emit();
  }

  /** An empty alias means "use the system name"; prefs resolves the fallback. */
  async setAlias(alias: string): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    await this.prefs.setAlias(alias);
    this.aliasText = this.prefs.alias();
    this.emit();
  }

  alias(): string {
    return this.aliasText;
  }

  encryptionEnabled(): boolean {
    return this.encryption;
  }

  /** Changing the scheme needs a new identity and a new listener, so it restarts the service. */
  async setEncryption(enabled: boolean): Promise<void> {
    if (this.prefs === null || this.encryption === enabled) {
      return;
    }
    await this.prefs.setEncryption(enabled);
    this.encryption = enabled;
    const wasRunning: boolean = this.running;
    await this.shutdown();
    this.identity = await new IdentityRepository(this.prefs).resolve(enabled, '');
    if (wasRunning) {
      await this.startReceiving();
    } else {
      this.emit();
    }
  }

  async setReceiving(enabled: boolean): Promise<void> {
    if (this.prefs !== null) {
      await this.prefs.setReceiving(enabled);
    }
    if (enabled) {
      await this.startReceiving();
    } else {
      await this.shutdown();
    }
  }

  isRunning(): boolean {
    return this.running;
  }

  /** The page fires actions without awaiting them; a failure still has to reach the screen. */
  reportError(message: string): void {
    this.log(`错误: ${message}`);
    this.emit();
  }

  private async startReceiving(): Promise<void> {
    if (this.running || this.identity === null) {
      return;
    }
    const identity: Identity = this.identity;
    const sessions: SessionManager = new SessionManager(this.sessionConfig(identity));
    this.sessions = sessions;
    const discovery: Discovery = new Discovery({
      self: (): WireDeviceInfo => this.selfInfo(identity),
      port: DEFAULT_PORT,
      group: null,
      identity: (): Identity | null => this.identity,
      onPeersChanged: (peers: Peer[]): void => {
        this.log(`peers: ${peers.length}`);
        this.emit();
      },
      log: (message: string): void => this.log(message)
    });
    this.discovery = discovery;

    this.web = new WebShare(this.webConfig(identity));

    const routes: Map<string, RequestHandler> = sessions.routes();
    routes.set(ApiPath.REGISTER, discovery.registerHandler());
    routes.set(ApiPath.INFO, discovery.infoHandler());
    // The web surface is live as soon as the server is: an off share must answer its pages with 403
    // rather than let requests fall through as unknown paths.
    this.web.routes().forEach((handler: RequestHandler, path: string) => {
      routes.set(path, handler);
    });

    const tls: TlsMaterial | null = identity.isHttps
      ? {
        certPem: identity.certPem,
        keyPem: identity.keyPem,
        keyPassword: identity.keyPassword,
        // Verified on the emulator: once we *request* a client certificate, the HarmonyOS TLS
        // stack validates it against its trust store and answers `unknown ca` to LocalSend's
        // self-signed device certificates. The official client still connects when we do not
        // ask, so encryption works both ways — only the peer's proven fingerprint is lost.
        requestClientCertificate: false
      }
      : null;

    this.server = await HttpServer.start({
      port: DEFAULT_PORT,
      tls: tls,
      routes: routes,
      log: (message: string): void => this.log(message)
    });
    await discovery.start();
    this.running = true;
    // Announce once we are actually listening, so no peer is pointed at a closed port.
    discovery.setAnswerAnnouncements(true);
    discovery.announce();
    this.log(`receiving on :${DEFAULT_PORT} over ${identity.scheme}`);
    await this.startBackgroundTask();
    this.emit();
  }

  private async shutdown(): Promise<void> {
    await this.stopBackgroundTask();
    if (this.discovery !== null) {
      await this.discovery.stop();
      this.discovery = null;
    }
    if (this.server !== null) {
      await this.server.stop();
      this.server = null;
    }
    if (this.sessions !== null) {
      this.sessions.reset();
      this.sessions = null;
    }
    if (this.web !== null) {
      this.web.reset();
      this.web = null;
    }
    this.resolveOffer = null;
    this.offer = null;
    this.session = null;
    this.webOffer = null;
    this.resolveWebOffer = null;
    this.running = false;
    this.emit();
  }

  async close(): Promise<void> {
    await this.shutdown();
  }

  // ------------------------------------------------------------------ receive PIN

  /** The PIN a sender must present; empty means none. */
  receivePin(): string {
    if (this.prefs === null) {
      return '';
    }
    const pin: string | null = this.prefs.receivePin();
    return pin === null ? '' : pin;
  }

  /**
   * Sets or clears the receive PIN. The server reads it per request, so no restart is needed —
   * a sender mid-transfer keeps the session it already earned.
   */
  async setReceivePin(pin: string): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    await this.prefs.setReceivePin(pin.length === 0 ? null : pin);
    this.log(pin.length === 0 ? '接收 PIN 已关闭' : '接收 PIN 已开启');
    this.emit();
  }

  // ------------------------------------------------------------------ quick save

  /** 'off' | 'paired' (favorites only) | 'on'. */
  quickSave(): string {
    return this.quickSaveMode;
  }

  async setQuickSave(mode: string): Promise<void> {
    if (this.prefs === null || this.quickSaveMode === mode) {
      return;
    }
    this.quickSaveMode = mode;
    await this.prefs.setQuickSave(mode);
    if (mode === 'on') {
      this.log('自动保存已开启：将自动接受所有传输请求');
    } else if (mode === 'paired') {
      this.log('自动保存已开启（仅收藏夹）');
    } else {
      this.log('自动保存已关闭');
    }
    this.emit();
  }

  // ------------------------------------------------------------------- favorites

  favorites(): FavoriteRow[] {
    return this.favs.slice(0);
  }

  isFavorite(fingerprint: string): boolean {
    if (fingerprint.length === 0) {
      return false;
    }
    for (let i = 0; i < this.favs.length; i++) {
      if (this.favs[i].fingerprint === fingerprint) {
        return true;
      }
    }
    return false;
  }

  /** The star on a discovered device: adds, or removes when already starred. */
  async toggleFavorite(peer: PeerRow): Promise<void> {
    if (this.isFavorite(peer.fingerprint)) {
      await this.removeFavorite(peer.fingerprint);
      return;
    }
    const entry: FavoriteRow = {
      name: peer.name,
      host: peer.host,
      port: peer.port,
      fingerprint: peer.fingerprint
    };
    this.upsertFavorite(entry);
    await this.persistFavorites();
    this.log(`已收藏：${peer.name}`);
    this.emit();
  }

  /** A favorite typed in by hand: no fingerprint, so it is never part of quick save. */
  async addFavoriteManual(name: string, host: string, port: number): Promise<void> {
    if (name.length === 0 || host.length === 0 || port <= 0 || port > 65535) {
      this.reportError('请填写名称、IP 和端口');
      return;
    }
    const entry: FavoriteRow = { name: name, host: host, port: port, fingerprint: '' };
    this.upsertFavorite(entry);
    await this.persistFavorites();
    this.log(`已添加收藏：${name}`);
    this.emit();
  }

  /** Removal is keyed by fingerprint, or `host:port` for manual entries. */
  async removeFavorite(key: string): Promise<void> {
    const kept: FavoriteRow[] = [];
    for (let i = 0; i < this.favs.length; i++) {
      if (favoriteKey(this.favs[i]) !== key) {
        kept.push(this.favs[i]);
      }
    }
    this.favs = kept;
    await this.persistFavorites();
    this.log('已移除收藏');
    this.emit();
  }

  private upsertFavorite(entry: FavoriteRow): void {
    const key: string = favoriteKey(entry);
    for (let i = 0; i < this.favs.length; i++) {
      if (favoriteKey(this.favs[i]) === key) {
        this.favs[i] = entry;
        return;
      }
    }
    this.favs.push(entry);
  }

  private readFavorites(): FavoriteRow[] {
    const json: string = this.prefs === null ? '' : this.prefs.favoritesJson();
    if (json.length === 0) {
      return [];
    }
    try {
      const parsed: FavoriteRow[] = JSON.parse(json) as FavoriteRow[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      this.log(`收藏夹读取失败: ${describeFailure(e)}`);
      return [];
    }
  }

  private persistFavorites(): Promise<void> {
    if (this.prefs === null) {
      return Promise.resolve();
    }
    return this.prefs.setFavoritesJson(JSON.stringify(this.favs));
  }

  // --------------------------------------------------------------------- history

  clearHistory(): void {
    this.historyEntries = [];
    this.persistHistory();
    this.log('历史记录已清空');
    this.emit();
  }

  removeHistoryEntry(id: string): void {
    const kept: HistoryRow[] = [];
    for (let i = 0; i < this.historyEntries.length; i++) {
      if (this.historyEntries[i].id !== id) {
        kept.push(this.historyEntries[i]);
      }
    }
    this.historyEntries = kept;
    this.persistHistory();
    this.emit();
  }

  /** Called when a session ends; newest first and capped, the setting decides whether at all. */
  private recordHistory(session: ReceiveSession, rows: ReceivedRow[]): void {
    if (!this.saveToHistoryValue) {
      return;
    }
    for (let i = 0; i < rows.length; i++) {
      const row: ReceivedRow = rows[i];
      const entry: HistoryRow = {
        id: `${session.sessionId}:${row.id}`,
        name: row.name,
        size: row.size,
        fileType: row.fileType,
        path: row.path,
        sender: session.senderAlias,
        timeMs: Date.now(),
        saved: row.saved
      };
      this.historyEntries.unshift(entry);
    }
    if (this.historyEntries.length > 200) {
      this.historyEntries.splice(200, this.historyEntries.length - 200);
    }
    this.persistHistory();
  }

  /** A successful export marks every row and history line that points at that file. */
  private markSaved(path: string): void {
    for (let i = 0; i < this.received.length; i++) {
      if (this.received[i].path === path) {
        this.received[i].saved = true;
      }
    }
    for (let i = 0; i < this.historyEntries.length; i++) {
      if (this.historyEntries[i].path === path) {
        this.historyEntries[i].saved = true;
      }
    }
    this.persistHistory();
  }

  private readHistory(): HistoryRow[] {
    const json: string = this.prefs === null ? '' : this.prefs.historyJson();
    if (json.length === 0) {
      return [];
    }
    try {
      const parsed: HistoryRow[] = JSON.parse(json) as HistoryRow[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      this.log(`历史记录读取失败: ${describeFailure(e)}`);
      return [];
    }
  }

  private persistHistory(): void {
    if (this.prefs === null) {
      return;
    }
    this.prefs.setHistoryJson(JSON.stringify(this.historyEntries)).catch((error: Object): void => {
      this.log(`历史记录写入失败: ${describeFailure(error)}`);
    });
  }

  // ----------------------------------------------------------- display settings

  /** The dark palette lives in resources/dark, so following the system is a color-mode switch. */
  private applyColorMode(): void {
    const context: common.UIAbilityContext | null = this.abilityContext;
    if (context === null) {
      return;
    }
    if (this.themeModeValue === 'dark') {
      context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } else if (this.themeModeValue === 'light') {
      context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } else {
      context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    }
  }

  async setThemeMode(mode: string): Promise<void> {
    if (this.prefs === null || this.themeModeValue === mode) {
      return;
    }
    this.themeModeValue = mode;
    await this.prefs.setThemeMode(mode);
    this.applyColorMode();
    this.emit();
  }

  async setAnimations(enabled: boolean): Promise<void> {
    if (this.prefs === null || this.animationsValue === enabled) {
      return;
    }
    this.animationsValue = enabled;
    await this.prefs.setAnimations(enabled);
    this.emit();
  }

  async setAutoFinish(enabled: boolean): Promise<void> {
    if (this.prefs === null || this.autoFinishValue === enabled) {
      return;
    }
    this.autoFinishValue = enabled;
    await this.prefs.setAutoFinish(enabled);
    if (enabled) {
      this.finishedRows = [];
      this.finishedSender = '';
    }
    this.emit();
  }

  async setSaveToHistory(enabled: boolean): Promise<void> {
    if (this.prefs === null || this.saveToHistoryValue === enabled) {
      return;
    }
    this.saveToHistoryValue = enabled;
    await this.prefs.setSaveToHistory(enabled);
    this.emit();
  }

  async setAdvanced(enabled: boolean): Promise<void> {
    if (this.prefs === null || this.advancedValue === enabled) {
      return;
    }
    this.advancedValue = enabled;
    await this.prefs.setAdvanced(enabled);
    this.emit();
  }

  async setWebAutoAccept(enabled: boolean): Promise<void> {
    if (this.prefs === null || this.webAutoAcceptValue === enabled) {
      return;
    }
    this.webAutoAcceptValue = enabled;
    await this.prefs.setWebAutoAccept(enabled);
    this.log(enabled ? '网页分享已设为自动同意请求' : '网页分享恢复为逐个确认');
    this.emit();
  }

  /** The finished-transfer card only stays when autoFinish is off; this is its 完成 button. */
  dismissFinished(): void {
    this.finishedRows = [];
    this.finishedSender = '';
    this.emit();
  }

  /** The 重启 button: a fresh listener with the current identity and settings. */
  async restart(): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    const wasRunning: boolean = this.running;
    await this.shutdown();
    if (wasRunning) {
      await this.startReceiving();
      this.log('服务器已重启');
    }
    this.emit();
  }

  /** Every local IPv4 address; the receive page derives the official '#<last octet>' from them. */
  localIps(): string[] {
    const discovery: Discovery | null = this.discovery;
    if (discovery === null) {
      return [];
    }
    const interfaces: LocalInterface[] = discovery.localInterfaces();
    const ips: string[] = [];
    for (let i = 0; i < interfaces.length; i++) {
      const address: string = interfaces[i].address;
      if (address.indexOf(':') >= 0 || address.length === 0) {
        continue;
      }
      if (ips.indexOf(address) < 0) {
        ips.push(address);
      }
    }
    return ips;
  }

  /** Drops every staged pick — nothing stopped the sender between 清空 and 开始发送 anyway. */
  removePicked(uri: string): void {
    const kept: PickedItem[] = [];
    for (let i = 0; i < this.picked.length; i++) {
      if (this.picked[i].uri !== uri) {
        kept.push(this.picked[i]);
      }
    }
    this.picked = kept;
    this.emit();
  }

  /**
   * Stages typed or pasted text as a file the send engine can read, so clipboard and text sends
   * take the same path through the Sender as picks from the system dialogs.
   */
  stageText(text: string, name: string): void {
    const context: common.UIAbilityContext | null = this.abilityContext;
    if (context === null) {
      return;
    }
    const path: string = `${context.cacheDir}/${name}`;
    try {
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        fs.closeSync(file);
      }
      this.addPicked([path]);
      this.log(`已加入文本文件：${name}`);
    } catch (error) {
      this.log(`文本暂存失败: ${describeFailure(error)}`);
      this.emit();
    }
  }

  // ------------------------------------------------------------ background running

  /**
   * Holds a `dataTransfer` background task while receiving, so a transfer survives the app going to
   * the background — which on this platform it otherwise does not.
   *
   * The mode is declared in module.json5; on a device or emulator that refuses the request the app
   * keeps receiving while foregrounded, so the failure is logged rather than raised.
   */
  private async startBackgroundTask(): Promise<void> {
    const context: common.UIAbilityContext | null = this.abilityContext;
    if (context === null || this.backgroundRunning) {
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: 'io.github.localsendnext.app', abilityName: 'EntryAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 101,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      this.backgroundRunning = true;
      this.log('后台任务已开启，退到后台仍可接收');
    } catch (e) {
      this.log(`后台任务开启失败，退到后台可能暂停接收: ${describeFailure(e)}`);
    }
  }

  private async stopBackgroundTask(): Promise<void> {
    const context: common.UIAbilityContext | null = this.abilityContext;
    if (context === null || !this.backgroundRunning) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      this.log('后台任务已停止');
    } catch (e) {
      this.log(`后台任务停止失败: ${describeFailure(e)}`);
    }
    this.backgroundRunning = false;
  }

  /** Discovery with no multicast: probe the addresses the user or a previous run knows. */
  /**
   * Adds `[scheme://]host[:port]` to the saved leads. Without multicast these are the only
   * addresses discovery has to work from, so they persist across launches.
   */
  async addKnownHost(spec: string): Promise<void> {
    const channel: KnownChannel | null = parseHostSpec(spec);
    if (channel === null) {
      this.reportError(`无法识别的地址: ${spec}`);
      return;
    }
    for (let i = 0; i < this.known.length; i++) {
      if (sameHost(this.known[i], channel)) {
        return;
      }
    }
    this.known.push(channel);
    await this.persistKnown();
    this.emit();
  }

  async refresh(): Promise<void> {
    if (this.discovery === null) {
      this.log('接收未开启，无法发现设备');
      return;
    }
    await this.discovery.discoverStaged(this.known);
    this.emit();
  }

  private readKnown(): KnownChannel[] {
    const channels: KnownChannel[] = [];
    if (this.prefs === null) {
      return channels;
    }
    const specs: string[] = this.prefs.knownHosts();
    for (let i = 0; i < specs.length; i++) {
      const channel: KnownChannel | null = parseHostSpec(specs[i]);
      if (channel !== null) {
        channels.push(channel);
      }
    }
    return channels;
  }

  private async persistKnown(): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    const specs: string[] = [];
    for (let i = 0; i < this.known.length; i++) {
      specs.push(formatHostSpec(this.known[i]));
    }
    await this.prefs.setKnownHosts(specs);
  }

  peers(): Peer[] {
    return this.discovery === null ? [] : this.discovery.peers.list();
  }

  // ------------------------------------------------------------------- sending

  /**
   * Stages the uris the system picker returned — a document uri, a media uri or a sandbox path, all
   * of which `fileIo.open` accepts unchanged.
   *
   * Picks accumulate because the phone's document picker returns one file per invocation: a folder
   * transfer is built by tapping 文件 several times, so a second pick must not discard the first.
   */
  addPicked(uris: string[]): void {
    for (let i = 0; i < uris.length; i++) {
      const uri: string = uris[i];
      if (this.hasPicked(uri)) {
        continue;
      }
      const item: PickedItem = new PickedItem();
      item.uri = uri;
      item.name = displayNameOf(uri);
      item.size = sizeOf(uri);
      this.picked.push(item);
    }
    this.emit();
  }

  private hasPicked(uri: string): boolean {
    for (let i = 0; i < this.picked.length; i++) {
      if (this.picked[i].uri === uri) {
        return true;
      }
    }
    return false;
  }

  clearPicked(): void {
    this.picked = [];
    this.emit();
  }

  /**
   * Sends the staged selection to one peer. The engine runs on its own and reports through
   * `onChanged`, so a folder transfer never blocks the tap handler that started it.
   */
  startSend(fingerprint: string, pin: string): void {
    const peer: Peer | null = this.discovery === null ? null : this.discovery.peers.get(fingerprint);
    if (peer === null) {
      this.reportError('该设备已不在列表中，请重新发现');
      return;
    }
    if (this.picked.length === 0) {
      this.reportError('还没有选择文件');
      return;
    }
    const identity: Identity | null = this.identity;
    if (identity === null) {
      this.reportError('设备标识尚未就绪');
      return;
    }
    const sources: SendSource[] = [];
    for (let i = 0; i < this.picked.length; i++) {
      sources.push({ uri: this.picked[i].uri, fileName: this.picked[i].name });
    }
    const target: SendTarget = {
      host: peer.host,
      port: peer.port,
      scheme: peer.protocol,
      alias: peer.alias,
      fingerprint: peer.fingerprint
    };
    const sender: Sender = this.sender === null ? new Sender(this.senderConfig(identity)) : this.sender;
    this.sender = sender;
    sender.start(target, sources, pin.length > 0 ? pin : null);
    this.emit();
  }

  cancelSend(): void {
    if (this.sender !== null) {
      this.sender.cancel();
    }
    this.emit();
  }

  private senderConfig(identity: Identity): SenderConfig {
    const credentials: ClientCredentials | null = identity.isHttps
      ? { certPem: identity.certPem, keyPem: identity.keyPem, keyPassword: identity.keyPassword }
      : null;
    const config: SenderConfig = {
      self: (): WireDeviceInfo => this.selfInfo(identity),
      credentials: (): ClientCredentials | null => credentials,
      onChanged: (): void => this.emit(),
      log: (message: string): void => this.log(message)
    };
    return config;
  }

  private sendRows(): FileRow[] {
    const task: SendTask | null = this.sender === null ? null : this.sender.current();
    const rows: FileRow[] = [];
    if (task === null) {
      return rows;
    }
    for (let i = 0; i < task.files.length; i++) {
      const file: SendFile = task.files[i];
      const row: FileRow = new FileRow();
      row.id = file.fileId;
      row.name = file.fileName;
      row.size = file.size;
      row.received = file.sent;
      row.status = file.status;
      rows.push(row);
    }
    return rows;
  }

  private pickedRows(): FileRow[] {
    const rows: FileRow[] = [];
    for (let i = 0; i < this.picked.length; i++) {
      const item: PickedItem = this.picked[i];
      const row: FileRow = new FileRow();
      // The uri is the id so the page can hand a row straight back to removePicked.
      row.id = item.uri;
      row.name = item.name;
      row.size = item.size;
      row.status = 'queued';
      rows.push(row);
    }
    return rows;
  }

  private sendErrorText(): string {
    const task: SendTask | null = this.sender === null ? null : this.sender.current();
    if (task === null) {
      return '';
    }
    if (task.error.length > 0) {
      return task.error;
    }
    // The task-level error stays empty when a single file failed; surface that one instead.
    for (let i = 0; i < task.files.length; i++) {
      if (task.files[i].status === SendFileStatus.FAILED) {
        return `${task.files[i].fileName}: ${task.files[i].error}`;
      }
    }
    return '';
  }

  // ------------------------------------------------------------ web share (Download API)

  /** One switch for the page: a running share stops, anything else starts one from the picks. */
  async toggleWebShare(): Promise<void> {
    if (this.web !== null && this.web.isSharing()) {
      this.stopWebShare();
      return;
    }
    await this.startWebShare();
  }

  /**
   * Offers the staged selection to browsers.
   *
   * A share is only meaningful while the server listens, so starting one from a stopped app turns
   * receiving on first rather than making the user flip two switches in a row.
   */
  async startWebShare(): Promise<void> {
    if (this.picked.length === 0) {
      this.reportError('还没有选择文件');
      return;
    }
    if (!this.running) {
      await this.setReceiving(true);
    }
    const web: WebShare | null = this.web;
    if (web === null) {
      this.reportError('接收未能开启，无法网页分享');
      return;
    }
    const sources: SendSource[] = [];
    for (let i = 0; i < this.picked.length; i++) {
      sources.push({ uri: this.picked[i].uri, fileName: this.picked[i].name });
    }
    const count: number = await web.share(sources);
    if (count === 0) {
      this.reportError('选中的文件都读取不到');
      return;
    }
    this.announceWebState();
    this.emit();
  }

  /**
   * The other half of the page at `/`: browsers upload files to this phone through the normal upload
   * API, which means the user still confirms each offer.
   */
  async toggleWebUpload(): Promise<void> {
    const web: WebShare | null = this.web;
    if (web !== null && web.isUploading()) {
      this.stopWebShare();
      return;
    }
    if (!this.running) {
      await this.setReceiving(true);
    }
    const ready: WebShare | null = this.web;
    if (ready === null) {
      this.reportError('接收未能开启，无法网页收取');
      return;
    }
    ready.acceptBrowserUploads();
    this.announceWebState();
    this.emit();
  }

  stopWebShare(): void {
    const web: WebShare | null = this.web;
    if (web !== null) {
      web.stop();
    }
    this.announceWebState();
    this.emit();
  }

  /** Peers cache our announcement, so a mode change only reaches them once we re-announce. */
  private announceWebState(): void {
    if (this.discovery !== null && this.running) {
      this.discovery.announce();
    }
  }

  private webConfig(identity: Identity): WebShareConfig {
    const config: WebShareConfig = {
      self: (): WireDeviceInfo => this.selfInfo(identity),
      // The download page's own PIN stays off: what guards it is the per-browser dialog. Browser
      // uploads, which pass through the receive API, are the ones gated by the receive PIN.
      pin: (): string | null => null,
      decide: (context: WebOfferContext): Promise<boolean> => this.askWebVisitor(context),
      // A browser that hangs up leaves the sheet standing over a request nobody can serve anymore.
      onOfferClosed: (clientIp: string): void => {
        const pending: WebOfferContext | null = this.webOffer;
        if (pending !== null && pending.clientIp === clientIp) {
          this.webOffer = null;
          this.resolveWebOffer = null;
          this.emit();
        }
      },
      onChanged: (): void => this.emit(),
      log: (message: string): void => this.log(message)
    };
    return config;
  }

  private askWebVisitor(context: WebOfferContext): Promise<boolean> {
    if (this.webAutoAcceptValue) {
      this.log(`自动同意浏览器 (${context.clientIp}) 的下载请求`);
      return Promise.resolve(true);
    }
    this.webOffer = context;
    this.emit();
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      this.resolveWebOffer = resolve;
    });
  }

  allowWebVisitor(): void {
    this.answerWebOffer(true);
  }

  denyWebVisitor(): void {
    this.answerWebOffer(false);
  }

  /** The browser may already have hung up; resolving anyway is harmless and frees the waiting slot. */
  private answerWebOffer(accepted: boolean): void {
    const resolve: ((accepted: boolean) => void) | null = this.resolveWebOffer;
    if (resolve === null) {
      return;
    }
    this.resolveWebOffer = null;
    this.webOffer = null;
    resolve(accepted);
    this.emit();
  }

  private webRows(): FileRow[] {
    const rows: FileRow[] = [];
    const web: WebShare | null = this.web;
    if (web === null) {
      return rows;
    }
    const files: WebOfferFile[] = web.offered();
    for (let i = 0; i < files.length; i++) {
      const file: WebOfferFile = files[i];
      const row: FileRow = new FileRow();
      row.id = file.fileId;
      row.name = file.fileName;
      row.size = file.size;
      row.received = file.downloaded;
      if (file.size > 0 && file.downloaded >= file.size) {
        row.status = 'done';
      } else if (file.downloaded > 0) {
        row.status = 'partial';
      } else {
        row.status = 'idle';
      }
      rows.push(row);
    }
    return rows;
  }

  /** Where a browser on the same network opens the share: one address per live interface. */
  private webLinks(): string[] {
    const links: string[] = [];
    const discovery: Discovery | null = this.discovery;
    if (discovery === null) {
      return links;
    }
    const scheme: string = this.identity === null || !this.identity.isHttps
      ? ProtocolScheme.HTTP : ProtocolScheme.HTTPS;
    const interfaces: LocalInterface[] = discovery.localInterfaces();
    for (let i = 0; i < interfaces.length; i++) {
      links.push(`${scheme}://${interfaces[i].address}:${DEFAULT_PORT}/`);
    }
    return links;
  }

  // ------------------------------------------------------------- user answers

  acceptOffer(fileIds: string[]): void {
    const resolve: ((decision: PrepareDecision) => void) | null = this.resolveOffer;
    if (resolve === null) {
      return;
    }
    this.resolveOffer = null;
    this.offer = null;
    resolve({ declined: false, acceptedFileIds: fileIds });
    this.emit();
  }

  declineOffer(): void {
    const resolve: ((decision: PrepareDecision) => void) | null = this.resolveOffer;
    if (resolve === null) {
      return;
    }
    this.resolveOffer = null;
    this.offer = null;
    resolve({ declined: true, acceptedFileIds: [] });
    this.emit();
  }

  stopSession(): void {
    if (this.sessions === null) {
      return;
    }
    this.sessions.cancelActiveLocally();
    this.emit();
  }

  /**
   * Files of a finished session that still only exist in the sandbox. They are kept until the next
   * session takes their place, because handing them out of the sandbox is a separate, user-driven
   * step: the gallery dialog or the document picker.
   */
  private collectReceived(session: ReceiveSession): void {
    const rows: ReceivedRow[] = [];
    session.files.forEach((file: ReceivedFile) => {
      if (file.status !== FileStatus.FINISHED) {
        return;
      }
      const row: ReceivedRow = new ReceivedRow();
      row.id = file.fileId;
      row.name = file.fileName;
      row.size = file.size;
      row.received = file.receivedBytes;
      row.status = file.status;
      row.path = file.path;
      row.fileType = file.fileType;
      rows.push(row);
    });
    if (rows.length > 0) {
      this.received = rows;
      this.recordHistory(session, rows);
    }
  }

  /** autoFinish off keeps a finished transfer on screen until 完成; everything else clears it. */
  private collectFinished(session: ReceiveSession, reason: SessionEndReason): void {
    if (this.autoFinishValue || reason !== SessionEndReason.FINISHED) {
      this.finishedRows = [];
      this.finishedSender = '';
      return;
    }
    const rows: FileRow[] = [];
    session.files.forEach((file: ReceivedFile) => {
      const row: FileRow = new FileRow();
      row.id = file.fileId;
      row.name = file.fileName;
      row.size = file.size;
      row.received = file.receivedBytes;
      row.status = file.status;
      rows.push(row);
    });
    this.finishedRows = rows;
    this.finishedSender = session.senderAlias;
  }

  /**
   * Hands one received file to the system. Media goes through the photo picker's creation dialog —
   * the only way into the gallery without holding a restricted write permission — and everything
   * else through the document picker, which asks the user for a destination folder.
   */
  async saveReceived(fileId: string): Promise<void> {
    let row: ReceivedRow | null = null;
    for (let i = 0; i < this.received.length; i++) {
      const candidate: ReceivedRow = this.received[i];
      if (candidate.id === fileId && !candidate.saved) {
        row = candidate;
      }
    }
    if (row === null) {
      return;
    }
    const target: ReceivedRow = row;
    await this.runSave(fileId, target, (): void => {
      target.saved = true;
      this.markSaved(target.path);
    });
  }

  /** The same flow for a history line, whose file can outlive the received list on screen. */
  async saveHistoryEntry(id: string): Promise<void> {
    let entry: HistoryRow | null = null;
    for (let i = 0; i < this.historyEntries.length; i++) {
      const candidate: HistoryRow = this.historyEntries[i];
      if (candidate.id === id && !candidate.saved) {
        entry = candidate;
      }
    }
    if (entry === null) {
      return;
    }
    const target: HistoryRow = entry;
    await this.runSave(id, target, (): void => {
      target.saved = true;
      this.markSaved(target.path);
    });
  }

  private async runSave(id: string, target: SaveTarget, onSaved: () => void): Promise<void> {
    if (this.savingId !== '') {
      return;
    }
    this.savingId = id;
    this.emit();
    try {
      if (target.fileType.startsWith('image/') || target.fileType.startsWith('video/')) {
        await this.saveToGallery(target, onSaved);
      } else {
        await this.saveToDocuments(target, onSaved);
      }
    } catch (e) {
      this.log(`保存失败: ${describeFailure(e)}`);
    }
    this.savingId = '';
    this.emit();
  }

  private async saveToGallery(target: SaveTarget, onSaved: () => void): Promise<void> {
    const context: common.UIAbilityContext | null = this.abilityContext;
    if (context === null) {
      return;
    }
    const video: boolean = target.fileType.startsWith('video/');
    const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
    const config: photoAccessHelper.PhotoCreationConfig = {
      title: target.name,
      fileNameExtension: extensionOf(target.name, video ? 'mp4' : 'jpg'),
      photoType: video ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE
    };
    const sources: string[] = [fileUri.getUriFromPath(target.path)];
    const work: Promise<string[]> = helper.showAssetsCreationDialog(sources, [config]);
    const created: string[] | null = await withDeadline(work, GALLERY_TIMEOUT_MS);
    if (created === null) {
      this.log(`存入相册超时: ${target.name}`);
      work.then((late: string[]): void => {
        this.finishGallerySave(target, onSaved, late);
      }).catch((error: Object): void => {
        this.log(`保存失败: ${describeFailure(error)}`);
      });
      return;
    }
    this.finishGallerySave(target, onSaved, created);
  }

  private finishGallerySave(target: SaveTarget, onSaved: () => void, created: string[]): void {
    if (created.length === 0) {
      this.log(`存入相册已取消: ${target.name}`);
      return;
    }
    onSaved();
    this.log(`已存入相册: ${target.name}`);
    this.emit();
  }

  private async saveToDocuments(target: SaveTarget, onSaved: () => void): Promise<void> {
    const context: common.UIAbilityContext | null = this.abilityContext;
    if (context === null) {
      return;
    }
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [target.name];
    const instance: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const work: Promise<string[]> = instance.save(options);
    const picked: string[] | null = await withDeadline(work, DOCUMENT_TIMEOUT_MS);
    if (picked === null) {
      this.log(`保存超时: ${target.name}`);
      // The file manager creates the destination as an empty file and only then answers us, so
      // giving up here would leave 0 bytes behind. Finish the copy whenever it does answer.
      work.then((late: string[]): void => {
        this.finishDocumentSave(target, onSaved, late);
      }).catch((error: Object): void => {
        this.log(`保存失败: ${target.name}: ${describeFailure(error)}`);
      });
      return;
    }
    this.finishDocumentSave(target, onSaved, picked);
  }

  private finishDocumentSave(target: SaveTarget, onSaved: () => void, picked: string[]): void {
    if (picked.length === 0) {
      this.log(`保存已取消: ${target.name}`);
      return;
    }
    try {
      const destination: fs.File = fs.openSync(picked[0],
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.copyFileSync(target.path, destination.fd);
      } finally {
        fs.closeSync(destination);
      }
      onSaved();
      this.log(`已保存: ${target.name}`);
      this.emit();
    } catch (error) {
      this.log(`保存失败: ${target.name}: ${describeFailure(error)}`);
    }
  }

  /**
   * Hands a sandbox file to whatever app registered for that type. There is no guarantee anything
   * will take it — the emulator ships almost no viewers — so a failure is a log line, not a crash.
   */
  openFile(path: string, fileType: string): void {
    const context: common.UIAbilityContext | null = this.abilityContext;
    if (context === null) {
      return;
    }
    try {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: fileUri.getUriFromPath(path),
        type: fileType.length > 0 ? fileType : 'application/octet-stream',
        // The file lives in our sandbox, so the viewer needs an explicit one-shot read grant.
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      };
      context.startAbility(want).then((): void => {
        this.log(`已请求打开: ${path}`);
      }).catch((error: Object): void => {
        this.log(`没有应用能打开该文件: ${describeFailure(error)}`);
      });
    } catch (e) {
      this.log(`打开失败: ${describeFailure(e)}`);
    }
  }

  /** 打开目录: shows the receive folder in the system file manager, like the official app. */
  openFolder(): void {
    const path: string = `${this.filesDir}${RECEIVE_SUBDIR}`;
    this.openFile(path, '');
  }

  /** 在文件管理器中显示: opens the folder that holds the file. */
  openFolderOf(path: string): void {
    const slash: number = path.lastIndexOf('/');
    this.openFile(slash <= 0 ? path : path.substring(0, slash), '');
  }

  /** For 关于/捐赠/隐私政策: openLink routes https to the browser without an explicit want. */
  openExternalUrl(url: string): void {
    const context: common.UIAbilityContext | null = this.abilityContext;
    if (context === null) {
      return;
    }
    try {
      context.openLink(url).then((): void => {
        this.log(`已在浏览器打开: ${url}`);
      }).catch((error: Object): void => {
        this.log(`链接打开失败: ${describeFailure(error)}`);
      });
    } catch (e) {
      this.log(`链接打开失败: ${describeFailure(e)}`);
    }
  }

  /** Used by the emulator test: a peer that never appears in discovery is added by hand. */
  private selfInfo(identity: Identity): WireDeviceInfo {
    const info: WireDeviceInfo = {
      alias: this.aliasText,
      version: PROTOCOL_VERSION,
      deviceModel: 'HarmonyOS',
      deviceType: DeviceTypeValue.MOBILE,
      fingerprint: identity.fingerprint,
      port: DEFAULT_PORT,
      protocol: identity.isHttps ? ProtocolScheme.HTTPS : ProtocolScheme.HTTP,
      // `download` means "the browser download page is live": only download mode advertises it,
      // because the pages the flag invites a browser to are exclusive.
      download: this.web !== null && this.web.isDownloading()
    };
    return info;
  }

  private sessionConfig(identity: Identity): SessionManagerConfig {
    const config: SessionManagerConfig = {
      selfFingerprint: (): string => identity.fingerprint,
      // Read per request, so a PIN the user sets later applies to the next sender without a restart.
      pin: (): string | null => {
        const pin: string = this.receivePin();
        return pin.length === 0 ? null : pin;
      },
      destination: async (context: DestinationContext): Promise<string | null> => {
        this.log(`incoming ${context.fileCount} file(s), ${context.totalBytes} byte(s) `
          + `from ${context.info.alias} (${context.senderIp})`);
        return this.filesDir + RECEIVE_SUBDIR;
      },
      decide: (context: PrepareContext): Promise<PrepareDecision> => this.askUser(context),
      verifyChecksums: (): boolean => true,
      onSessionCreated: (session: ReceiveSession): void => {
        this.session = session;
        this.emit();
      },
      onSessionEnded: (session: ReceiveSession, reason: SessionEndReason): void => {
        this.log(`session ${session.sessionId} ended: ${reason}`);
        this.session = null;
        this.collectReceived(session);
        this.collectFinished(session, reason);
        this.emit();
      },
      onFileUpdated: (session: ReceiveSession, file: ReceivedFile): void => {
        this.session = session;
        this.emit();
      },
      onProgress: (event: FileProgressEvent): void => {
        this.emit();
      },
      onPrepareAborted: (sessionId: string): void => {
        this.log(`offer ${sessionId} withdrawn by the sender`);
        this.resolveOffer = null;
        this.offer = null;
        this.emit();
      },
      onCancelReceived: (senderIp: string, sessionId: string): void => {
        this.log(`cancel from ${senderIp} for session ${sessionId}`);
      },
      log: (message: string): void => this.log(message)
    };
    return config;
  }

  private askUser(context: PrepareContext): Promise<PrepareDecision> {
    if (this.quickSaveMode === 'on'
      || (this.quickSaveMode === 'paired' && this.isFavorite(context.senderFingerprint))) {
      const ids: string[] = [];
      for (let i = 0; i < context.candidates.length; i++) {
        ids.push(context.candidates[i].fileId);
      }
      this.log(`自动保存：接受来自 ${context.info.alias} 的 ${ids.length} 个文件`);
      const decision: PrepareDecision = { declined: false, acceptedFileIds: ids };
      return Promise.resolve(decision);
    }
    this.offer = context;
    this.emit();
    return new Promise<PrepareDecision>((resolve: (value: PrepareDecision) => void) => {
      this.resolveOffer = resolve;
    });
  }

  // ------------------------------------------------------------------ snapshot

  private log(message: string): void {
    // The on-screen console is not enough once the app is out of sight: the same lines have to
    // be reachable from `hdc shell hilog` while debugging a transfer.
    hilog.info(0x0000, TAG, '%{public}s', message);
    this.logLines.push(message);
    if (this.logLines.length > 120) {
      this.logLines.splice(0, this.logLines.length - 120);
    }
  }

  private rowsOf(files: ReceivedFile[]): FileRow[] {
    const rows: FileRow[] = [];
    for (let i = 0; i < files.length; i++) {
      const file: ReceivedFile = files[i];
      const row: FileRow = new FileRow();
      row.id = file.fileId;
      row.name = file.fileName;
      row.size = file.size;
      row.received = file.receivedBytes;
      row.status = file.status;
      rows.push(row);
    }
    return rows;
  }

  private sessionFiles(): FileRow[] {
    const session: ReceiveSession | null = this.session;
    if (session === null) {
      return [];
    }
    const list: ReceivedFile[] = [];
    session.files.forEach((file: ReceivedFile) => {
      list.push(file);
    });
    return this.rowsOf(list);
  }

  private offerFiles(): FileRow[] {
    const offer: PrepareContext | null = this.offer;
    if (offer === null) {
      return [];
    }
    const rows: FileRow[] = [];
    for (let i = 0; i < offer.candidates.length; i++) {
      const row: FileRow = new FileRow();
      row.id = offer.candidates[i].fileId;
      row.name = offer.candidates[i].fileName;
      row.size = offer.candidates[i].size;
      row.status = FileStatus.PENDING;
      rows.push(row);
    }
    return rows;
  }

  private peerRows(): PeerRow[] {
    const peers: Peer[] = this.peers();
    const rows: PeerRow[] = [];
    for (let i = 0; i < peers.length; i++) {
      const row: PeerRow = new PeerRow();
      row.name = peers[i].alias;
      row.host = peers[i].host;
      row.port = peers[i].port;
      row.scheme = peers[i].protocol;
      row.download = peers[i].download;
      row.fingerprint = peers[i].fingerprint;
      row.model = peers[i].deviceModel;
      row.deviceType = peers[i].deviceType;
      rows.push(row);
    }
    return rows;
  }

  private emit(): void {
    const listener: ((snapshot: ServiceSnapshot) => void) | null = this.listener;
    if (listener === null) {
      return;
    }
    const offer: PrepareContext | null = this.offer;
    const snapshot: ServiceSnapshot = new ServiceSnapshot();
    snapshot.running = this.running;
    snapshot.alias = this.aliasText;
    snapshot.fingerprint = this.identity === null ? '' : this.identity.fingerprint;
    snapshot.scheme = this.identity === null ? ProtocolScheme.HTTP : this.identity.scheme;
    snapshot.port = DEFAULT_PORT;
    snapshot.multicast = this.discovery !== null && this.discovery.hasMulticast();
    snapshot.encryption = this.encryption;
    snapshot.peers = this.peerRows();
    snapshot.hasOffer = offer !== null;
    snapshot.offerSender = offer === null ? '' : `${offer.info.alias} (${offer.senderIp})`;
    snapshot.offerDestination = offer === null ? '' : offer.destination;
    snapshot.offerFiles = this.offerFiles();
    snapshot.hasSession = this.session !== null;
    snapshot.sessionSender = this.session === null ? '' : this.session.senderAlias;
    snapshot.sessionFiles = this.sessionFiles();
    // A fresh array each time: ArkUI's ForEach only re-diffs when the array it was handed changes.
    snapshot.lastReceived = this.received.slice(0);
    snapshot.savingId = this.savingId;
    const specs: string[] = [];
    for (let i = 0; i < this.known.length; i++) {
      specs.push(formatHostSpec(this.known[i]));
    }
    snapshot.hosts = specs;
    const sendTask: SendTask | null = this.sender === null ? null : this.sender.current();
    snapshot.picked = this.pickedRows();
    snapshot.sendActive = sendTask !== null && !sendTask.isFinished();
    snapshot.sendPeer = sendTask === null ? '' : `${sendTask.peerAlias} (${sendTask.target.host})`;
    snapshot.sendState = sendTask === null ? '' : sendTask.status;
    snapshot.sendFiles = this.sendRows();
    snapshot.sendTotal = sendTask === null ? 0 : sendTask.totalBytes();
    snapshot.sendSent = sendTask === null ? 0 : sendTask.sentBytes();
    snapshot.sendError = this.sendErrorText();
    const web: WebShare | null = this.web;
    const webOffer: WebOfferContext | null = this.webOffer;
    snapshot.webSharing = web !== null && web.isSharing();
    snapshot.webUploading = web !== null && web.isUploading();
    snapshot.receivePin = this.receivePin();
    snapshot.webFiles = this.webRows();
    snapshot.webTotal = web === null ? 0 : web.totalOffered();
    snapshot.webSent = web === null ? 0 : web.transferred();
    snapshot.webClients = web === null ? 0 : web.acceptedClients();
    snapshot.webUrls = this.webLinks();
    snapshot.hasWebOffer = webOffer !== null;
    snapshot.webOfferClient = webOffer === null ? '' : webOffer.clientIp;
    snapshot.webOfferAgent = webOffer === null ? '' : webOffer.userAgent;
    snapshot.webOfferFiles = webOffer === null ? 0 : webOffer.fileCount;
    snapshot.webOfferBytes = webOffer === null ? 0 : webOffer.totalBytes;
    snapshot.quickSave = this.quickSaveMode;
    snapshot.favorites = this.favorites();
    snapshot.history = this.historyEntries.slice(0);
    snapshot.themeMode = this.themeModeValue;
    snapshot.animations = this.animationsValue;
    snapshot.autoFinish = this.autoFinishValue;
    snapshot.saveToHistory = this.saveToHistoryValue;
    snapshot.advanced = this.advancedValue;
    snapshot.webAutoAccept = this.webAutoAcceptValue;
    snapshot.localIps = this.localIps();
    snapshot.hasFinished = this.finishedRows.length > 0;
    snapshot.finishedSender = this.finishedSender;
    snapshot.finishedFiles = this.finishedRows.slice(0);
    snapshot.log = this.logLines.slice(0);
    listener(snapshot);
  }
}

/** A favorite is keyed by fingerprint when it has one, by `host:port` when typed in by hand. */
function favoriteKey(favorite: FavoriteRow): string {
  return favorite.fingerprint.length > 0
    ? favorite.fingerprint
    : `${favorite.host}:${favorite.port}`;
}

/** Best-effort size for the picked-file card; a uri we cannot stat shows as 0 B, not a crash. */
function sizeOf(uri: string): number {
  try {
    return fs.statSync(uri).size;
  } catch (e) {
    return 0;
  }
}

/**
 * Last path segment of a uri, percent-decoded.
 *
 * Pickers hand back `file://docs/.../名字.pdf` and `file://media/Photo/.../IMG_1.jpg`; a
 * `decodeURIComponent` failure only means the name contains a stray `%`, which is legal in a file
 * name, so the raw tail is the better answer.
 */
function displayNameOf(uri: string): string {  const trimmed: string = uri.endsWith('/') ? uri.substring(0, uri.length - 1) : uri;
  const slash: number = trimmed.lastIndexOf('/');
  const tail: string = slash < 0 ? trimmed : trimmed.substring(slash + 1);
  try {
    return decodeURIComponent(tail);
  } catch (e) {
    return tail;
  }
}

/**
 * The extension the photo picker's creation config demands, which refuses a config without one.
 * The received name is the only hint: senders write their own mime type, often just
 * `application/octet-stream`, so the mime cannot be trusted for this.
 */
function extensionOf(name: string, fallback: string): string {
  const dot: number = name.lastIndexOf('.');
  if (dot < 0 || dot === name.length - 1) {
    return fallback;
  }
  return name.substring(dot + 1).toLowerCase();
}

/**
 * A system picker that dies stays silent instead of rejecting — the emulator's photo picker does
 * exactly that — so every picker call gets a deadline. `null` means the wait gave up; the caller
 * keeps its own continuation attached to `work` so an answer that arrives late is not lost.
 */
function withDeadline<T>(work: Promise<T>, timeoutMs: number): Promise<T | null> {
  return new Promise<T | null>((resolve: (value: T | null) => void,
    reject: (reason: Object) => void): void => {
    let settled: boolean = false;
    const timer: number = setTimeout((): void => {
      if (!settled) {
        settled = true;
        resolve(null);
      }
    }, timeoutMs);
    work.then((value: T): void => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        resolve(value);
      }
    }).catch((reason: Object): void => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(reason);
      }
    });
  });
}
