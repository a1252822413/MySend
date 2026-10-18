// 鸿蒙 NAPI TLS 传输层。
//
// 为什么需要它：鸿蒙自带的 TLSSocketServer 在多记录大 body 上会丢最后一段
// （详见 docs/harmonyos-app-design.md §11.2），无法承载文件传输；而 SDK 又没有
// 官方 HTTP(S) 服务端。这里用 @ohos-rs/openssl（预编译 OpenSSL）+ NAPI 自建一层
// "TLS 字节泵"：C++ 负责监听/握手/加解密，解密后的明文通过 threadsafe function
// 推给 ArkTS，ArkTS 侧继续用原有的 HttpSession 解析 HTTP，协议逻辑零改动。
//
// 线程模型：
//   · accept 线程：accept → 起一条连接线程
//   · 连接线程：SSL_accept → 循环 SSL_read → TSFN 投递 (connId, bytes)
//   · JS 线程：send() → SSL_write；closeConn() → shutdown(fd) 让读线程退出
// OpenSSL 1.1+ 自带内部锁，同一 SSL 对象上"读线程 + 写线程"可并存。

#include <napi/native_api.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace {

struct Conn {
  int32_t id = 0;
  int fd = -1;
  SSL *ssl = nullptr;
  std::atomic<bool> shutting{false};
};

// 投递给 JS 的数据块
struct DataMsg {
  int32_t id = 0;
  std::string bytes;
};

SSL_CTX *g_ctx = nullptr;
int g_listenFd = -1;
std::thread g_acceptThread;
std::atomic<bool> g_running{false};
std::atomic<int32_t> g_nextId{1};
std::atomic<int32_t> g_activeConns{0};

std::mutex g_connsMu;
std::map<int32_t, std::shared_ptr<Conn>> g_conns;

napi_threadsafe_function g_tsfnConnect = nullptr;
napi_threadsafe_function g_tsfnData = nullptr;
napi_threadsafe_function g_tsfnClose = nullptr;

// ---------------- TSFN 回调（在 JS 线程执行） ----------------

void CallJsConnect(napi_env env, napi_value jsCb, void * /*context*/, void *data) {
  int32_t id = static_cast<int32_t>(reinterpret_cast<intptr_t>(data));
  napi_value argv[1];
  napi_create_int32(env, id, &argv[0]);
  napi_value undef = nullptr;
  napi_get_undefined(env, &undef);
  napi_call_function(env, undef, jsCb, 1, argv, nullptr);
}

void CallJsData(napi_env env, napi_value jsCb, void * /*context*/, void *data) {
  auto *msg = static_cast<DataMsg *>(data);
  if (msg == nullptr) {
    return;
  }
  napi_value argv[2];
  napi_create_int32(env, msg->id, &argv[0]);
  void *buf = nullptr;
  napi_value ab = nullptr;
  napi_create_arraybuffer(env, msg->bytes.size(), &buf, &ab);
  if (buf != nullptr && !msg->bytes.empty()) {
    std::memcpy(buf, msg->bytes.data(), msg->bytes.size());
  }
  argv[1] = ab;
  napi_value undef = nullptr;
  napi_get_undefined(env, &undef);
  napi_call_function(env, undef, jsCb, 2, argv, nullptr);
  delete msg;
}

void CallJsClose(napi_env env, napi_value jsCb, void * /*context*/, void *data) {
  int32_t id = static_cast<int32_t>(reinterpret_cast<intptr_t>(data));
  napi_value argv[1];
  napi_create_int32(env, id, &argv[0]);
  napi_value undef = nullptr;
  napi_get_undefined(env, &undef);
  napi_call_function(env, undef, jsCb, 1, argv, nullptr);
}

napi_status MakeTsfn(napi_env env, napi_value cb, const char *name,
                     napi_threadsafe_function_call_js callJs,
                     napi_threadsafe_function *out) {
  napi_value resourceName = nullptr;
  napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resourceName);
  return napi_create_threadsafe_function(env, cb, nullptr, resourceName,
                                        0, 1, nullptr, nullptr, nullptr, callJs, out);
}

void EmitConnect(int32_t id) {
  auto fn = g_tsfnConnect;
  if (fn != nullptr) {
    napi_call_threadsafe_function(fn, reinterpret_cast<void *>(static_cast<intptr_t>(id)),
                                 napi_tsfn_nonblocking);
  }
}

void EmitClose(int32_t id) {
  auto fn = g_tsfnClose;
  if (fn != nullptr) {
    napi_call_threadsafe_function(fn, reinterpret_cast<void *>(static_cast<intptr_t>(id)),
                                 napi_tsfn_nonblocking);
  }
}

void EmitData(int32_t id, const char *data, int len) {
  auto fn = g_tsfnData;
  if (fn == nullptr) {
    return;
  }
  auto *msg = new DataMsg();
  msg->id = id;
  msg->bytes.assign(data, static_cast<size_t>(len));
  napi_status st = napi_call_threadsafe_function(fn, msg, napi_tsfn_nonblocking);
  if (st != napi_ok) {
    delete msg;
  }
}

// ---------------- 连接处理 ----------------

void RemoveConn(int32_t id) {
  std::lock_guard<std::mutex> lock(g_connsMu);
  g_conns.erase(id);
}

void ConnLoop(std::shared_ptr<Conn> conn) {
  int32_t id = conn->id;
  char buf[16384];
  bool handshakeOk = false;

  conn->ssl = SSL_new(g_ctx);
  if (conn->ssl != nullptr) {
    SSL_set_fd(conn->ssl, conn->fd);
    if (SSL_accept(conn->ssl) > 0) {
      handshakeOk = true;
    }
  }

  if (handshakeOk) {
    EmitConnect(id);
    while (g_running.load() && !conn->shutting.load()) {
      int n = SSL_read(conn->ssl, buf, static_cast<int>(sizeof(buf)));
      if (n > 0) {
        EmitData(id, buf, n);
        continue;
      }
      int err = SSL_get_error(conn->ssl, n);
      if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
        continue;
      }
      break; // ZERO_RETURN / SYSCALL / SSL 错误
    }
  } else {
    unsigned long e = ERR_get_error();
    (void)e;
  }

  if (conn->ssl != nullptr) {
    SSL_shutdown(conn->ssl);
    SSL_free(conn->ssl);
    conn->ssl = nullptr;
  }
  if (conn->fd >= 0) {
    close(conn->fd);
    conn->fd = -1;
  }
  if (handshakeOk) {
    EmitClose(id);
  }
  RemoveConn(id);
  g_activeConns.fetch_sub(1);
}

void AcceptLoop() {
  while (g_running.load()) {
    sockaddr_in peer{};
    socklen_t len = sizeof(peer);
    int fd = accept(g_listenFd, reinterpret_cast<sockaddr *>(&peer), &len);
    if (fd < 0) {
      if (!g_running.load()) {
        break;
      }
      continue; // 被信号打断等，继续
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    auto conn = std::make_shared<Conn>();
    conn->id = g_nextId.fetch_add(1);
    conn->fd = fd;
    {
      std::lock_guard<std::mutex> lock(g_connsMu);
      g_conns[conn->id] = conn;
    }
    g_activeConns.fetch_add(1);

    std::thread t(ConnLoop, conn);
    t.detach();
  }
}

// ---------------- NAPI 参数工具 ----------------

bool GetInt32(napi_env env, napi_value v, int32_t *out) {
  return napi_get_value_int32(env, v, out) == napi_ok;
}

bool GetString(napi_env env, napi_value v, std::string *out) {
  size_t len = 0;
  if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) {
    return false;
  }
  out->resize(len);
  size_t copied = 0;
  return napi_get_value_string_utf8(env, v, out->data(), len + 1, &copied) == napi_ok;
}

// ---------------- 导出方法 ----------------

// start(port, certPem, keyPem, onConnect, onData, onClose): boolean
napi_value Start(napi_env env, napi_callback_info info) {
  size_t argc = 6;
  napi_value args[6] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 6) {
    return nullptr;
  }

  int32_t port = 0;
  std::string certPem;
  std::string keyPem;
  if (!GetInt32(env, args[0], &port) || !GetString(env, args[1], &certPem) ||
      !GetString(env, args[2], &keyPem)) {
    return nullptr;
  }

  if (g_running.load()) {
    return nullptr; // 已启动
  }

  // 1) SSL_CTX + 证书
  g_ctx = SSL_CTX_new(TLS_server_method());
  if (g_ctx == nullptr) {
    return nullptr;
  }
  SSL_CTX_set_min_proto_version(g_ctx, TLS1_2_VERSION);
  SSL_CTX_set_options(g_ctx, SSL_OP_NO_COMPRESSION);

  BIO *certBio = BIO_new_mem_buf(certPem.data(), static_cast<int>(certPem.size()));
  X509 *cert = certBio != nullptr ? PEM_read_bio_X509(certBio, nullptr, nullptr, nullptr) : nullptr;
  if (cert == nullptr || SSL_CTX_use_certificate(g_ctx, cert) != 1) {
    if (cert != nullptr) {
      X509_free(cert);
    }
    if (certBio != nullptr) {
      BIO_free(certBio);
    }
    SSL_CTX_free(g_ctx);
    g_ctx = nullptr;
    return nullptr;
  }
  X509_free(cert);
  BIO_free(certBio);

  BIO *keyBio = BIO_new_mem_buf(keyPem.data(), static_cast<int>(keyPem.size()));
  EVP_PKEY *pkey = keyBio != nullptr ? PEM_read_bio_PrivateKey(keyBio, nullptr, nullptr, nullptr) : nullptr;
  if (pkey == nullptr || SSL_CTX_use_PrivateKey(g_ctx, pkey) != 1) {
    if (pkey != nullptr) {
      EVP_PKEY_free(pkey);
    }
    if (keyBio != nullptr) {
      BIO_free(keyBio);
    }
    SSL_CTX_free(g_ctx);
    g_ctx = nullptr;
    return nullptr;
  }
  EVP_PKEY_free(pkey);
  BIO_free(keyBio);

  // 2) 监听
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    SSL_CTX_free(g_ctx);
    g_ctx = nullptr;
    return nullptr;
  }
  int reuse = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_port = htons(static_cast<uint16_t>(port));
  if (bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0 ||
      listen(fd, 64) < 0) {
    close(fd);
    SSL_CTX_free(g_ctx);
    g_ctx = nullptr;
    return nullptr;
  }

  // 3) 三个 TSFN
  if (MakeTsfn(env, args[3], "kuaitls.connect", CallJsConnect, &g_tsfnConnect) != napi_ok ||
      MakeTsfn(env, args[4], "kuaitls.data", CallJsData, &g_tsfnData) != napi_ok ||
      MakeTsfn(env, args[5], "kuaitls.close", CallJsClose, &g_tsfnClose) != napi_ok) {
    close(fd);
    SSL_CTX_free(g_ctx);
    g_ctx = nullptr;
    return nullptr;
  }

  g_listenFd = fd;
  g_running.store(true);
  g_acceptThread = std::thread(AcceptLoop);

  napi_value ret = nullptr;
  napi_get_boolean(env, true, &ret);
  return ret;
}

// send(connId, arrayBuffer): boolean
napi_value Send(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    return nullptr;
  }
  int32_t id = 0;
  if (!GetInt32(env, args[0], &id)) {
    return nullptr;
  }

  void *data = nullptr;
  size_t len = 0;
  bool isAb = false;
  napi_is_arraybuffer(env, args[1], &isAb);
  if (!isAb || napi_get_arraybuffer_info(env, args[1], &data, &len) != napi_ok) {
    return nullptr;
  }

  std::shared_ptr<Conn> conn;
  {
    std::lock_guard<std::mutex> lock(g_connsMu);
    auto it = g_conns.find(id);
    if (it == g_conns.end()) {
      return nullptr;
    }
    conn = it->second;
  }
  if (conn->ssl == nullptr || conn->shutting.load()) {
    return nullptr;
  }

  int n = SSL_write(conn->ssl, data, static_cast<int>(len));
  napi_value ret = nullptr;
  napi_get_boolean(env, n > 0, &ret);
  return ret;
}

// closeConn(connId)
napi_value CloseConn(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t id = 0;
  if (argc < 1 || !GetInt32(env, args[0], &id)) {
    return nullptr;
  }
  std::shared_ptr<Conn> conn;
  {
    std::lock_guard<std::mutex> lock(g_connsMu);
    auto it = g_conns.find(id);
    if (it == g_conns.end()) {
      return nullptr;
    }
    conn = it->second;
  }
  conn->shutting.store(true);
  if (conn->fd >= 0) {
    shutdown(conn->fd, SHUT_RDWR); // 让阻塞中的 SSL_read 立刻返回
  }
  return nullptr;
}

// stop()
napi_value Stop(napi_env env, napi_callback_info /*info*/) {
  if (!g_running.exchange(false)) {
    return nullptr;
  }
  if (g_listenFd >= 0) {
    shutdown(g_listenFd, SHUT_RDWR);
    close(g_listenFd);
    g_listenFd = -1;
  }
  if (g_acceptThread.joinable()) {
    g_acceptThread.join();
  }

  // 关闭所有连接并等待线程退出（最多 2 秒）
  {
    std::lock_guard<std::mutex> lock(g_connsMu);
    for (auto &kv : g_conns) {
      kv.second->shutting.store(true);
      if (kv.second->fd >= 0) {
        shutdown(kv.second->fd, SHUT_RDWR);
      }
    }
  }
  for (int i = 0; i < 200 && g_activeConns.load() > 0; i++) {
    usleep(10000);
  }

  if (g_tsfnConnect != nullptr) {
    napi_release_threadsafe_function(g_tsfnConnect, napi_tsfn_release);
    g_tsfnConnect = nullptr;
  }
  if (g_tsfnData != nullptr) {
    napi_release_threadsafe_function(g_tsfnData, napi_tsfn_release);
    g_tsfnData = nullptr;
  }
  if (g_tsfnClose != nullptr) {
    napi_release_threadsafe_function(g_tsfnClose, napi_tsfn_release);
    g_tsfnClose = nullptr;
  }

  if (g_ctx != nullptr) {
    SSL_CTX_free(g_ctx);
    g_ctx = nullptr;
  }
  return nullptr;
}

// version(): string —— 便于确认 OpenSSL 真的链上了
napi_value Version(napi_env env, napi_callback_info /*info*/) {
  napi_value ret = nullptr;
  const char *v = OpenSSL_version(OPENSSL_VERSION);
  napi_create_string_utf8(env, v != nullptr ? v : "unknown", NAPI_AUTO_LENGTH, &ret);
  return ret;
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"send", nullptr, Send, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"closeConn", nullptr, CloseConn, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module tlsModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "kuaitls",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule() {
  napi_module_register(&tlsModule);
}
