import { util } from '@kit.ArkTS';
import { wrapIdentityError } from './IdentityErrors';

/**
 * PEM armor/dearmor with 64-char body lines, on top of util.Base64Helper
 * (no third-party base64). The official Rust core emits LF line endings via
 * pem::encode / LineEnding::LF; we match that so stored PEMs are identical
 * across platforms for the same key.
 */

const LINE_WIDTH: number = 64;

export function pemArmor(label: string, der: Uint8Array): string {
  try {
    const helper: util.Base64Helper = new util.Base64Helper();
    const body: string = helper.encodeToStringSync(der);
    let out: string = `-----BEGIN ${label}-----\n`;
    for (let i = 0; i < body.length; i += LINE_WIDTH) {
      const end: number = Math.min(i + LINE_WIDTH, body.length);
      out += body.substring(i, end);
      out += '\n';
    }
    out += `-----END ${label}-----\n`;
    return out;
  } catch (e) {
    throw wrapIdentityError('pem', `PEM armor of '${label}' failed`, e as Object);
  }
}

/** Extract and base64-decode the body of a single-block PEM. */
export function pemDearmor(pemText: string, label: string): Uint8Array {
  try {
    const header: string = `-----BEGIN ${label}-----`;
    const footer: string = `-----END ${label}-----`;
    const start: number = pemText.indexOf(header);
    const end: number = pemText.indexOf(footer);
    if (start < 0 || end < 0 || end <= start) {
      throw new Error(`PEM block '${label}' not found`);
    }
    const raw: string = pemText.substring(start + header.length, end);
    let compact: string = '';
    for (let i = 0; i < raw.length; i++) {
      const c: string = raw.charAt(i);
      if (c !== '\n' && c !== '\r' && c !== ' ' && c !== '\t') {
        compact += c;
      }
    }
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.decodeSync(compact);
  } catch (e) {
    throw wrapIdentityError('pem', `PEM dearmor of '${label}' failed`, e as Object);
  }
}
