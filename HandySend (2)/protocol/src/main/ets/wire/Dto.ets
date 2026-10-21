import { DeviceTypeValue, normalizeDeviceType, ProtocolScheme } from './Constants';
import {
  JsonWriter, parseRecord, readBoolean, readNumber, readRecord, readString, keysOf
} from './JsonValue';

/**
 * Wire DTOs for LocalSend protocol v2.2.
 *
 * Two rules govern this file:
 * - key names are exactly the camelCase names in the spec, because peers deserialize strictly;
 * - optional fields are omitted rather than sent as null, and parsing never throws on surprises.
 */

/** `info` payload used by announcement, register and prepare-upload. */
export interface WireDeviceInfo {
  alias: string;
  version: string;
  deviceModel?: string;
  deviceType?: DeviceTypeValue;
  fingerprint: string;
  port: number;
  protocol: ProtocolScheme;
  download: boolean;
}

/** UDP announcement: the `info` payload plus the legacy `announce` flag. */
export interface WireAnnouncement extends WireDeviceInfo {
  announce: boolean;
}

/** Response body of /register and /info, which carries no port or scheme. */
export interface WireInfoResponse {
  alias: string;
  version: string;
  deviceModel?: string;
  deviceType?: DeviceTypeValue;
  fingerprint: string;
  download: boolean;
}

export interface WireFileMetadata {
  modified?: string;
  accessed?: string;
}

export interface WireFile {
  id: string;
  fileName: string;
  size: number;
  fileType: string;
  sha256?: string;
  preview?: string;
  metadata?: WireFileMetadata;
}

export interface WirePrepareUploadRequest {
  info: WireDeviceInfo;
  files: Map<string, WireFile>;
}

export interface WirePrepareUploadResponse {
  sessionId: string;
  /** fileId -> per-file upload token; only accepted files are present. */
  files: Map<string, string>;
}

export interface WirePrepareDownloadResponse {
  info: WireInfoResponse;
  sessionId: string;
  files: Map<string, WireFile>;
}

export interface WireError {
  message?: string;
}

export class Dto {
  static deviceInfoToJson(info: WireDeviceInfo): JsonWriter {
    const writer: JsonWriter = new JsonWriter();
    writer.putString('alias', info.alias);
    writer.putString('version', info.version);
    writer.putString('deviceModel', info.deviceModel);
    writer.putString('deviceType', info.deviceType);
    writer.putString('fingerprint', info.fingerprint);
    writer.putNumber('port', info.port);
    writer.putString('protocol', info.protocol);
    writer.putBoolean('download', info.download);
    return writer;
  }

  static announcementToJson(info: WireDeviceInfo, announce: boolean): string {
    const writer: JsonWriter = Dto.deviceInfoToJson(info);
    writer.putBoolean('announce', announce);
    return writer.build();
  }

  static infoResponseToJson(info: WireInfoResponse): string {
    const writer: JsonWriter = new JsonWriter();
    writer.putString('alias', info.alias);
    writer.putString('version', info.version);
    writer.putString('deviceModel', info.deviceModel);
    writer.putString('deviceType', info.deviceType);
    writer.putString('fingerprint', info.fingerprint);
    writer.putBoolean('download', info.download);
    return writer.build();
  }

  /**
   * The `/register`, `/info` and `prepare-download` answer built from our own announcement: the same
   * identity without the dialling information, which a peer already knows by having reached us.
   */
  static infoResponseOf(info: WireDeviceInfo): WireInfoResponse {
    const response: WireInfoResponse = {
      alias: info.alias,
      version: info.version,
      fingerprint: info.fingerprint,
      download: info.download,
      deviceModel: info.deviceModel,
      deviceType: info.deviceType === undefined ? DeviceTypeValue.DESKTOP : info.deviceType
    };
    return response;
  }

  static fileToJson(file: WireFile): JsonWriter {
    const writer: JsonWriter = new JsonWriter();
    writer.putString('id', file.id);
    writer.putString('fileName', file.fileName);
    writer.putNumber('size', file.size);
    writer.putString('fileType', file.fileType);
    writer.putString('sha256', file.sha256);
    writer.putString('preview', file.preview);
    if (file.metadata !== undefined) {
      const metadata: JsonWriter = new JsonWriter();
      metadata.putString('modified', file.metadata.modified);
      metadata.putString('accessed', file.metadata.accessed);
      writer.putObject('metadata', metadata);
    }
    return writer;
  }

  static prepareUploadRequestToJson(request: WirePrepareUploadRequest): string {
    const writer: JsonWriter = new JsonWriter();
    writer.putObject('info', Dto.deviceInfoToJson(request.info));
    writer.putMap('files', request.files, (file: WireFile) => Dto.fileToJson(file));
    return writer.build();
  }

  static prepareUploadResponseToJson(response: WirePrepareUploadResponse): string {
    const writer: JsonWriter = new JsonWriter();
    writer.putString('sessionId', response.sessionId);
    const files: JsonWriter = new JsonWriter();
    response.files.forEach((token: string, fileId: string) => {
      files.putString(fileId, token);
    });
    writer.putRaw('files', files.build());
    return writer.build();
  }

  static prepareDownloadResponseToJson(response: WirePrepareDownloadResponse): string {
    const writer: JsonWriter = new JsonWriter();
    writer.putRaw('info', Dto.infoResponseToJson(response.info));
    writer.putString('sessionId', response.sessionId);
    writer.putMap('files', response.files, (file: WireFile) => Dto.fileToJson(file));
    return writer.build();
  }

  static errorToJson(error: WireError): string {
    const writer: JsonWriter = new JsonWriter();
    writer.putString('message', error.message);
    return writer.build();
  }

  /** Parses an `info` object from any endpoint; returns null when the payload is unusable. */
  static parseDeviceInfo(source: Record<string, Object>): WireDeviceInfo | null {
    const alias: string | null = readString(source, 'alias');
    const fingerprint: string | null = readString(source, 'fingerprint');
    if (alias === null || fingerprint === null) {
      return null;
    }
    const version: string | null = readString(source, 'version');
    const info: WireDeviceInfo = {
      alias: alias,
      version: version === null ? '' : version,
      fingerprint: fingerprint,
      port: readNumber(source, 'port', 0),
      protocol: Dto.parseScheme(readString(source, 'protocol')),
      download: readBoolean(source, 'download', false),
      deviceModel: readString(source, 'deviceModel') ?? undefined,
      deviceType: normalizeDeviceType(readString(source, 'deviceType'))
    };
    return info;
  }

  static parseAnnouncement(source: Record<string, Object>): WireAnnouncement | null {
    const info: WireDeviceInfo | null = Dto.parseDeviceInfo(source);
    if (info === null) {
      return null;
    }
    const announcement: WireAnnouncement = {
      alias: info.alias,
      version: info.version,
      fingerprint: info.fingerprint,
      port: info.port,
      protocol: info.protocol,
      download: info.download,
      deviceModel: info.deviceModel,
      deviceType: info.deviceType,
      announce: readBoolean(source, 'announce', false)
    };
    return announcement;
  }

  static parseInfoResponse(source: Record<string, Object>): WireInfoResponse {
    const response: WireInfoResponse = {
      alias: readString(source, 'alias') ?? '',
      version: readString(source, 'version') ?? '',
      fingerprint: readString(source, 'fingerprint') ?? '',
      download: readBoolean(source, 'download', false),
      deviceModel: readString(source, 'deviceModel') ?? undefined,
      deviceType: normalizeDeviceType(readString(source, 'deviceType'))
    };
    return response;
  }

  static parseFile(source: Record<string, Object>, fallbackId: string): WireFile {
    const file: WireFile = {
      id: readString(source, 'id') ?? fallbackId,
      fileName: readString(source, 'fileName') ?? 'unnamed',
      size: readNumber(source, 'size', 0),
      fileType: readString(source, 'fileType') ?? 'application/octet-stream',
      sha256: readString(source, 'sha256') ?? undefined,
      preview: readString(source, 'preview') ?? undefined
    };
    const metadata: Record<string, Object> | null = readRecord(source, 'metadata');
    if (metadata !== null) {
      const parsed: WireFileMetadata = {
        modified: readString(metadata, 'modified') ?? undefined,
        accessed: readString(metadata, 'accessed') ?? undefined
      };
      file.metadata = parsed;
    }
    return file;
  }

  /** The wire `files` object is a map of fileId -> file; keys are authoritative over `id`. */
  static parseFileMap(source: Record<string, Object> | null): Map<string, WireFile> {
    const files: Map<string, WireFile> = new Map<string, WireFile>();
    if (source === null) {
      return files;
    }
    keysOf(source).forEach((fileId: string) => {
      const value: Record<string, Object> | null = readRecord(source, fileId);
      if (value !== null) {
        files.set(fileId, Dto.parseFile(value, fileId));
      }
    });
    return files;
  }

  static parsePrepareUploadRequest(body: string): WirePrepareUploadRequest | null {
    const root: Record<string, Object> | null = parseRecord(body);
    if (root === null) {
      return null;
    }
    const infoSource: Record<string, Object> | null = readRecord(root, 'info');
    if (infoSource === null) {
      return null;
    }
    const info: WireDeviceInfo | null = Dto.parseDeviceInfo(infoSource);
    if (info === null) {
      return null;
    }
    const request: WirePrepareUploadRequest = {
      info: info,
      files: Dto.parseFileMap(readRecord(root, 'files'))
    };
    return request;
  }

  static parsePrepareUploadResponse(body: string): WirePrepareUploadResponse | null {
    const root: Record<string, Object> | null = parseRecord(body);
    if (root === null) {
      return null;
    }
    const sessionId: string | null = readString(root, 'sessionId');
    if (sessionId === null) {
      return null;
    }
    const tokens: Map<string, string> = new Map<string, string>();
    const files: Record<string, Object> | null = readRecord(root, 'files');
    if (files !== null) {
      keysOf(files).forEach((fileId: string) => {
        const token: string | null = readString(files, fileId);
        if (token !== null) {
          tokens.set(fileId, token);
        }
      });
    }
    const response: WirePrepareUploadResponse = { sessionId: sessionId, files: tokens };
    return response;
  }

  static parsePrepareDownloadResponse(body: string): WirePrepareDownloadResponse | null {
    const root: Record<string, Object> | null = parseRecord(body);
    if (root === null) {
      return null;
    }
    const infoSource: Record<string, Object> | null = readRecord(root, 'info');
    if (infoSource === null) {
      return null;
    }
    const sessionId: string | null = readString(root, 'sessionId');
    if (sessionId === null) {
      return null;
    }
    const response: WirePrepareDownloadResponse = {
      info: Dto.parseInfoResponse(infoSource),
      sessionId: sessionId,
      files: Dto.parseFileMap(readRecord(root, 'files'))
    };
    return response;
  }

  static parseError(body: string): WireError {
    const root: Record<string, Object> | null = parseRecord(body);
    const error: WireError = { message: root === null ? undefined : readString(root, 'message') ?? undefined };
    return error;
  }

  static parseScheme(raw: string | null): ProtocolScheme {
    return raw !== null && raw.toLowerCase() === ProtocolScheme.HTTPS ? ProtocolScheme.HTTPS : ProtocolScheme.HTTP;
  }
}
