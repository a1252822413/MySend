// Uploads one self-describing file over TLS so the bytes that land in the app sandbox can be
// diffed against the pattern. 16 KiB blocks, each headed by its own index.
import https from 'node:https';
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';

const HOST = '127.0.0.1';
const PORT = 53317;
const BLOCK = 16384;
const BLOCKS = Number(process.env.LS_BLOCKS || 192);
const NAME = process.env.LS_NAME || 'probe.bin';
const PLAIN = process.env.LS_TLS !== '1';

const info = {
  alias: 'Node probe', version: '2.2', deviceModel: 'PC', deviceType: 'desktop',
  fingerprint: 'PROBE000000000000000000000000000000000000000000000000000000A',
  port: PORT, protocol: PLAIN ? 'http' : 'https', download: false,
};

const body = Buffer.alloc(BLOCK * BLOCKS);
// Every 8-byte slot carries its own index, so any 8 bytes in the stream identify their position.
for (let k = 0; k * 8 < body.length; k++) body.writeUInt32LE(k, k * 8);
for (let i = 0; i < body.length; i++) if (i % 8 >= 4) body[i] = (i / 8 | 0) % 251;
const digest = crypto.createHash('sha256').update(body).digest('hex');

function request(method, path, payload, headers) {
  return new Promise((resolve, reject) => {
    const opts = {
      host: HOST, port: PORT, method, path,
      headers: { 'content-type': 'application/json; charset=utf-8', ...(headers || {}) },
      rejectUnauthorized: false,
    };
    if (payload) opts.headers['content-length'] = payload.length;
    const req = (PLAIN ? http : https).request(opts, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function main() {
  const file = {
    id: 'p1', fileName: NAME, size: body.length,
    fileType: 'application/octet-stream', sha256: digest,
  };
  console.log(`probe ${NAME} ${body.length} bytes, sha256 ${digest.slice(0, 16)}…`);
  const prepare = await request('POST', '/api/localsend/v2/prepare-upload',
    Buffer.from(JSON.stringify({ info, files: { p1: file } }), 'utf8'));
  if (prepare.status !== 200) {
    console.log(`prepare failed: ${prepare.status} ${prepare.body}`);
    return;
  }
  const { sessionId, files } = JSON.parse(prepare.body);
  console.log(`session ${sessionId}, uploading…`);
  const up = await request('POST',
    `/api/localsend/v2/upload?sessionId=${sessionId}&fileId=p1&token=${files.p1}`, body,
    { 'content-type': 'application/octet-stream' });
  console.log(`upload -> ${up.status} ${up.body}`);
  console.log(`expected sha256 ${digest}`);
  fs.writeFileSync('/tmp/probe-expected.bin', body);
}

main();
