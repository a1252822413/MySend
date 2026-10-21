import { describe, it, expect } from '@ohos/hypium';
import {
  SanitizeRules,
  sanitizeFileName,
  extensionOf,
  stripCountSuffix,
  withCount,
  resolveConflict
} from '../../main/ets/util/FileName';
import { assertNoTraversal, cleanFileName } from '../../main/ets/util/PathSafety';
import { FileNameError, PathTraversalError } from '../../main/ets/util/Errors';

/** Name of the error a call raised, '' when it raised nothing. */
function errorNameOf(body: () => void): string {
  try {
    body();
  } catch (e) {
    const err: Error = e as Error;
    return err.name;
  }
  return '';
}

function takenNames(names: string[]): (candidate: string) => boolean {
  return (candidate: string): boolean => {
    return names.indexOf(candidate) !== -1;
  };
}

function utf8Length(text: string): number {
  let bytes: number = 0;
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code < 0x80) {
      bytes += 1;
    } else if (code < 0x800) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff) {
      bytes += 4;
      i += 1;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

export default function fileNameTest() {
  describe('FileNameTest', () => {
    it('current_uses_posix_rules', 0, () => {
      const posix: SanitizeRules = SanitizeRules.current();
      expect(sanitizeFileName('a/b:c', posix)).assertEqual('a_b:c');
      expect(sanitizeFileName('a\\b', posix)).assertEqual('a\\b');
    });

    it('replaces_illegal_characters', 0, () => {
      const windows: SanitizeRules = SanitizeRules.windows();
      expect(sanitizeFileName('a<b>c:d"e/f\\g|h?i*j', windows)).assertEqual('a_b_c_d_e_f_g_h_i_j');
      expect(sanitizeFileName('a/b:c', SanitizeRules.hfs())).assertEqual('a_b_c');
      expect(sanitizeFileName('a/b:c', SanitizeRules.posix())).assertEqual('a_b:c');
    });

    it('replaces_control_characters', 0, () => {
      expect(sanitizeFileName('a\u0000b\u001fc', SanitizeRules.posix())).assertEqual('a_b_c');
    });

    it('keeps_legal_names_untouched', 0, () => {
      expect(sanitizeFileName('holiday photo (1).jpg', SanitizeRules.current())).assertEqual('holiday photo (1).jpg');
      expect(sanitizeFileName('Ünïcödé — 文件.txt', SanitizeRules.current())).assertEqual('Ünïcödé — 文件.txt');
    });

    it('empty_name_becomes_placeholder', 0, () => {
      const posix: SanitizeRules = SanitizeRules.posix();
      expect(sanitizeFileName('', posix)).assertEqual('untitled');
      expect(sanitizeFileName('.', posix)).assertEqual('untitled');
      expect(sanitizeFileName('..', posix)).assertEqual('untitled');
      expect(sanitizeFileName('///', posix)).assertEqual('___');
    });

    it('collapses_trailing_dots_and_spaces_on_windows_like_rules', 0, () => {
      expect(sanitizeFileName('report.', SanitizeRules.windows())).assertEqual('report_');
      expect(sanitizeFileName('report...  ', SanitizeRules.windows())).assertEqual('report_');
      expect(sanitizeFileName('trailing ', SanitizeRules.universal())).assertEqual('trailing_');
      // POSIX and FAT allow a trailing dot.
      expect(sanitizeFileName('report.', SanitizeRules.posix())).assertEqual('report.');
      expect(sanitizeFileName('report.', SanitizeRules.fat())).assertEqual('report.');
    });

    it('prefixes_reserved_windows_stems', 0, () => {
      const windows: SanitizeRules = SanitizeRules.windows();
      expect(sanitizeFileName('CON.txt', windows)).assertEqual('_.txt');
      expect(sanitizeFileName('con', windows)).assertEqual('_');
      expect(sanitizeFileName('NUL.txt', windows)).assertEqual('_.txt');
      expect(sanitizeFileName('com9.tar.gz', windows)).assertEqual('_.tar.gz');
      expect(sanitizeFileName('lpt9', windows)).assertEqual('_');
      // Only the exact stem is reserved.
      expect(sanitizeFileName('console.txt', windows)).assertEqual('console.txt');
      expect(sanitizeFileName('com10.txt', windows)).assertEqual('com10.txt');
      // FAT carries no reserved names, POSIX accepts them as ordinary files.
      expect(sanitizeFileName('con', SanitizeRules.fat())).assertEqual('con');
      expect(sanitizeFileName('con.txt', SanitizeRules.posix())).assertEqual('con.txt');
    });

    it('truncates_on_a_utf8_char_boundary_at_255_bytes', 0, () => {
      const long: string = 'ä'.repeat(200); // 400 bytes
      const cut: string = sanitizeFileName(long, SanitizeRules.posix());
      expect(cut.length).assertEqual(127);
      expect(utf8Length(cut)).assertEqual(254);
      expect(cut).assertEqual('ä'.repeat(127));

      const ascii: string = sanitizeFileName('a'.repeat(300), SanitizeRules.posix());
      expect(ascii.length).assertEqual(255);

      const cjk: string = sanitizeFileName('文'.repeat(100), SanitizeRules.posix());
      expect(utf8Length(cjk)).assertEqual(255);
      expect(cjk.length).assertEqual(85);
    });

    it('truncation_does_not_expose_a_trailing_run', 0, () => {
      const dot: string = 'a'.repeat(254) + '.' + 'b'.repeat(10);
      expect(sanitizeFileName(dot, SanitizeRules.windows())).assertEqual('a'.repeat(254) + '_');
      expect(sanitizeFileName(dot, SanitizeRules.posix())).assertEqual('a'.repeat(254) + '.');
    });

    it('extension_of', 0, () => {
      expect(extensionOf('a.JPG')).assertEqual('jpg');
      expect(extensionOf('archive.tar.gz')).assertEqual('gz');
      expect(extensionOf('noext')).assertEqual('');
      expect(extensionOf('.gitignore')).assertEqual('gitignore');
    });

    it('strip_count_suffix', 0, () => {
      expect(stripCountSuffix('a (2)')).assertEqual('a');
      expect(stripCountSuffix('a (1) (2)')).assertEqual('a (1)');
      expect(stripCountSuffix('a(2)')).assertEqual('a(2)');
      expect(stripCountSuffix('a (x)')).assertEqual('a (x)');
      expect(stripCountSuffix('(2)')).assertEqual('(2)');
      expect(stripCountSuffix('a (2).jpg')).assertEqual('a (2)');
    });

    it('withCount_replaces_the_existing_suffix', 0, () => {
      expect(withCount('a (2).jpg', 3)).assertEqual('a (3).jpg');
      expect(withCount('a.jpg', 1)).assertEqual('a (1).jpg');
      expect(withCount('photo', 12)).assertEqual('photo (12)');
      expect(withCount('a (1) (2)', 5)).assertEqual('a (1) (5)');
      // The extension is lower-cased on the way through, as in the Dart helper.
      expect(withCount('a (2).JPG', 3)).assertEqual('a (3).jpg');
    });

    it('resolveConflict_walks_the_numbered_sequence', 0, () => {
      expect(resolveConflict('x.jpg', takenNames([]))).assertEqual('x.jpg');
      expect(resolveConflict('x.jpg', takenNames(['x.jpg']))).assertEqual('x (1).jpg');
      expect(resolveConflict('x.jpg', takenNames(['x.jpg', 'x (1).jpg']))).assertEqual('x (2).jpg');
      expect(resolveConflict('x.jpg', takenNames(['x.jpg', 'x (1).jpg', 'x (2).jpg'])))
        .assertEqual('x (3).jpg');
      // A peer-supplied suffix is replaced, not stacked.
      expect(resolveConflict('x (2).jpg', takenNames(['x (2).jpg']))).assertEqual('x (1).jpg');
    });

    it('traversal_is_refused_not_rewritten', 0, () => {
      expect(errorNameOf((): void => {
        cleanFileName('../etc/passwd');
      })).assertEqual('PathTraversalError');
      expect(errorNameOf((): void => {
        cleanFileName('/abs');
      })).assertEqual('PathTraversalError');
      expect(errorNameOf((): void => {
        cleanFileName('a/../../b');
      })).assertEqual('PathTraversalError');
      expect(errorNameOf((): void => {
        cleanFileName('..');
      })).assertEqual('PathTraversalError');
      expect(errorNameOf((): void => {
        cleanFileName('/');
      })).assertEqual('PathTraversalError');
      expect(errorNameOf((): void => {
        cleanFileName('');
      })).assertEqual('FileNameError');
    });

    it('dot_components_and_separators_are_collapsed', 0, () => {
      const parts: string[] = assertNoTraversal('a b/c');
      expect(parts.length).assertEqual(2);
      expect(parts[0]).assertEqual('a b');
      expect(parts[1]).assertEqual('c');
      // A name carrying a folder structure is not a single component.
      expect(errorNameOf((): void => {
        cleanFileName('a b/c');
      })).assertEqual('FileNameError');
      expect(cleanFileName('a b')).assertEqual('a b');
      expect(cleanFileName('./plain/')).assertEqual('plain');
      // On POSIX a backslash is an ordinary character, so the whole thing stays
      // one component and the sanitizer is what rewrites it for Windows peers.
      expect(cleanFileName('C:\\Windows\\evil.exe')).assertEqual('C:\\Windows\\evil.exe');
      expect(sanitizeFileName(cleanFileName('C:\\Windows\\evil.exe'), SanitizeRules.windows()))
        .assertEqual('C__Windows_evil.exe');
    });

    it('error_types_share_the_file_name_hierarchy', 0, () => {
      const traversal: PathTraversalError = new PathTraversalError('x');
      expect(traversal instanceof FileNameError).assertTrue();
      expect(traversal.name).assertEqual('PathTraversalError');
      expect(traversal.message).assertEqual('x');
    });
  });
}
