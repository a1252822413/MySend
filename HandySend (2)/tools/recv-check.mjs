// Protocol-level receiver test: speaks the LocalSend v2.2 sender API against the
// HarmonyOS app running on the emulator (reached through `hdc fport`).
import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';
import fs from 'node:fs';

const HOST = '127.0.0.1';
const PORT = 53317;
const USE_TLS = process.env.LS_TLS === '1';
const BASE = `/api/localsend/v2`;
const MY_FINGERPRINT = 'TESTSENDER00000000000000000000000000000000000000000000000000000A';

const info = {
  alias: 'Node test sender',
  version: '2.2',
  deviceModel: 'PC',
  deviceType: 'desktop',
  fingerprint: MY_FINGERPRINT,
  port: PORT,
  protocol: USE_TLS ? 'https' : 'http',
  download: false,
};

const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8' };

function request(method, path, body, extraHeaders) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const payload = body === undefined ? null : typeof body === 'string' ? Buffer.from(body, 'utf8') : body;
    const headers = { ...JSON_HEADERS, ...(extraHeaders || {}) };
    if (payload !== null) headers['content-length'] = payload.length;
    const transport = USE_TLS ? https : http;
    const options = { host: HOST, port: PORT, method, path, headers, rejectUnauthorized: false };
    const req = transport.request(options, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () =>
        resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8'), ms: Date.now() - started })
      );
    });
    req.on('error', reject);
    if (payload !== null) req.write(payload);
    req.end();
  });
}

function fileMeta(id, fileName, bytes) {
  return {
    id,
    fileName,
    size: bytes.length,
    fileType: 'application/octet-stream',
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
  };
}

function prepareBody(files) {
  const map = {};
  for (const f of files) map[f.id] = f;
  return JSON.stringify({ info, files: map });
}

const results = [];
function check(name, ok, detail) {
  results.push({ name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
}

const octet = { 'content-type': 'application/octet-stream' };

async function main() {
  // 1. register + info are the discovery answers a peer relies on.
  //    The body is the flat device info, and the reply is the *server's* own info.
  const reg = await request('POST', `${BASE}/register`, JSON.stringify(info));
  const regBody = JSON.parse(reg.body);
  check('register answers with our own device info',
    reg.status === 200 && regBody.version === '2.2' && regBody.deviceType === 'mobile' && !!regBody.fingerprint,
    reg.body.slice(0, 120));
  const inf = await request('GET', `${BASE}/info`);
  check('info endpoint', inf.status === 200 && JSON.parse(inf.body).download === false, inf.body.slice(0, 120));

  // 2. an empty file map is refused before the user is bothered.
  const empty = await request('POST', `${BASE}/prepare-upload`, prepareBody([]));
  check('empty offer -> 400 No files provided', empty.status === 400 && /No files/.test(empty.body),
    `${empty.status} ${empty.body}`);

  // 3. traversal in a file name fails the offer.
  const evil = [fileMeta('e1', '../../escape.txt', Buffer.from('x'))];
  const bad = await request('POST', `${BASE}/prepare-upload`, prepareBody(evil));
  check('path traversal -> 400', bad.status === 400, `${bad.status} ${bad.body}`);

  // 4. a real offer: small file, chinese name with a count suffix, nested folder path.
  const small = Buffer.from('localsend harmony next 接收测试\n'.repeat(3));
  const big = crypto.randomBytes(3 * 1024 * 1024);
  const nested = Buffer.from('inner file of a folder transfer');
  const files = [
    fileMeta('f1', 'hello.txt', small),
    fileMeta('f2', '中文 照片 (1).txt', big),
    fileMeta('f3', '我的文件夹/子目录/inner.txt', nested),
  ];
  const payloads = { f1: small, f2: big, f3: nested };

  console.log('… waiting for the user to accept the offer on screen');
  const prepare = await request('POST', `${BASE}/prepare-upload`, prepareBody(files));
  check('prepare-upload accepted', prepare.status === 200, `${prepare.status} ${prepare.body.slice(0, 200)}`);
  if (prepare.status !== 200) return finish();
  const { sessionId, files: tokens } = JSON.parse(prepare.body);
  check('three tokens issued', Object.keys(tokens).length === 3, JSON.stringify(tokens).slice(0, 160));

  // 5. a wrong token is refused, and the session stays usable.
  const wrong = await request('POST', `${BASE}/upload?sessionId=${sessionId}&fileId=f1&token=not-the-token`,
    Buffer.from('x'), octet);
  check('bad token -> 403', wrong.status === 403 && /Invalid token/.test(wrong.body), `${wrong.status} ${wrong.body}`);

  // 6. checksum mismatch -> 422, and the same file may then be retried with the same token.
  //    Same byte count, different content: a size mismatch would be terminal, not retryable.
  const broken = Buffer.from('x'.repeat(small.length));
  const mismatch = await request('POST', `${BASE}/upload?sessionId=${sessionId}&fileId=f1&token=${tokens.f1}`,
    broken, octet);
  check('checksum mismatch -> 422', mismatch.status === 422 && /Checksum/.test(mismatch.body),
    `${mismatch.status} ${mismatch.body}`);

  for (const id of ['f1', 'f2', 'f3']) {
    const up = await request('POST', `${BASE}/upload?sessionId=${sessionId}&fileId=${id}&token=${tokens[id]}`,
      payloads[id], octet);
    check(id === 'f1' ? `retry after 422 -> 200` : `upload ${id} -> 200`, up.status === 200,
      `${up.status} ${up.body} ${up.ms}ms`);
  }

  // 7. once every file is final the slot must be free again: a new offer gets a decision, not 409.
  console.log('… waiting for the second offer to be declined');
  const again = await request('POST', `${BASE}/prepare-upload`, prepareBody([files[0]]));
  check('slot freed after completion', again.status === 403 && /Rejected/.test(again.body),
    `${again.status} ${again.body}`);

  // 8. while an offer is on screen a second sender is blocked.
  console.log('… waiting for the third offer, which stays unanswered');
  const hold = request('POST', `${BASE}/prepare-upload`, prepareBody([files[1]]));
  await new Promise((r) => setTimeout(r, 1500));
  const concurrent = await request('POST', `${BASE}/prepare-upload`, prepareBody([files[0]]));
  check('second sender during a pending decision -> 409', concurrent.status === 409 && /another session/.test(concurrent.body),
    `${concurrent.status} ${concurrent.body}`);
  // A sender that is still waiting for the prepare-upload answer cancels without a session id.
  const cancel = await request('POST', `${BASE}/cancel`);
  check('session-less cancel accepted', cancel.status === 200, `${cancel.status} ${cancel.body}`);
  const declined = await hold;
  check('held offer ends as cancelled by sender', declined.status === 403 && /Cancelled/.test(declined.body),
    `${declined.status} ${declined.body}`);

  return finish();
}

function finish() {
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) console.log('failures: ' + failed.map((f) => f.name).join(', '));
  fs.writeFileSync('/tmp/lsrecv-result.json', JSON.stringify(results, null, 2));
  process.exit(failed.length ? 1 : 0);
}

main().catch((e) => {
  console.error('script error: ' + e.message + '\n' + e.stack);
  finish();
});
