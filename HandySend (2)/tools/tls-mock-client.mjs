// Mimics an official LocalSend *client* over mTLS: presents a self-signed certificate and
// trusts the server by fingerprint rather than by CA. Used to prove our ArkTS TLS server
// completes a handshake when it requests a client certificate nobody's trust store knows.
//   node tools/tls-mock-client.mjs [host] [port]
import tls from 'node:tls';
import fs from 'node:fs';
import crypto from 'node:crypto';

const HOST = process.argv[2] || '127.0.0.1';
const PORT = Number(process.argv[3] || 153317);
const BASE = '/api/localsend/v2';

const cert = fs.readFileSync('/tmp/mock.crt');
const key = fs.readFileSync('/tmp/mock.key');
const claimed = crypto.createHash('sha256').update(new crypto.X509Certificate(cert).raw).digest('hex').toUpperCase();

const info = {
  alias: 'Node mTLS client',
  version: '2.2',
  deviceModel: 'PC',
  deviceType: 'desktop',
  fingerprint: claimed,
  port: PORT,
  protocol: 'https',
  download: false,
};

const socket = tls.connect({ host: HOST, port: PORT, cert, key, rejectUnauthorized: false, ALPNProtocols: ['http/1.1'] });

let buffer = '';
let onBody = (reply) => {};

socket.on('secureConnect', () => {
  const peer = socket.getPeerCertificate();
  console.log(`handshake ok · alpn=${socket.alpnProtocol || 'none'} · tls=${socket.getProtocol()} · ` +
    `cipher=${socket.getCipher().name}`);
  console.log(`server cert fingerprint ${String(peer.fingerprint256).toUpperCase().replace(/:/g, '')}`);
  step();
});

socket.on('data', (buf) => {
  buffer += buf.toString('binary');
  const at = buffer.indexOf('\r\n\r\n');
  if (at < 0) return;
  const head = buffer.slice(0, at);
  const length = Number((head.match(/content-length: (\d+)/i) || [])[1] || 0);
  if (Buffer.byteLength(buffer.slice(at + 4), 'binary') < length) return;
  const body = Buffer.from(buffer.slice(at + 4, at + 4 + length), 'binary').toString('utf8');
  buffer = buffer.slice(at + 4 + length);
  onBody({ status: Number(head.split(' ')[1]), body });
});

socket.on('error', (e) => console.log('client error: ' + e.message));

function call(name, method, path, body) {
  return new Promise((resolve) => {
    console.log(`… ${name}`);
    onBody = (reply) => {
      console.log(`${name} -> ${reply.status} ${reply.body.slice(0, 140)}`);
      resolve(reply);
    };
    const payload = body === undefined ? '' : JSON.stringify(body);
    socket.write(`${method} ${path} HTTP/1.1\r\nhost: ${HOST}\r\ncontent-type: application/json; charset=utf-8` +
      `\r\ncontent-length: ${Buffer.byteLength(payload)}\r\nconnection: keep-alive\r\n\r\n${payload}`);
  });
}

async function step() {
  const bytes = Buffer.from('tls spike payload\n');
  const sha = crypto.createHash('sha256').update(bytes).digest('hex');
  await call('GET info', 'GET', `${BASE}/info`);
  await call('POST register', 'POST', `${BASE}/register`, info);
  const prepared = await call('POST prepare-upload', 'POST', `${BASE}/prepare-upload`, {
    info,
    files: { s1: { id: 's1', fileName: 'tls.txt', size: bytes.length, fileType: 'text/plain', sha256: sha } },
  });
  if (prepared.status === 200) {
    // An offer we are not going to answer on screen: withdraw it, like a sender would.
    await call('POST cancel', 'POST', `${BASE}/cancel`);
  }
  socket.end();
}
