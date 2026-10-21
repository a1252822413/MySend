/**
 * File-name rules for untrusted, peer-supplied names. Ported from the official
 * Rust core (packages/core/src/util/filename.rs) and the " (n)" de-duplication
 * suffix of the Dart client (file_path_helper.dart).
 */

const ILLEGAL_WINDOWS_CHARS: string = '<>:"/\\|?*';
const ILLEGAL_HFS_CHARS: string = '/:';
const ILLEGAL_POSIX_CHARS: string = '/';

/** ext4, APFS and HFS+ all cap a single component at 255 bytes. */
const MAX_NAME_BYTES: number = 255;

/** Device names Windows reserves whatever the extension is. */
const RESERVED_WINDOWS_STEMS: string[] = [
  'con', 'prn', 'aux', 'nul',
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9'
];

const DOT: string = '.';
const SPACE: string = ' ';

/** Unicode general category Cc, what Rust's `char::is_control` rejects. */
function isControlCodePoint(cp: number): boolean {
  return cp < 0x20 || (cp >= 0x7f && cp <= 0x9f);
}

function utf8ByteLength(cp: number): number {
  if (cp < 0x80) {
    return 1;
  }
  if (cp < 0x800) {
    return 2;
  }
  if (cp < 0x10000) {
    return 3;
  }
  return 4;
}

/**
 * Code point starting at `index`. A lone surrogate is returned as its own unit,
 * so a malformed name still round-trips instead of losing bytes.
 */
function codePointAt(s: string, index: number): number {
  const high: number = s.charCodeAt(index);
  if (high >= 0xd800 && high <= 0xdbff && index + 1 < s.length) {
    const low: number = s.charCodeAt(index + 1);
    if (low >= 0xdc00 && low <= 0xdfff) {
      return 0x10000 + (high - 0xd800) * 0x400 + (low - 0xdc00);
    }
  }
  return high;
}

function unitsOfCodePoint(cp: number): number {
  return cp > 0xffff ? 2 : 1;
}

function isAsciiDigit(code: number): boolean {
  return code >= 0x30 && code <= 0x39;
}

/** The subset of `\s` a file name can realistically carry. */
function isWhitespaceCode(code: number): boolean {
  return code === 0x20 || (code >= 0x09 && code <= 0x0d);
}

/**
 * Which characters are illegal, whether Windows' extra baggage applies, and
 * what to substitute. Selected per destination file system, not per OS, so a
 * file can be sanitized for a volume that is not the local one.
 */
export class SanitizeRules {
  readonly illegalChars: string;
  readonly reservedStems: string[];
  /** Trailing `.`/` ` collapse plus reserved device names. */
  readonly windowsLike: boolean;
  readonly replacement: string;
  readonly placeholder: string;

  constructor(illegalChars: string, reservedStems: string[], windowsLike: boolean,
    replacement: string, placeholder: string) {
    this.illegalChars = illegalChars;
    this.reservedStems = reservedStems;
    this.windowsLike = windowsLike;
    this.replacement = replacement;
    this.placeholder = placeholder;
  }

  static posix(): SanitizeRules {
    return new SanitizeRules(ILLEGAL_POSIX_CHARS, [], false, '_', 'untitled');
  }

  static hfs(): SanitizeRules {
    return new SanitizeRules(ILLEGAL_HFS_CHARS, [], false, '_', 'untitled');
  }

  /** FAT/exFAT: the Windows character set, but no reserved names or trailing run. */
  static fat(): SanitizeRules {
    return new SanitizeRules(ILLEGAL_WINDOWS_CHARS, [], false, '_', 'untitled');
  }

  static windows(): SanitizeRules {
    return new SanitizeRules(ILLEGAL_WINDOWS_CHARS, RESERVED_WINDOWS_STEMS, true, '_', 'untitled');
  }

  /**
   * Intersection of every rule set. The HFS character set is a subset of the
   * Windows one, so the union is just the Windows characters.
   */
  static universal(): SanitizeRules {
    return new SanitizeRules(ILLEGAL_WINDOWS_CHARS, RESERVED_WINDOWS_STEMS, true, '_', 'untitled');
  }

  /**
   * Rules for this device. HarmonyOS stores on a POSIX-ish volume, and like the
   * official client we sanitize with the current platform's rules rather than
   * the most restrictive, so a name survives a round trip unchanged.
   */
  static current(): SanitizeRules {
    return SanitizeRules.posix();
  }

  isIllegalCodePoint(cp: number): boolean {
    if (isControlCodePoint(cp)) {
      return true;
    }
    for (let i = 0; i < this.illegalChars.length; i++) {
      if (this.illegalChars.charCodeAt(i) === cp) {
        return true;
      }
    }
    return false;
  }
}

/** Replaces a trailing run of `.`/` ` with a single replacement. */
function collapseTrailingRun(name: string, replacement: string): string {
  let end: number = name.length;
  while (end > 0) {
    const code: number = name.charCodeAt(end - 1);
    if (code !== 0x2e && code !== 0x20) {
      break;
    }
    end -= 1;
  }
  if (end === name.length) {
    return name;
  }
  return name.substring(0, end) + replacement;
}

/** Reserved stems are matched case-insensitively against the part before the first `.`. */
function reservedStemLengthOf(name: string, stems: string[]): number {
  const firstDot: number = name.indexOf(DOT);
  const stem: string = firstDot === -1 ? name : name.substring(0, firstDot);
  const lowered: string = stem.toLowerCase();
  for (let i = 0; i < stems.length; i++) {
    if (stems[i] === lowered) {
      return stem.length;
    }
  }
  return 0;
}

/** Cuts to at most `max` UTF-8 bytes, never in the middle of a code point. */
function truncateToBytes(value: string, max: number): string {
  let bytes: number = 0;
  let index: number = 0;
  while (index < value.length) {
    const cp: number = codePointAt(value, index);
    const size: number = utf8ByteLength(cp);
    if (bytes + size > max) {
      break;
    }
    bytes += size;
    index += unitsOfCodePoint(cp);
  }
  return value.substring(0, index);
}

/**
 * Rewrites `name` into a single legal component. `name` must already be one
 * path segment; any separator it still carries is replaced, not honoured.
 */
export function sanitizeFileName(name: string, rules: SanitizeRules): string {
  let result: string = '';
  let index: number = 0;
  while (index < name.length) {
    const cp: number = codePointAt(name, index);
    const units: number = unitsOfCodePoint(cp);
    if (rules.isIllegalCodePoint(cp)) {
      result += rules.replacement;
    } else {
      result += name.substring(index, index + units);
    }
    index += units;
  }

  if (rules.windowsLike) {
    result = collapseTrailingRun(result, rules.replacement);
    const reserved: number = reservedStemLengthOf(result, rules.reservedStems);
    if (reserved > 0) {
      result = rules.replacement + result.substring(reserved);
    }
  }

  result = truncateToBytes(result, MAX_NAME_BYTES);

  if (rules.windowsLike) {
    // The cut can land right after a `.` or ` `, exposing a trailing run that
    // did not exist before truncation.
    result = collapseTrailingRun(result, rules.replacement);
    result = truncateToBytes(result, MAX_NAME_BYTES);
  }

  if (result.length === 0 || result === DOT || result === DOT + DOT) {
    result = truncateToBytes(rules.placeholder, MAX_NAME_BYTES);
  }

  return result;
}

/** Extension after the last `.`; empty string when the name has none. */
export function extensionOf(name: string): string {
  const dot: number = name.lastIndexOf(DOT);
  if (dot === -1) {
    return '';
  }
  return name.substring(dot + 1).toLowerCase();
}

/**
 * Drops a trailing " (n)". Mirrors the Dart regex `^(.*)(?:(\s\(\d+\)))$`,
 * whose greedy stem means only the last numbered group is peeled off:
 * `a (1) (2)` becomes `a (1)`.
 */
export function stripCountSuffix(name: string): string {
  const length: number = name.length;
  // Shortest suffix matching `\s\(\d+\)` is four characters.
  if (length < 4 || name.charCodeAt(length - 1) !== 0x29) {
    return name;
  }
  let cursor: number = length - 2;
  while (cursor > 0 && isAsciiDigit(name.charCodeAt(cursor))) {
    cursor -= 1;
  }
  const digits: number = length - 2 - cursor;
  if (digits === 0 || name.charCodeAt(cursor) !== 0x28 || cursor === 0) {
    return name;
  }
  if (!isWhitespaceCode(name.charCodeAt(cursor - 1))) {
    return name;
  }
  return name.substring(0, cursor - 1);
}

/**
 * Replaces the name's count suffix with ` (count)`, keeping the extension.
 * A stem with no count gains one; a dotfile such as `.gitignore` is treated as
 * an empty stem plus an extension, exactly like the Dart helper does.
 */
export function withCount(name: string, count: number): string {
  const dot: number = name.lastIndexOf(DOT);
  let stem: string = name;
  let extension: string = '';
  if (dot !== -1) {
    stem = name.substring(0, dot);
    extension = name.substring(dot + 1).toLowerCase();
  }
  const base: string = stripCountSuffix(stem) + SPACE + '(' + count + ')';
  return extension.length > 0 ? base + DOT + extension : base;
}

/**
 * First free name for `name`: itself when nothing occupies it, otherwise the
 * counted variants. `exists` is the destination-directory probe; it is called
 * with candidates in the order they should be reported to the user.
 */
export function resolveConflict(name: string, exists: (candidate: string) => boolean): string {
  if (!exists(name)) {
    return name;
  }
  let count: number = 1;
  let candidate: string = withCount(name, count);
  while (exists(candidate)) {
    count += 1;
    candidate = withCount(name, count);
  }
  return candidate;
}
