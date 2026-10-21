/**
 * Content types for the `fileType` field of a send request.
 *
 * The receiver shows this value and the browser page uses it for downloads, but no peer branches on
 * it, so an accurate table for the formats a phone actually holds matters more than a complete one.
 * Anything unknown becomes `application/octet-stream`, which is what the reference clients send for
 * a file they cannot classify.
 */

const UNKNOWN: string = 'application/octet-stream';

function buildTable(): Map<string, string> {
  const table: Map<string, string> = new Map<string, string>();
  table.set('jpg', 'image/jpeg');
  table.set('jpeg', 'image/jpeg');
  table.set('png', 'image/png');
  table.set('gif', 'image/gif');
  table.set('webp', 'image/webp');
  table.set('bmp', 'image/bmp');
  table.set('heic', 'image/heic');
  table.set('heif', 'image/heif');
  table.set('svg', 'image/svg+xml');
  table.set('mp4', 'video/mp4');
  table.set('m4v', 'video/mp4');
  table.set('mov', 'video/quicktime');
  table.set('mkv', 'video/x-matroska');
  table.set('webm', 'video/webm');
  table.set('avi', 'video/x-msvideo');
  table.set('mp3', 'audio/mpeg');
  table.set('m4a', 'audio/mp4');
  table.set('aac', 'audio/aac');
  table.set('wav', 'audio/wav');
  table.set('flac', 'audio/flac');
  table.set('ogg', 'audio/ogg');
  table.set('txt', 'text/plain');
  table.set('md', 'text/markdown');
  table.set('csv', 'text/csv');
  table.set('json', 'application/json');
  table.set('xml', 'application/xml');
  table.set('pdf', 'application/pdf');
  table.set('zip', 'application/zip');
  table.set('rar', 'application/vnd.rar');
  table.set('7z', 'application/x-7z-compressed');
  table.set('tar', 'application/x-tar');
  table.set('apk', 'application/vnd.android.package-archive');
  table.set('doc', 'application/msword');
  table.set('xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
  table.set('docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
  table.set('pptx', 'application/vnd.openxmlformats-officedocument.presentationml.presentation');
  return table;
}

const BY_EXTENSION: Map<string, string> = buildTable();

function extensionOf(name: string): string {
  // A folder member arrives as `dir/name.ext`, so only the last dot of the last component counts.
  const slash: number = name.lastIndexOf('/');
  const leaf: string = slash < 0 ? name : name.substring(slash + 1);
  const dot: number = leaf.lastIndexOf('.');
  if (dot <= 0 || dot === leaf.length - 1) {
    return '';
  }
  return leaf.substring(dot + 1).toLowerCase();
}

export function mimeTypeOf(fileName: string): string {
  const mime: string | undefined = BY_EXTENSION.get(extensionOf(fileName));
  return mime === undefined ? UNKNOWN : mime;
}
