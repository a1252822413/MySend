// Mimics an official LocalSend server over TLS: self-signed certificate, client certificate
// requested and accepted without chain validation (LocalSend pins fingerprints instead of CAs).
// Used to prove our ArkTS TLS *client* can complete an mTLS handshake with that trust model.
import tls from 'node:tls';
import fs from 'node:fs';
import crypto from 'node:crypto';

const PORT = Number(process.argv[2] || 53318);
const ALIAS = 'Mock LocalSend (host)';

const key = fs.readFileSync('/tmp/mock.key');
const cert = fs.readFileSync('/tmp/mock.crt');
// LocalSend fingerprints are SHA-256 over the DER, not the PEM.
const fingerprint = crypto.createHash('sha256').update(new crypto.X509Certificate(cert).raw).digest('hex').toUpperCase();

const info = {
  alias: ALIAS,
  version: '2.2',
  deviceModel: 'Mac',
  deviceType: 'desktop',
  fingerprint,
  download: true,
};

const server = tls.createServer(
  { key, cert, requestCert: true, rejectUnauthorized: false },
  (socket) => {
    const peer = socket.getPeerCertificate();
    console.log(
      `handshake ok · alpn=${socket.getAlpnProtocol() || 'none'} · ${socket.getCipher().name} · ` +
        `tls=${socket.getProtocol()} · client cert subject=${JSON.stringify(peer.subject)} ` +
        `fingerprint256=${peer.fingerprint256}`
    );
    // HTTP/1.1 without a parser: the probe only needs register/info replies.
    socket.on('data', (buf) => {
      const text = buf.toString('utf8');
      if (text.includes('/register')) {
        console.log('register from the emulator:', text.split('\r\n\r\n')[1] || '(empty body)');
        sendRaw(socket, info);
      } else if (text.includes('/info')) {
        sendRaw(socket, info);
      } else {
        sendRaw(socket, { message: 'mock' }, 404);
      }
    });
    socket.on('error', (e) => console.log('socket error: ' + e.message));
  }
);

function sendRaw(socket, payload, status = 200) {
  const body = JSON.stringify(payload);
  socket.write(
    `HTTP/1.1 ${status} OK\r\ncontent-type: application/json; charset=utf-8\r\ncontent-length: ${Buffer.byteLength(body)}\r\nconnection: keep-alive\r\n\r\n${body}`
  );
}

server.listen(PORT, '0.0.0.0', () => {
  console.log(`mock LocalSend https server on :${PORT}, fingerprint ${fingerprint.slice(0, 16)}…`);
});
