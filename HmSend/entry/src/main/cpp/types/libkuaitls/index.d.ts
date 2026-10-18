// libkuaitls.so 的类型声明（对应 cpp/tls_server.cpp）

export const start: (
  port: number,
  certPem: string,
  keyPem: string,
  onConnect: (connId: number) => void,
  onData: (connId: number, data: ArrayBuffer) => void,
  onClose: (connId: number) => void
) => boolean;

export const send: (connId: number, data: ArrayBuffer) => boolean;

export const closeConn: (connId: number) => void;

export const stop: () => void;

export const version: () => string;
