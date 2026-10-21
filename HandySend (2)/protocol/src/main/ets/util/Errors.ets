/**
 * Error types shared by the protocol utilities. Everything the platform throws
 * is wrapped in one of these, so callers never depend on BusinessError shapes.
 */
import { BusinessError } from '@kit.BasicServicesKit';

/** Illegal or unusable file name. */
export class FileNameError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'FileNameError';
  }
}

/**
 * A peer-supplied name tried to leave the destination directory. It extends
 * FileNameError so code that only distinguishes "bad name" keeps working,
 * while the transfer layer can still refuse the upload on its own.
 */
export class PathTraversalError extends FileNameError {
  constructor(message: string) {
    super(message);
    this.name = 'PathTraversalError';
  }
}

/** Work abandoned because the user (or a timeout) cancelled it. */
export class CancelledError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CancelledError';
  }
}

/** Failure of a network system call; the platform code is kept for logging. */
export class NetError extends Error {
  readonly code: number;

  constructor(message: string, code: number) {
    super(message);
    this.name = 'NetError';
    this.code = code;
  }
}

/** Failure of a digest or file-streaming call. */
export class DigestError extends Error {
  readonly code: number;

  constructor(message: string, code: number) {
    super(message);
    this.name = 'DigestError';
    this.code = code;
  }
}

/**
 * BusinessError code of a caught value, or -1 when the thrown object carries
 * none. The catch variable is untyped, hence the checked view cast.
 */
export function platformErrorCode(e: Object): number {
  const biz: BusinessError = e as BusinessError;
  const code: number = biz.code;
  return code > 0 ? code : -1;
}

/** Message of a caught value, prefixed for rethrow. */
export function describePlatformError(e: Object, prefix: string): string {
  const biz: BusinessError = e as BusinessError;
  return prefix + ': ' + biz.message + ' [code=' + platformErrorCode(e) + ']';
}

/**
 * Reads a caught value as text.
 *
 * A template interpolation is not enough on this runtime: an `Error` stringifies to
 * `[object Object]`, which turns a log line into noise exactly when it matters. BusinessError
 * carries `message`/`code` rather than a usable `toString`, so both shapes are pulled out here.
 */
export function describeFailure(value: Object): string {
  if (typeof value === 'string') {
    return value as string;
  }
  const error: Error = value as Error;
  const message: string = error.message;
  const code: number = platformErrorCode(value);
  const name: string = error.name.length > 0 ? error.name : 'Error';
  if (code > 0) {
    return `${name}: ${message} [code=${code}]`;
  }
  return message.length > 0 ? `${name}: ${message}` : name;
}
