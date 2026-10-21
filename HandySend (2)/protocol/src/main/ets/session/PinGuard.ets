import { MAX_PIN_ATTEMPTS } from '../wire/Constants';

/**
 * Wrong-PIN bookkeeping for /prepare-upload.
 *
 * Same rules as the reference server (packages/core/src/http/server/common/pin.rs):
 * three failures per source IP and every later request is refused, and only a correct
 * PIN clears an address. The one deliberate addition is a bound on the table — the
 * reference uses an LRU for the same reason, since counters never expire on their own
 * and a device that stays on a LAN would otherwise accumulate entries forever.
 */

export enum PinResult {
  OK,
  /** No PIN required, or the required PIN was supplied. */
  LOCKED,
  MISSING,
  INVALID
}

/** Addresses tracked before the oldest are dropped; a LAN never has this many senders. */
const MAX_TRACKED_IPS: number = 128;

export class PinGuard {
  private attempts: Map<string, number> = new Map<string, number>();
  private readonly maxAttempts: number;

  constructor(maxAttempts: number = MAX_PIN_ATTEMPTS) {
    this.maxAttempts = maxAttempts;
  }

  check(requiredPin: string | null, providedPin: string | null, ip: string): PinResult {
    if (requiredPin === null) {
      return PinResult.OK;
    }
    const count: number = this.attempts.get(ip) ?? 0;
    if (count >= this.maxAttempts) {
      return PinResult.LOCKED;
    }
    if (providedPin === null) {
      return PinResult.MISSING;
    }
    if (providedPin === requiredPin) {
      this.attempts.delete(ip);
      return PinResult.OK;
    }
    this.put(ip, count + 1);
    return PinResult.INVALID;
  }

  private put(ip: string, count: number): void {
    if (!this.attempts.has(ip) && this.attempts.size >= MAX_TRACKED_IPS) {
      // Insertion order is the eviction order: the address that has been quiet longest goes.
      const oldest: string | undefined = this.attempts.keys().next().value as string | undefined;
      if (oldest !== undefined) {
        this.attempts.delete(oldest);
      }
    }
    this.attempts.set(ip, count);
  }

  reset(): void {
    this.attempts.clear();
  }
}
