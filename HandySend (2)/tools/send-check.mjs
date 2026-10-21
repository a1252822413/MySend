// Mock LocalSend v2.2 *receiver*, used to verify our ArkTS sender from the other side of the wire.
//
// It answers register / prepare-upload / upload / cancel and asserts the parts of the contract the
// official clients depend on: the flat register body, the nested prepare info, per-file lowercase
// sha256 against the bytes we actually pushed to the device, Content-Length framing, at most
// UPLOAD_CONCURRENCY parallel bodies, and that a 422 is retried with the same token.
//
//   node tools/send-check.mjs --port 53318
//   node tools/send-check.mjs --pin 1234 --skip b.bin --fail-first-on a.txt
//   node tools/send-check.mjs --expect-cancel
//
// The files it hashes must already be on the device; prepare them with:
//   node tools/send-check.mjs --make-fixtures   (writes /tmp/ls-send-test)
//   hdc file send /tmp/ls-send-test/<name> /storage/media/100/local/files/Docs/Download/<name>
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const FIXTURE_DIR = '/tmp/ls-send-test';
const args = process.argv.slice(2);

function flag(name) {
  return args.includes(`--${name}`);
}
function value(name, fallback) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : fallback;
}

const PORT = Number(value('port', '53318'));
const REQUIRED_PIN = value('pin', null);
const SKIP_NAME = value('skip', null);
const FAIL_FIRST_NAME = value('fail-first-on', null);
const EXPECT_CANCEL = flag('expect-cancel');
/** Per-chunk pause in ms; a fast local link otherwise finishes before a cancel can be tapped. */
const THROTTLE_MS = Number(value('throttle', '0'));

if (flag('make-fixtures')) {
  fs.mkdirSync(FIXTURE_DIR, { recursive: true });
  fs.writeFileSync(path.join(FIXTURE_DIR, 'a.txt'), 'alpha-payload-for-send-check\n');
  const big = Buffer.alloc(3 * 1024 * 1024);
  for (let k = 0; k * 8 < big.length; k++) {
    big.writeUInt32LE(k >>> 0, k * 8);
    big.writeUInt32LE((k * 2654435761) >>> 0, k * 8 + 4);
  }
  fs.writeFileSync(path.join(FIXTURE_DIR, 'b.bin'), big);
  for (const entry of fs.readdirSync(FIXTURE_DIR)) {
    const bytes = fs.readFileSync(path.join(FIXTURE_DIR, entry));
    console.log(`${entry}\t${bytes.length}\t${crypto.createHash('sha256').update(bytes).digest('hex')}`);
  }
  process.exit(0);
}

const expected = new Map();
for (const entry of fs.readdirSync(FIXTURE_DIR)) {
  const bytes = fs.readFileSync(path.join(FIXTURE_DIR, entry));
  expected.set(entry, { size: bytes.length, sha256: crypto.createHash('sha256').update(bytes).digest('hex') });
}

const results = [];
function check(name, ok, detail) {
  results.push({ name, ok: Boolean(ok), detail: detail === undefined ? '' : String(detail).slice(0, 200) });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail === undefined ? '' : `  — ${String(detail).slice(0, 160)}`}`);
}

const MOCK_INFO = {
  alias: 'MockReceiver', version: '2.2', deviceModel: 'Mac', deviceType: 'desktop',
  fingerprint: 'MOCKRECEIVER0000000000000000000000000000000000000000000000000000', download: false,
};

const state = {
  registered: false,
  sessionId: '',
  /** fileName -> { fileId, token, sha256, size, attempts, finished } */
  files: new Map(),
  inFlight: 0,
  maxInFlight: 0,
  cancelled: null,
  prepareSeen: false,
  done: false,
};

function readBody(req, limit, onChunk) {
  return new Promise((resolve, reject) => {
    let total = 0;
    req.on('data', (buf) => {
      total += buf.length;
      if (total > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      if (onChunk !== undefined) {
        onChunk(buf);
      }
    });
    req.on('end', () => resolve(total));
    req.on('error', reject);
  });
}

/**
 * Drains the body one pause/resume per chunk, so a fast local link still leaves a window in which
 * the sender can be cancelled mid-transfer.
 */
function readBodySlowly(req, limit, onChunk, stepMs) {
  return new Promise((resolve, reject) => {
    let total = 0;
    req.on('data', (buf) => {
      total += buf.length;
      if (total > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      onChunk(buf);
      req.pause();
      setTimeout(() => req.resume(), stepMs);
    });
    req.on('end', () => resolve(total));
    req.on('error', reject);
  });
}

function json(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(body) });
  res.end(body);
}

/** Things the wire can only show once the exchange is over. */
function finalChecks() {
  check('at most two upload streams run in parallel', state.maxInFlight <= 2, `peak ${state.maxInFlight}`);
  if (SKIP_NAME !== null) {
    const skipped = state.files.get(SKIP_NAME);
    check(`an unaccepted file is never uploaded`, skipped !== undefined && skipped.attempts === 0,
      skipped === undefined ? 'never offered' : `${skipped.attempts} upload attempt(s)`);
  }
  if (EXPECT_CANCEL) {
    check('a cancel arrived', state.cancelled !== null, `cancelled=${String(state.cancelled)}`);
  }
  if (state.prepareSeen && !EXPECT_CANCEL) {
    let missing = [];
    state.files.forEach((file, name) => {
      if (!file.skipped && !file.finished) {
        missing.push(name);
      }
    });
    check('every accepted file landed', missing.length === 0, missing.join(', '));
  }
}

function finish(server) {
  if (state.done) {
    return;
  }
  state.done = true;
  finalChecks();
  server.close();
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    console.log(`failures: ${failed.map((f) => f.name).join(', ')}`);
  }
  fs.writeFileSync('/tmp/ls-send-result.json', JSON.stringify(results, null, 2));
  process.exit(failed.length ? 1 : 0);
}

/** Called after every upload answer: the send is over once each accepted file landed. */
function maybeComplete(server) {
  if (EXPECT_CANCEL) {
    return;
  }
  let pending = 0;
  state.files.forEach((file) => {
    if (!file.skipped && !file.finished) {
      pending++;
    }
  });
  if (pending === 0 && state.prepareSeen && state.files.size > 0) {
    setTimeout(() => finish(server), 1500);
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  const route = url.pathname.split('/').pop();

  if (req.method === 'POST' && route === 'register') {
    const chunks = [];
    await readBody(req, 1024 * 1024, (buf) => chunks.push(buf));
    const body = Buffer.concat(chunks).toString('utf-8');
    let payload = null;
    try {
      payload = JSON.parse(body);
    } catch (e) {
      /* reported below */
    }
    check('register arrives with a flat device body',
      payload !== null && typeof payload.alias === 'string' && payload.alias.length > 0
        && typeof payload.version === 'string' && typeof payload.fingerprint === 'string'
        && payload.info === undefined,
      payload === null ? body.slice(0, 80) : `alias=${payload.alias} version=${payload.version} fp=${String(payload.fingerprint).slice(0, 12)}…`);
    check('register announces a reachable port and scheme',
      payload !== null && typeof payload.port === 'number' && payload.port > 0
        && (payload.protocol === 'http' || payload.protocol === 'https'),
      payload === null ? '' : `port=${payload.port} protocol=${payload.protocol}`);
    state.registered = true;
    json(res, 200, MOCK_INFO);
    return;
  }

  if (req.method === 'POST' && route === 'prepare-upload') {
    state.prepareSeen = true;
    const chunks = [];
    await readBody(req, 4 * 1024 * 1024, (buf) => chunks.push(buf));
    let payload = null;
    try {
      payload = JSON.parse(Buffer.concat(chunks).toString('utf-8'));
    } catch (e) {
      check('prepare-upload body parses', false, e.message);
      json(res, 400, { message: 'Invalid body' });
      return;
    }
    check('prepare-upload carries nested info plus files',
      payload.info !== undefined && payload.info.alias !== undefined && payload.files !== undefined,
      `info.alias=${payload.info && payload.info.alias}`);

    if (REQUIRED_PIN !== null) {
      const provided = url.searchParams.get('pin');
      if (provided === null) {
        check('prepare-upload asks for the PIN first', true, 'no pin -> 401');
        json(res, 401, { message: 'PIN required' });
        return;
      }
      check('PIN arrives as a query parameter', provided === REQUIRED_PIN, `provided=${provided}`);
      if (provided !== REQUIRED_PIN) {
        json(res, 401, { message: 'Invalid PIN' });
        return;
      }
    }

    const names = [];
    let shapeOk = true;
    let tokensOk = true;
    let sizesOk = true;
    Object.keys(payload.files).forEach((fileId) => {
      const file = payload.files[fileId];
      names.push(file.fileName);
      if (file.id !== fileId || typeof file.fileName !== 'string' || typeof file.size !== 'number'
        || typeof file.fileType !== 'string') {
        shapeOk = false;
      }
      if (!/^[0-9a-f]{64}$/.test(String(file.sha256))) {
        tokensOk = false;
      }
      const want = expected.get(file.fileName);
      if (want === undefined || want.size !== file.size || want.sha256 !== file.sha256) {
        sizesOk = false;
      }
      state.files.set(file.fileName, {
        fileId, sha256: file.sha256, size: file.size, attempts: 0, finished: false,
        skipped: SKIP_NAME === file.fileName,
      });
    });
    check('every file id matches its map key and shape', shapeOk, names.join(', '));
    check('every sha256 is 64 lowercase hex', tokensOk, Object.values(payload.files).map((f) => String(f.sha256)).join(' ').slice(0, 80));
    check('sizes and checksums match the bytes on the device', sizesOk, names.join(', '));
    check('fileType is a real content type', Object.values(payload.files).every((f) => String(f.fileType).includes('/')),
      Object.values(payload.files).map((f) => f.fileType).join(', '));

    state.sessionId = crypto.randomUUID();
    const tokens = {};
    state.files.forEach((file, name) => {
      if (!file.skipped) {
        file.token = crypto.randomUUID();
        tokens[file.fileId] = file.token;
      }
    });
    if (SKIP_NAME !== null) {
      check('one file is deliberately left unaccepted', state.files.has(SKIP_NAME), SKIP_NAME);
    }
    json(res, 200, { sessionId: state.sessionId, files: tokens });
    console.log(`… offer accepted, ${Object.keys(tokens).length} token(s) issued (skipped: ${SKIP_NAME ?? 'none'})`);
    return;
  }

  if (req.method === 'POST' && route === 'upload') {
    const fileId = url.searchParams.get('fileId');
    const token = url.searchParams.get('token');
    const sessionId = url.searchParams.get('sessionId');
    let target = null;
    state.files.forEach((file) => {
      if (file.fileId === fileId) {
        target = file;
      }
    });

    check('upload names a session and a token we issued',
      target !== null && sessionId === state.sessionId && token === target.token,
      `sessionId=${String(sessionId).slice(0, 8)}… fileId=${fileId}`);
    check('upload is framed with Content-Length, not chunked',
      req.headers['content-length'] !== undefined && req.headers['transfer-encoding'] === undefined,
      `content-length=${req.headers['content-length']} transfer-encoding=${req.headers['transfer-encoding']}`);

    state.inFlight++;
    state.maxInFlight = Math.max(state.maxInFlight, state.inFlight);
    if (target === null) {
      await readBody(req, 64 * 1024 * 1024).catch(() => undefined);
      state.inFlight--;
      json(res, 403, { message: 'Invalid token' });
      return;
    }
    target.attempts++;
    const sha = crypto.createHash('sha256');
    let received = 0;
    try {
      received = await (THROTTLE_MS > 0
        ? readBodySlowly(req, 64 * 1024 * 1024, (buf) => sha.update(buf), THROTTLE_MS)
        : readBody(req, 64 * 1024 * 1024, (buf) => sha.update(buf)));
    } catch (e) {
      state.inFlight--;
      check(`upload ${fileId} body readable`, false, e.message);
      res.writeHead(400).end();
      return;
    }
    state.inFlight--;

    const digest = sha.digest('hex');
    const attempt = target.attempts;
    if (FAIL_FIRST_NAME !== null && target === state.files.get(FAIL_FIRST_NAME) && attempt === 1) {
      console.log(`… forcing one 422 for ${FAIL_FIRST_NAME}`);
      res.writeHead(422, { 'content-type': 'application/json', 'content-length': '26' });
      res.end(JSON.stringify({ message: 'Checksum mismatch' }));
      state.pendingRetry = target;
      return;
    }

    check(`body of ${target.sha256.slice(0, 8)}… matches its metadata`,
      digest === target.sha256 && received === target.size,
      `${received}/${target.size} bytes, got ${digest.slice(0, 16)}… want ${target.sha256.slice(0, 16)}…`);
    if (state.pendingRetry === target) {
      check('a 422 is retried with the same token', attempt === 2, `attempt ${attempt}`);
      state.pendingRetry = null;
    }
    target.finished = digest === target.sha256;
    res.writeHead(200, { 'content-length': '0' });
    res.end();
    maybeComplete(server);
    return;
  }

  if (req.method === 'POST' && route === 'cancel') {
    const sessionId = url.searchParams.get('sessionId');
    state.cancelled = sessionId === null ? '' : sessionId;
    check('cancel names the session it is aborting', sessionId === state.sessionId,
      `sessionId=${String(sessionId)} issued=${String(state.sessionId)}`);
    json(res, 200, {});
    if (EXPECT_CANCEL) {
      setTimeout(() => finish(server), 1000);
    }
    return;
  }

  res.writeHead(404, { 'content-length': '0' });
  res.end();
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`mock receiver listening on 0.0.0.0:${PORT}`);
  console.log(`in the app: add host http://10.0.2.2:${PORT}, discover it, pick ${[...expected.keys()].join(', ')}`);
  console.log(`pin=${REQUIRED_PIN ?? 'none'} skip=${SKIP_NAME ?? 'none'} failFirst=${FAIL_FIRST_NAME ?? 'none'} expectCancel=${EXPECT_CANCEL} throttle=${THROTTLE_MS}ms`);
});

setTimeout(() => {
  check('the sender reached the mock receiver', state.registered || state.prepareSeen, 'timeout after 120s');
  finish(server);
}, 120000);

process.on('SIGINT', () => finish(server));
