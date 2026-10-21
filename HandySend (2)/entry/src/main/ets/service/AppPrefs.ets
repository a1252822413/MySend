import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { IdentityStore, StoredIdentity } from '@lsnext/protocol';

const STORE_NAME: string = 'localsend';
const KEY_ALIAS: string = 'alias';
const KEY_CERT: string = 'certPem';
const KEY_KEY: string = 'keyPem';
const KEY_KEY_PASSWORD: string = 'keyPassword';
const KEY_FINGERPRINT: string = 'fingerprint';
const KEY_ENCRYPTION: string = 'encryption';
const KEY_RECEIVING: string = 'receiving';
const KEY_KNOWN_HOSTS: string = 'knownHosts';
const KEY_RECEIVE_PIN: string = 'receivePin';
const KEY_WEB_AUTO_ACCEPT: string = 'webAutoAccept';
const KEY_QUICK_SAVE: string = 'quickSave';
const KEY_FAVORITES: string = 'favorites';
const KEY_HISTORY: string = 'history';
const KEY_THEME: string = 'themeMode';
const KEY_ANIMATIONS: string = 'animations';
const KEY_AUTO_FINISH: string = 'autoFinish';
const KEY_SAVE_TO_HISTORY: string = 'saveToHistory';
const KEY_ADVANCED: string = 'advancedSettings';

/**
 * The app's settings and the device identity, in one preferences file.
 *
 * The identity implements the protocol's `IdentityStore` contract: the HAR decides
 * *what* an identity is, this decides only *where* it lives, which is what keeps the
 * protocol layer free of any UI-framework dependency.
 */
export class AppPrefs implements IdentityStore {
  private readonly prefs: preferences.Preferences;

  private constructor(prefs: preferences.Preferences) {
    this.prefs = prefs;
  }

  static async open(context: common.UIAbilityContext): Promise<AppPrefs> {
    const prefs: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    return new AppPrefs(prefs);
  }

  async load(): Promise<StoredIdentity | null> {
    const fingerprint: string = this.prefs.getSync(KEY_FINGERPRINT, '') as string;
    if (fingerprint.length === 0) {
      return null;
    }
    const stored: StoredIdentity = {
      certPem: this.prefs.getSync(KEY_CERT, '') as string,
      keyPem: this.prefs.getSync(KEY_KEY, '') as string,
      keyPassword: this.prefs.getSync(KEY_KEY_PASSWORD, '') as string,
      fingerprint: fingerprint
    };
    return stored;
  }

  async save(identity: StoredIdentity): Promise<void> {
    this.prefs.putSync(KEY_CERT, identity.certPem);
    this.prefs.putSync(KEY_KEY, identity.keyPem);
    this.prefs.putSync(KEY_KEY_PASSWORD, identity.keyPassword);
    this.prefs.putSync(KEY_FINGERPRINT, identity.fingerprint);
    await this.prefs.flush();
  }

  /** The alias the official clients default to: the device's marketing name. */
  alias(): string {
    const stored: string = this.prefs.getSync(KEY_ALIAS, '') as string;
    if (stored.length > 0) {
      return stored;
    }
    return deviceInfo.marketName;
  }

  async setAlias(alias: string): Promise<void> {
    this.prefs.putSync(KEY_ALIAS, alias);
    await this.prefs.flush();
  }

  /**
   * Encryption on means HTTPS with the device certificate. Off is plain HTTP with a
   * random fingerprint, which is also the only mode verified against the emulator so far.
   */
  encryption(): boolean {
    return this.prefs.getSync(KEY_ENCRYPTION, false) as boolean;
  }

  async setEncryption(enabled: boolean): Promise<void> {
    this.prefs.putSync(KEY_ENCRYPTION, enabled);
    await this.prefs.flush();
  }

  /** Official mobile clients receive as soon as the app is open, so on is the default. */
  receiving(): boolean {
    return this.prefs.getSync(KEY_RECEIVING, true) as boolean;
  }

  async setReceiving(enabled: boolean): Promise<void> {
    this.prefs.putSync(KEY_RECEIVING, enabled);
    await this.prefs.flush();
  }

  /**
   * Addresses the user added by hand. Without multicast there is nothing else to point
   * discovery at, so these have to survive a restart.
   */
  knownHosts(): string[] {
    const stored: string[] = this.prefs.getSync(KEY_KNOWN_HOSTS, []) as string[];
    return stored.slice(0);
  }

  async setKnownHosts(specs: string[]): Promise<void> {
    this.prefs.putSync(KEY_KNOWN_HOSTS, specs.slice(0));
    await this.prefs.flush();
  }

  /**
   * The PIN every sender — a device or a browser upload — must present. Empty means "no PIN", which
   * is the state the official clients default to.
   */
  receivePin(): string | null {
    const stored: string = this.prefs.getSync(KEY_RECEIVE_PIN, '') as string;
    return stored.length === 0 ? null : stored;
  }

  async setReceivePin(pin: string | null): Promise<void> {
    this.prefs.putSync(KEY_RECEIVE_PIN, pin === null ? '' : pin);
    await this.prefs.flush();
  }

  /** 'off' | 'paired' | 'on', the three states of the receive page's quick-save control. */
  quickSave(): string {
    return this.prefs.getSync(KEY_QUICK_SAVE, 'off') as string;
  }

  async setQuickSave(mode: string): Promise<void> {
    this.prefs.putSync(KEY_QUICK_SAVE, mode);
    await this.prefs.flush();
  }

  /** The favorites list as JSON; parsing lives in the service so this stays a dumb store. */
  favoritesJson(): string {
    return this.prefs.getSync(KEY_FAVORITES, '') as string;
  }

  async setFavoritesJson(json: string): Promise<void> {
    this.prefs.putSync(KEY_FAVORITES, json);
    await this.prefs.flush();
  }

  /** Receive history as JSON, newest first. */
  historyJson(): string {
    return this.prefs.getSync(KEY_HISTORY, '') as string;
  }

  async setHistoryJson(json: string): Promise<void> {
    this.prefs.putSync(KEY_HISTORY, json);
    await this.prefs.flush();
  }

  /** 'system' | 'light' | 'dark'. */
  themeMode(): string {
    return this.prefs.getSync(KEY_THEME, 'system') as string;
  }

  async setThemeMode(mode: string): Promise<void> {
    this.prefs.putSync(KEY_THEME, mode);
    await this.prefs.flush();
  }

  animations(): boolean {
    return this.prefs.getSync(KEY_ANIMATIONS, true) as boolean;
  }

  async setAnimations(enabled: boolean): Promise<void> {
    this.prefs.putSync(KEY_ANIMATIONS, enabled);
    await this.prefs.flush();
  }

  /** On: the finished transfer vanishes once done. Off: it stays with a 完成 button. */
  autoFinish(): boolean {
    return this.prefs.getSync(KEY_AUTO_FINISH, true) as boolean;
  }

  async setAutoFinish(enabled: boolean): Promise<void> {
    this.prefs.putSync(KEY_AUTO_FINISH, enabled);
    await this.prefs.flush();
  }

  saveToHistory(): boolean {
    return this.prefs.getSync(KEY_SAVE_TO_HISTORY, true) as boolean;
  }

  async setSaveToHistory(enabled: boolean): Promise<void> {
    this.prefs.putSync(KEY_SAVE_TO_HISTORY, enabled);
    await this.prefs.flush();
  }

  advanced(): boolean {
    return this.prefs.getSync(KEY_ADVANCED, false) as boolean;
  }

  async setAdvanced(enabled: boolean): Promise<void> {
    this.prefs.putSync(KEY_ADVANCED, enabled);
    await this.prefs.flush();
  }

  /** On: a browser hitting the download page is served without the per-request dialog. */
  webAutoAccept(): boolean {
    return this.prefs.getSync(KEY_WEB_AUTO_ACCEPT, false) as boolean;
  }

  async setWebAutoAccept(enabled: boolean): Promise<void> {
    this.prefs.putSync(KEY_WEB_AUTO_ACCEPT, enabled);
    await this.prefs.flush();
  }
}
