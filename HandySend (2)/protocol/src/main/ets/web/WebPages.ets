/**
 * The browser-facing assets: the file list page, the upload form, the page a stopped share serves
 * instead, and the strings the pages show.
 *
 * The pages are deliberately plain HTML with ES5-era JavaScript so that any browser on the LAN works
 * — an old TV box, a corporate Safari, a HarmonyOS webview. Every visible word comes from `/i18n.json`
 * in the language the browser asked for, so one page serves both locales.
 *
 * Two constraints keep the source compilable inside a template literal: no backslash escapes and no
 * backticks anywhere in the markup or script.
 */

/** A file list a browser can pick from. */
export const DOWNLOAD_PAGE: string = `<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LocalSend</title>
<style>
body { margin: 0; padding: 24px 16px 56px; background: #f2f3f5; color: #1c1d1f;
       font-family: system-ui, "HarmonyOS Sans SC", "PingFang SC", sans-serif; }
main { max-width: 620px; margin: 0 auto; }
h1 { font-size: 20px; margin: 0 0 2px; }
.muted { color: #6b7076; font-size: 13px; margin: 0; }
#status { min-height: 20px; margin: 18px 0; font-size: 14px; color: #6b7076; }
#status.bad { color: #c62828; }
.file { display: flex; align-items: center; margin-bottom: 9px; padding: 13px 15px; background: #fff; border-radius: 12px; }
.name { flex: 1; margin-right: 10px; font-size: 14px; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.size { margin-right: 12px; font-size: 12px; color: #6b7076; white-space: nowrap; }
.get { padding: 7px 14px; font-size: 13px; color: #fff; background: #00796b; border-radius: 999px; text-decoration: none; }
.get:active { background: #00695c; }
@media (prefers-color-scheme: dark) {
body { background: #16171a; color: #e9eaec; }
.file { background: #232529; }
.muted, #status, .size { color: #9a9ea3; }
}
</style>
</head>
<body>
<main>
<h1>LocalSend</h1>
<p class="muted" id="device"></p>
<p id="status">LocalSend</p>
<div id="list"></div>
<noscript><p>需要浏览器启用 JavaScript / JavaScript is required to download these files.</p></noscript>
</main>
<script>
(function () {
  var API = '/api/localsend/v2';
  var status = document.getElementById('status');
  var device = document.getElementById('device');
  var list = document.getElementById('list');
  var text = {};

  function param(name) {
    var parts = location.search.slice(1).split('&');
    for (var i = 0; i < parts.length; i++) {
      var pair = parts[i].split('=');
      if (pair[0] === name) {
        return decodeURIComponent(pair.slice(1).join('=') || '');
      }
    }
    return '';
  }

  function remember(sessionId) {
    try { sessionStorage.setItem('localsendSession', sessionId); } catch (e) {}
  }

  function recalled() {
    try { return sessionStorage.getItem('localsendSession') || ''; } catch (e) { return ''; }
  }

  function ask(method, url, done) {
    var xhr = new XMLHttpRequest();
    xhr.open(method, url, true);
    xhr.onreadystatechange = function () {
      if (xhr.readyState === 4) { done(xhr); }
    };
    xhr.send(null);
  }

  function bad(message) {
    status.className = 'bad';
    status.textContent = message;
  }

  function sizeOf(bytes) {
    if (bytes < 1024) { return bytes + ' B'; }
    if (bytes < 1048576) { return (bytes / 1024).toFixed(1) + ' KB'; }
    if (bytes < 1073741824) { return (bytes / 1048576).toFixed(1) + ' MB'; }
    return (bytes / 1073741824).toFixed(2) + ' GB';
  }

  function esc(value) {
    var out = '';
    for (var i = 0; i < value.length; i++) {
      var c = value.charAt(i);
      if (c === '&') { out += '&amp;'; }
      else if (c === '<') { out += '&lt;'; }
      else if (c === '>') { out += '&gt;'; }
      else if (c === '"') { out += '&quot;'; }
      else { out += c; }
    }
    return out;
  }

  function show(data) {
    remember(data.sessionId);
    device.textContent = (text.sharedBy || 'Shared by') + ' ' + data.info.alias;
    var ids = Object.keys(data.files);
    status.className = '';
    status.textContent = (text.files || 'Files') + ' (' + ids.length + ')';
    var html = '';
    for (var i = 0; i < ids.length; i++) {
      var file = data.files[ids[i]];
      var href = API + '/download?sessionId=' + encodeURIComponent(data.sessionId)
        + '&fileId=' + encodeURIComponent(ids[i]);
      html += '<div class="file"><span class="name">' + esc(file.fileName) + '</span>'
        + '<span class="size">' + sizeOf(file.size) + '</span>'
        + '<a class="get" href="' + href + '">' + esc(text.download || 'Download') + '</a></div>';
    }
    list.innerHTML = html;
  }

  function request(pin, first) {
    status.className = '';
    status.textContent = text.waiting || 'Waiting for the phone to confirm';
    var qs = [];
    var id = recalled();
    if (id) { qs.push('sessionId=' + encodeURIComponent(id)); }
    if (pin) { qs.push('pin=' + encodeURIComponent(pin)); }
    var url = API + '/prepare-download' + (qs.length ? '?' + qs.join('&') : '');
    ask('POST', url, function (xhr) {
      if (xhr.status === 401) {
        var label = text.pin || 'PIN';
        var typed = window.prompt(first ? label : label + ' / ' + (text.badPin || 'Wrong PIN'));
        if (!typed) { bad(text.badPin || 'Wrong PIN'); return; }
        request(typed, false);
        return;
      }
      if (xhr.status === 403) { bad(text.rejected || 'Rejected on the phone'); return; }
      if (xhr.status === 409) { bad(text.busy || 'The phone is busy with another request'); return; }
      if (xhr.status === 429) { bad(text.tooMany || 'Too many wrong PIN attempts'); return; }
      if (xhr.status !== 200) { bad((text.failed || 'Request failed, status') + ' ' + xhr.status); return; }
      show(JSON.parse(xhr.responseText));
    });
  }

  ask('GET', '/i18n.json', function (xhr) {
    if (xhr.status === 200) {
      text = JSON.parse(xhr.responseText);
    }
    request(param('pin'), true);
  });
})();
</script>
</body>
</html>`;

/**
 * The upload form: while web receive is active, a browser posts files through the normal upload API,
 * with the PIN as its only credential.
 */
export const UPLOAD_PAGE: string = `<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LocalSend</title>
<style>
body { margin: 0; padding: 40px 16px 56px; background: #f2f3f5; color: #1c1d1f;
       font-family: system-ui, "HarmonyOS Sans SC", "PingFang SC", sans-serif; }
main { max-width: 560px; margin: 0 auto; text-align: center; }
h1 { font-size: 20px; margin: 0 0 18px; }
#drop { padding: 36px 18px 30px; background: #fff; border: 2px dashed #c9cdd3; border-radius: 14px; }
#drop.over { border-color: #00796b; background: #e0f2f1; }
#pick { padding: 12px 30px; font-size: 15px; color: #fff; background: #00796b; border: none;
        border-radius: 999px; cursor: pointer; }
#pick:active { background: #00695c; }
#pick:disabled { background: #9aa5a1; }
#hint { margin: 14px 0 0; font-size: 13px; color: #6b7076; }
#status { min-height: 20px; margin: 16px 0 0; font-size: 14px; color: #6b7076; }
#status.bad { color: #c62828; }
@media (prefers-color-scheme: dark) {
body { background: #16171a; color: #e9eaec; }
#drop { background: #232529; border-color: #4a4e54; }
#hint, #status { color: #9a9ea3; }
}
</style>
</head>
<body>
<main>
<h1>LocalSend</h1>
<div id="drop">
<button id="pick" type="button">Upload</button>
<p id="hint"></p>
<p id="status"></p>
</div>
<noscript><p>需要浏览器启用 JavaScript / JavaScript is required to upload files.</p></noscript>
</main>
<input id="files" type="file" multiple hidden>
<script>
(function () {
  var API = '/api/localsend/v2';
  var text = {};
  var pin = '';
  var busy = false;
  var depth = 0;
  var drop = document.getElementById('drop');
  var pick = document.getElementById('pick');
  var hint = document.getElementById('hint');
  var status = document.getElementById('status');

  function param(name) {
    var parts = location.search.slice(1).split('&');
    for (var i = 0; i < parts.length; i++) {
      var pair = parts[i].split('=');
      if (pair[0] === name) {
        return decodeURIComponent(pair.slice(1).join('=') || '');
      }
    }
    return '';
  }

  pin = param('pin');

  function say(message, bad) {
    status.className = bad ? 'bad' : '';
    status.textContent = message;
  }

  function ask(method, url, body, done) {
    var xhr = new XMLHttpRequest();
    xhr.open(method, url, true);
    xhr.onreadystatechange = function () {
      if (xhr.readyState === 4) { done(xhr); }
    };
    xhr.send(body === undefined ? null : body);
  }

  function fingerprint() {
    var stored = '';
    try { stored = sessionStorage.getItem('localsendFingerprint') || ''; } catch (e) {}
    if (stored) { return stored; }
    var made = 'web-';
    for (var i = 0; i < 32; i++) { made += Math.floor(Math.random() * 16).toString(16); }
    try { sessionStorage.setItem('localsendFingerprint', made); } catch (e) {}
    return made;
  }

  function stop(message) {
    busy = false;
    pick.disabled = false;
    say(message, true);
  }

  function prepare(files) {
    busy = true;
    pick.disabled = true;
    say(text.waiting || 'Waiting for the phone to confirm');
    var dto = {};
    for (var i = 0; i < files.length; i++) {
      dto[String(i)] = {
        id: String(i),
        fileName: files[i].name,
        size: files[i].size,
        fileType: files[i].type || 'application/octet-stream'
      };
    }
    var body = JSON.stringify({
      info: {
        alias: 'Web Browser',
        version: '2.2',
        deviceType: 'web',
        fingerprint: fingerprint(),
        port: 0,
        protocol: location.protocol === 'https:' ? 'https' : 'http',
        download: false
      },
      files: dto
    });
    offer(body, files, true);
  }

  function offer(body, files, first) {
    var url = API + '/prepare-upload' + (pin ? '?pin=' + encodeURIComponent(pin) : '');
    ask('POST', url, body, function (xhr) {
      if (xhr.status === 401) {
        var label = text.pin || 'PIN';
        var typed = window.prompt(first ? label : label + ' / ' + (text.badPin || 'Wrong PIN'));
        if (!typed) { stop(text.badPin || 'Wrong PIN'); return; }
        pin = typed;
        offer(body, files, false);
        return;
      }
      if (xhr.status === 403) { stop(text.uploadRejected || 'Rejected on the phone'); return; }
      if (xhr.status === 409) { stop(text.busy || 'The phone is busy with another request'); return; }
      if (xhr.status === 429) { stop(text.tooMany || 'Too many wrong PIN attempts'); return; }
      if (xhr.status === 204) { stop(text.uploadRejected || 'Rejected on the phone'); return; }
      if (xhr.status !== 200) { stop((text.failed || 'Request failed, status') + ' ' + xhr.status); return; }
      var answer = JSON.parse(xhr.responseText);
      send(answer.sessionId, answer.files, files, 0);
    });
  }

  function send(sessionId, tokens, files, index) {
    var ids = Object.keys(tokens);
    if (index >= ids.length) {
      busy = false;
      pick.disabled = false;
      say(text.uploadDone || 'Upload complete');
      return;
    }
    say((text.sending || 'Uploading') + ' ' + index + '/' + ids.length);
    var fileId = ids[index];
    var url = API + '/upload?sessionId=' + encodeURIComponent(sessionId)
      + '&fileId=' + encodeURIComponent(fileId) + '&token=' + encodeURIComponent(tokens[fileId]);
    ask('POST', url, files[Number(fileId)], function (xhr) {
      if (xhr.status !== 200) {
        stop((text.failed || 'Request failed, status') + ' ' + xhr.status);
        return;
      }
      send(sessionId, tokens, files, index + 1);
    });
  }

  function start(files) {
    if (files.length > 0 && !busy) { prepare(files); }
  }

  function hasFiles(e) {
    var types = e.dataTransfer && e.dataTransfer.types;
    if (!types) { return false; }
    for (var i = 0; i < types.length; i++) { if (types[i] === 'Files') { return true; } }
    return false;
  }

  function dropped(e) {
    var out = [];
    var items = e.dataTransfer.items;
    if (items && items.length > 0 && items[0].webkitGetAsEntry) {
      for (var i = 0; i < items.length; i++) {
        // Directories cannot be read as blobs, so uploading them would fail midway; skip them.
        var entry = items[i].webkitGetAsEntry();
        if (entry && entry.isDirectory) { continue; }
        var file = items[i].getAsFile();
        if (file) { out.push(file); }
      }
    } else {
      for (var j = 0; j < e.dataTransfer.files.length; j++) { out.push(e.dataTransfer.files[j]); }
    }
    return out;
  }

  var input = document.getElementById('files');
  pick.onclick = function () { input.click(); };
  input.onchange = function () {
    // FileList is live, and clearing the input empties it, so copy the File objects (snapshots)
    // out first; clearing right away also lets the same file be picked again later.
    var picked = [];
    for (var i = 0; i < input.files.length; i++) { picked.push(input.files[i]); }
    input.value = '';
    if (picked.length > 0) { start(picked); }
  };

  document.addEventListener('dragenter', function (e) {
    if (!hasFiles(e)) { return; }
    e.preventDefault();
    depth++;
    drop.className = 'over';
  });
  document.addEventListener('dragover', function (e) {
    if (!hasFiles(e)) { return; }
    e.preventDefault();
    e.dataTransfer.dropEffect = busy ? 'none' : 'copy';
  });
  document.addEventListener('dragleave', function (e) {
    if (!hasFiles(e)) { return; }
    depth--;
    if (depth <= 0) { depth = 0; drop.className = ''; }
  });
  document.addEventListener('drop', function (e) {
    if (!hasFiles(e)) { return; }
    e.preventDefault();
    depth = 0;
    drop.className = '';
    start(dropped(e));
  });

  ask('GET', '/i18n.json', null, function (xhr) {
    if (xhr.status === 200) {
      text = JSON.parse(xhr.responseText);
      pick.textContent = text.upload || 'Upload';
      hint.textContent = text.dropHint || '';
    }
  });
})();
</script>
</body>
</html>`;

/** Served with 403 while nothing is shared, so a stale bookmark explains itself. */
export const SHARING_OFF_PAGE: string = `<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LocalSend</title>
<style>
body { margin: 0; padding: 20vh 16px 0; text-align: center; background: #f2f3f5; color: #5f6469;
       font-family: system-ui, "HarmonyOS Sans SC", "PingFang SC", sans-serif; }
h1 { margin: 0 0 10px; font-size: 18px; color: #1c1d1f; }
p { margin: 0 0 4px; font-size: 14px; }
@media (prefers-color-scheme: dark) {
body { background: #16171a; color: #9a9ea3; }
h1 { color: #e9eaec; }
}
</style>
</head>
<body>
<h1>LocalSend</h1>
<p>这台设备当前没有开启网页传</p>
<p>This device is not sharing files right now.</p>
</body>
</html>`;

const ENGLISH: Map<string, string> = buildEnglish();
const CHINESE: Map<string, string> = buildChinese();

function buildEnglish(): Map<string, string> {
  const table: Map<string, string> = new Map<string, string>();
  table.set('sharedBy', 'Shared by');
  table.set('waiting', 'Waiting for the phone to confirm');
  table.set('pin', 'Enter the PIN');
  table.set('badPin', 'Wrong PIN');
  table.set('tooMany', 'Too many wrong PIN attempts');
  table.set('rejected', 'Rejected on the phone');
  table.set('busy', 'The phone is busy with another request');
  table.set('failed', 'Request failed, status');
  table.set('files', 'Files');
  table.set('download', 'Download');
  table.set('upload', 'Upload');
  table.set('dropHint', 'Drop files here, or click to choose');
  table.set('uploadRejected', 'The phone rejected this upload');
  table.set('uploadDone', 'Upload complete');
  table.set('sending', 'Uploading');
  return table;
}

function buildChinese(): Map<string, string> {
  const table: Map<string, string> = new Map<string, string>();
  table.set('sharedBy', '分享自');
  table.set('waiting', '等待手机确认');
  table.set('pin', '请输入 PIN');
  table.set('badPin', 'PIN 不正确');
  table.set('tooMany', 'PIN 尝试次数过多');
  table.set('rejected', '手机上拒绝了这次下载');
  table.set('busy', '手机上正有另一个请求待处理');
  table.set('failed', '请求失败，状态码');
  table.set('files', '可下载的文件');
  table.set('download', '下载');
  table.set('upload', '上传');
  table.set('dropHint', '把文件拖到这里，或点击选择');
  table.set('uploadRejected', '手机上拒绝了这次上传');
  table.set('uploadDone', '上传完成');
  table.set('sending', '正在上传');
  return table;
}

/**
 * The translations for one request, chosen from its `Accept-Language`.
 *
 * The browser is the reader here, not the phone, so a German browser gets German words even though
 * the app itself is Chinese. Chinese is the fallback: it is what the phone's own user reads.
 */
export function webText(acceptLanguage: string): Map<string, string> {
  const raw: string = acceptLanguage.toLowerCase();
  if (raw.indexOf('zh') >= 0) {
    return CHINESE;
  }
  return ENGLISH;
}
