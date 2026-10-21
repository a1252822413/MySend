import { fileIo } from '@kit.CoreFileKit';
import { SanitizeRules, resolveConflict, sanitizeFileName } from '../util/FileName';
import { describeFailure } from '../util/Errors';
import { assertNoTraversal } from '../util/PathSafety';

/**
 * Where a peer-supplied name lands on this device.
 *
 * The reference client resolves a name once, when the transfer is accepted, and keeps that
 * target for every retry — so a re-uploaded file overwrites its own partial bytes instead of
 * piling up copies. We plan all names at prepare time for the same reason, and additionally
 * within the session, because two files of one offer can carry the same name.
 */

const SLASH: string = '/';

export function joinPath(dir: string, name: string): string {
  return dir.endsWith(SLASH) ? dir + name : dir + SLASH + name;
}

export function parentDir(path: string): string {
  const cut: number = path.lastIndexOf(SLASH);
  return cut <= 0 ? SLASH : path.substring(0, cut);
}

export function exists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (e) {
    // An unreadable parent counts as absent: the caller then fails on open with a real reason.
    return false;
  }
}

/** Creates `dir` and any missing parent; succeeds when it is already there. */
export async function ensureDirectory(dir: string): Promise<void> {
  if (exists(dir)) {
    return;
  }
  try {
    await fileIo.mkdir(dir, true);
  } catch (e) {
    if (!exists(dir)) {
      throw new Error(`mkdir ${dir} failed: ${describeFailure(e)}`);
    }
  }
}

/** A planned landing spot: what the user sees, and what the writer opens. */
export class PlannedPath {
  readonly relative: string;
  readonly absolute: string;

  constructor(relative: string, absolute: string) {
    this.relative = relative;
    this.absolute = absolute;
  }
}

export class LayoutPlanner {
  private readonly destination: string;
  private readonly rules: SanitizeRules = SanitizeRules.current();
  /** Roots claimed by this session, so a duplicate name inside one offer still gets a copy. */
  private readonly taken: Set<string> = new Set<string>();

  constructor(destination: string) {
    this.destination = destination;
  }

  /**
   * Refuses traversal, sanitizes each component and de-duplicates the root. Throws
   * PathTraversalError for a name that tries to leave the destination, which fails the
   * whole offer — rewriting it into something else would silently misfile the file.
   */
  plan(fileName: string): PlannedPath {
    const components: string[] = assertNoTraversal(fileName);
    const cleaned: string[] = [];
    for (let i = 0; i < components.length; i++) {
      cleaned.push(sanitizeFileName(components[i], this.rules));
    }
    if (cleaned.length === 0) {
      cleaned.push(this.rules.placeholder);
    }
    const root: string = resolveConflict(cleaned[0], (candidate: string): boolean => this.occupied(candidate));
    this.taken.add(joinPath(this.destination, root));
    const relative: string = [root].concat(cleaned.slice(1)).join(SLASH);
    return new PlannedPath(relative, joinPath(this.destination, relative));
  }

  private occupied(candidate: string): boolean {
    const path: string = joinPath(this.destination, candidate);
    return this.taken.has(path) || exists(path);
  }
}
