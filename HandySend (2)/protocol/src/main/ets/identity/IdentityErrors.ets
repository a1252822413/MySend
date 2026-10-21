import { BusinessError } from '@kit.BasicServicesKit';

/**
 * Our own error type: every HarmonyOS crypto/kit call that throws surfaces a
 * BusinessError with a numeric code, which is meaningless outside the kit. We
 * re-throw IdentityError with a context string plus the original code so the
 * UI layer can log something actionable.
 */
export class IdentityError extends Error {
  readonly context: string;
  readonly causeCode: number;
  readonly causeMessage: string;

  constructor(context: string, message: string, causeCode: number, causeMessage: string) {
    super(`[identity/${context}] ${message}` + (causeMessage.length > 0 ? ` (cause ${causeCode}: ${causeMessage})` : ''));
    this.name = 'IdentityError';
    this.context = context;
    this.causeCode = causeCode;
    this.causeMessage = causeMessage;
  }
}

/**
 * Wrap whatever a `catch` clause produced. The runtime object is usually a
 * BusinessError carrying `code`; plain Errors carry none, so `code` reads as
 * undefined at runtime despite the static type and we filter it out.
 */
export function wrapIdentityError(context: string, message: string, err: Object): IdentityError {
  let code: number = -1;
  let causeMessage: string = err.toString();
  try {
    const be: BusinessError = err as BusinessError;
    if (Number.isFinite(be.code)) {
      code = be.code;
    }
    if (typeof be.message === 'string' && be.message.length > 0) {
      causeMessage = be.message;
    }
  } catch (probeErr) {
    // Not BusinessError-shaped at all: keep the toString() fallback.
  }
  return new IdentityError(context, message, code, causeMessage);
}
