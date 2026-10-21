/**
 * Tolerant readers for parsed JSON.
 *
 * Peers are other implementations of the same spec, so a field can be missing, null, or of the
 * wrong scalar type without the payload being unusable. Every read is defensive: the wire layer
 * must never throw on a malformed announcement from an unknown device on the LAN.
 */

export function asRecord(source: Object | null | undefined): Record<string, Object> | null {
  if (source === null || source === undefined) {
    return null;
  }
  if (source instanceof Object) {
    return source as Record<string, Object>;
  }
  return null;
}

export function parseRecord(text: string): Record<string, Object> | null {
  if (text.length === 0) {
    return null;
  }
  try {
    return asRecord(JSON.parse(text) as Object);
  } catch (e) {
    return null;
  }
}

export function readString(container: Record<string, Object>, key: string): string | null {
  const value: Object | undefined = container[key];
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value === 'string') {
    return value as string;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return `${value}`;
  }
  return null;
}

export function readNumber(container: Record<string, Object>, key: string, fallback: number): number {
  const value: Object | undefined = container[key];
  if (typeof value === 'number') {
    return value as number;
  }
  if (typeof value === 'string') {
    const parsed: number = Number.parseInt(value as string, 10);
    return Number.isNaN(parsed) ? fallback : parsed;
  }
  return fallback;
}

export function readBoolean(container: Record<string, Object>, key: string, fallback: boolean): boolean {
  const value: Object | undefined = container[key];
  if (typeof value === 'boolean') {
    return value as boolean;
  }
  if (typeof value === 'string') {
    return (value as string).toLowerCase() === 'true';
  }
  return fallback;
}

export function readRecord(container: Record<string, Object>, key: string): Record<string, Object> | null {
  return asRecord(container[key]);
}

/** Iterates the own keys of a parsed JSON object. */
export function keysOf(container: Record<string, Object>): string[] {
  const out: string[] = [];
  Object.keys(container).forEach((key: string) => {
    out.push(key);
  });
  return out;
}

export class JsonWriter {
  private parts: string[] = [];

  /**
   * `undefined` and `null` values are skipped, matching the spec's "nullable / optional" fields:
   * sending an explicit null is not the same as omitting the key for strict peer deserializers.
   */
  putString(key: string, value: string | null | undefined): JsonWriter {
    if (value === undefined || value === null) {
      return this;
    }
    this.emit(key, JSON.stringify(value));
    return this;
  }

  putNumber(key: string, value: number | null | undefined): JsonWriter {
    if (value === undefined || value === null || Number.isNaN(value)) {
      return this;
    }
    this.emit(key, `${value}`);
    return this;
  }

  putBoolean(key: string, value: boolean | null | undefined): JsonWriter {
    if (value === undefined || value === null) {
      return this;
    }
    this.emit(key, value ? 'true' : 'false');
    return this;
  }

  putRaw(key: string, json: string): JsonWriter {
    this.emit(key, json);
    return this;
  }

  putObject(key: string, value: JsonWriter | null | undefined): JsonWriter {
    if (value === undefined || value === null) {
      return this;
    }
    this.emit(key, value.build());
    return this;
  }

  /** A map keyed by arbitrary strings (the `files` payloads), values built by `buildEntry`. */
  putMap<T>(key: string, entries: Map<string, T>, buildEntry: (value: T) => JsonWriter): JsonWriter {
    const writer: JsonWriter = new JsonWriter();
    entries.forEach((value: T, mapKey: string) => {
      writer.putObject(mapKey, buildEntry(value));
    });
    this.emit(key, writer.build());
    return this;
  }

  build(): string {
    return `{${this.parts.join(',')}}`;
  }

  private emit(key: string, jsonValue: string): void {
    this.parts.push(`${JSON.stringify(key)}:${jsonValue}`);
  }
}
