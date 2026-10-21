/**
 * Gate for the `fileName` a peer puts on the wire. Mirrors the official Dart
 * `sanitizeRelativeName`: traversal is refused, never rewritten, so a name that
 * tries to leave the destination directory fails the transfer instead of
 * silently landing somewhere else.
 */
import { FileNameError, PathTraversalError } from './Errors';

const SLASH: string = '/';
const DOT_DOT: string = '..';
const DOT: string = '.';

/**
 * Splits a peer-supplied name and refuses to let it escape.
 *
 * Empty and `.` components address the directory they sit in, so they drop out;
 * any `..` and any absolute name aborts the transfer. HarmonyOS only treats `/`
 * as a separator, so a backslash stays an ordinary character of a component —
 * same call the Dart helper makes on POSIX.
 */
export function assertNoTraversal(fileName: string): string[] {
  if (fileName.startsWith(SLASH)) {
    throw new PathTraversalError('Absolute file name rejected: ' + fileName);
  }
  const parts: string[] = fileName.split(SLASH);
  const components: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const part: string = parts[i];
    if (part === DOT_DOT) {
      throw new PathTraversalError('Parent-directory reference rejected: ' + fileName);
    }
    if (part === DOT || part.length === 0) {
      continue;
    }
    components.push(part);
  }
  return components;
}

/**
 * The cleaned single-component name a file may be stored under. Names that
 * carry a folder structure belong to `assertNoTraversal` plus the per-component
 * sanitizer, not to a flat receive directory.
 */
export function cleanFileName(fileName: string): string {
  const components: string[] = assertNoTraversal(fileName);
  if (components.length !== 1) {
    throw new FileNameError('Name is not a single path component: ' + fileName);
  }
  return components[0];
}
