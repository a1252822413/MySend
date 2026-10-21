import { WireDeviceInfo } from '../wire/Dto';

/**
 * The browser-facing half of the protocol: the Download API of spec sections 5.2 and 5.3, plus the
 * page and the translations a browser needs to use it.
 */

/** Not a LocalSend API path, but it belongs to the same web surface. */
export const WEB_I18N_PATH: string = '/i18n.json';

/**
 * What the one page at `/` serves. The modes are exclusive because only one page can live at `/`:
 * browsers either download what the phone offers, or upload files to it.
 */
export enum WebShareMode {
  IDLE = 'idle',
  DOWNLOAD = 'download',
  UPLOAD = 'upload'
}

/** One file the phone offers to browsers, ready to be streamed from `uri`. */
export interface WebOfferFile {
  fileId: string;
  fileName: string;
  /** Claimed in Content-Length and in the file list, so a browser can detect a truncation. */
  size: number;
  fileType: string;
  /** Whatever `fileIo.open` accepts: a sandbox path, a document uri or a media uri. */
  uri: string;
  modifiedMs: number;
  /** Bytes handed to browsers so far; only feeds the on-screen counter. */
  downloaded: number;
}

/** What the phone shows the user when a browser asks for the offer. */
export interface WebOfferContext {
  clientIp: string;
  /** Verbatim `User-Agent`, truncated for the dialog; it is display text, never trusted. */
  userAgent: string;
  fileCount: number;
  totalBytes: number;
}

/**
 * Everything the web share asks the application for.
 *
 * `self` is re-read per request so the advertised `download` flag can never drift from the share
 * state, and `pin` is read per request as well — the reference fixes both at server start, but a
 * phone app that changes them must not answer with stale values.
 */
export interface WebShareConfig {
  /** Our own announcement; its `download` flag is what the file list answers with. */
  self: () => WireDeviceInfo;
  pin: () => string | null;
  /** The user's answer to "this browser wants the shared files". */
  decide: (context: WebOfferContext) => Promise<boolean>;
  /**
   * A request the dialog was showing is over without the user having answered — the browser hung up.
   * Without this the sheet would stay open over a request that can no longer be served.
   */
  onOfferClosed: (clientIp: string) => void;
  onChanged: () => void;
  log: (message: string) => void;
}
