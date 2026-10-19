# 快传 · 鸿蒙手机端 App 设计方案

> 目标：和 PC 端「快传」**同一个软件的感觉**，双向互联互通。
> 本文只回答"能不能做、怎么做、代价多大"，不含代码。

---

## 一、结论速览

| 能力 | 判定 | 依据 |
|---|---|---|
| 与 PC 端互通（发现 + 收发文件） | ✅ **完全可行** | 鸿蒙有 TCP/组播/TLS 服务端全套 API，LocalSend v2.2 全部端点可实现 |
| 与官方 LocalSend / AloeSend / iOS 客户端互通 | ✅ 可行 | 只要严格实现协议，不依赖任何一方适配 |
| 后台常驻接收（关掉界面也能收） | ✅ 可行 | `backgroundModes: ["dataTransfer"]` + `KEEP_BACKGROUND_RUNNING`，**数据传输类长时任务无需 AGC 审批** |
| 默认 HTTPS（和 PC 端一致） | ✅ 可行 | `socket.constructTLSSocketServerInstance()` 支持服务端 TLS；证书需自行准备（见 §5.3） |
| 互传联盟 MTA（小米/OPPO/vivo/荣耀"互传"） | ❌ **不可行** | 见 §3.1，三重硬门槛 |
| Google Quick Share | ⚠️ 不建议 | 见 §3.2，逆向 + 平台变更风险 |

**一句话**：协议层只做 LocalSend，就是把"和 PC 端是一个软件"这件事做扎实；
MTA / Quick Share 这两块**不是我们没做好，是平台不给**。

---

## 二、范围定义

**技术要求（已定）**
- 最低支持 **API 12（HarmonyOS NEXT 5.0）**：`MulticastSocket` 需 API 11+，`TLSSocketServer` 需 API 12+
- **HTTPS 默认开启**，设置页可关闭（与 PC 端一致）；关闭后按协议公告 `https: false` 走明文

**功能范围：全量对齐 PC 端**，逐项清单见 `docs/harmonyos-feature-parity.md`（A 发现 / B 发送 / C 接收 / D 历史 / E 设置 / F 系统集成 / G 协议细节）。
因系统或硬件限制剔除的只有 5 项：托盘、拖拽、Ctrl+V 文件、开机自启、防火墙检测——每项都有替代方案。

**不做**（v1.0 明确排除）
- MTA / Quick Share 协议
- 手机与手机之间的"碰一碰"（NFC 触发）
- 云中转、账号体系

---

## 三、协议策略（为什么只做 LocalSend）

### 3.1 互传联盟 MTA：不可行，三重门槛

这不是"协议没公开"这么简单。参考开源实现 CatShare（MIT，`CatShare-main/`）的 README 明确写着：

> Android 目前已不再支持非系统应用获取手机的 MAC 地址……但由于各品牌的互传功能通常为系统应用，
> **互传联盟协议将设备的 MAC 地址作为其认证信息的一部分，目前暂时无法绕过。**

三重门槛叠加：

| 门槛 | 具体限制 | 鸿蒙上的情况 |
|---|---|---|
| 设备真实 MAC | 协议用它做认证因子 | 三方应用**禁止**获取（仅系统应用 + `GET_WIFI_LOCAL_MAC` 才给真实值，三方只能拿到随机 MAC） |
| Wi-Fi P2P 直连 | 传数据靠 Wi-Fi Direct 建组 | 相关 API 属**系统应用**能力，三方不可用 |
| BLE 广播 / GATT 服务端 | 设备发现靠 BLE 广播 | 后台广播受限，无法长期维持 |

结论：**即使拿到 CatShare 全部源码也搬不过来**，因为它的关键能力（MAC、P2P、Shizuku 特权）在鸿蒙上一律没有。
这条路要等华为开放，不是工程量问题。

### 3.2 Quick Share：技术上可部分实现，但不建议

- 协议是逆向出来的（NearDrop / rquickshare / packet 都基于此），非官方授权
- 依赖 BLE 广播 + mDNS + 自有 protobuf + TLS，Google 侧一改就得跟
- 鸿蒙的 BLE 广播能力对三方应用同样受限，后台更难

投入产出比极差，且一旦被 Google 封堵就是沉没成本。**不做。**

### 3.3 LocalSend v2.2：我们真正该做的

PC 端已实现并跑通的 5 个端点，手机端 1:1 对齐：

| 端点 | 方法 | 作用 |
|---|---|---|
| `/api/localsend/v2/info` | GET | 被探测时返回本机信息（alias / deviceModel / deviceType / fingerprint / port / protocol / https / download） |
| `/api/localsend/v2/register` | POST | 主动登记对方设备 |
| `/api/localsend/v2/prepare-upload` | POST | 发送前协商：提交文件清单，拿 `sessionId` + 每个文件的 token |
| `/api/localsend/v2/upload` | POST | 按 `sessionId` + `fileId` + `token` 上传裸 body |
| `/api/localsend/v2/cancel` | POST | 取消会话 |

发现：UDP 组播 `224.0.0.167:53317`，报文就是 info 的 JSON。

---

## 四、架构设计

### 4.1 分层（与 PC 端一一对应）

```
┌──────────────────────────────────────────────┐
│ UI 层（ArkUI 页面）                          │  ≈ PC 的 Views/*.xaml
│  SendPage / ReceivePage / HistoryPage        │
│  DeviceListPage / SettingsPage / Dialogs     │
├──────────────────────────────────────────────┤
│ 状态层（@ObservedV2 + 单例 Store）           │  ≈ PC 的 ViewModels
│  SendStore / ReceiveStore / DeviceStore      │
├──────────────────────────────────────────────┤
│ 服务层                                       │  ≈ PC 的 Services / Networking
│  DiscoveryService（组播收发）                │
│  LocalSendServer（TCP/TLS + 手写 HTTP）      │
│  SendClient（发送端）                        │
│  ReceiverService（落盘 + 目录安全）          │
│  SettingsService / HistoryService            │
│  BackgroundKeeper（长时任务）                │
├──────────────────────────────────────────────┤
│ 协议层（纯函数，可单测）                     │  ≈ PC 的 Models/Dto + Endpoints
│  DTO / 序列化 / 端点常量 / 指纹计算           │
└──────────────────────────────────────────────┘
```

### 4.2 目录结构（ArkTS 工程）

```
harmony/
├── AppScope/app.json5                  # bundleName: com.kuai.chuan
├── entry/src/main/
│   ├── module.json5                    # 权限 / 后台模式 / ability
│   ├── ets/
│   │   ├── entryability/EntryAbility.ets
│   │   ├── pages/                      # ArkUI 页面
│   │   │   ├── Index.ets               # 底部 Tab：发送 / 接收 / 历史 / 设置
│   │   │   ├── SendPage.ets
│   │   │   ├── ReceivePage.ets
│   │   │   ├── HistoryPage.ets
│   │   │   ├── SettingsPage.ets
│   │   │   ├── DeviceListPage.ets
│   │   │   └── OpenSourcePage.ets      # 开源许可（对齐竞品，也是 MIT 合规要求）
│   │   ├── viewmodel/                  # 状态
│   │   ├── service/                    # 服务（见 4.1）
│   │   ├── protocol/                   # DTO + 常量 + 编解码
│   │   ├── common/                     # 设计令牌、工具、日志
│   │   └── components/                 # 可复用组件（文件行、设备卡、空态）
│   └── resources/                      # 字符串 / 颜色 / 图标 / 自签证书
```

### 4.3 与 PC 端的能力对位

| PC 端 | 鸿蒙端 | 说明 |
|---|---|---|
| Kestrel（HTTP/HTTPS 服务） | `TCPSocketServer` / `TLSSocketServer` + **手写 HTTP/1.1** | 鸿蒙没有 HTTP 服务器，必须自己解析（见 §5.2） |
| UDP 组播（`MulticastClient`） | `MulticastSocket` + `addMembership` | 能力对齐，含 TTL / 回环 / 地址复用 |
| `HttpClient`（发送） | `http` / `rpc` 或 `TCPSocket` | 走 `@kit.NetworkKit` 的 http 请求即可 |
| 托盘常驻 | 长时任务 + 通知栏 | 语义等价，实现完全不同 |
| `%LOCALAPPDATA%` 数据目录 | 应用沙箱 `context.filesDir` | 结构性等价 |
| 公共目录保存 | `PhotoAccessHelper` / `file.picker` | 手机端有分区存储限制，见 §5.4 |

---

## 五、关键技术方案

### 5.1 设备发现（组播）

```ts
const sock = socket.constructMulticastSocketInstance();
const group: socket.NetAddress = { address: '224.0.0.167', port: 53317, family: 1 };
sock.setLoopbackMode(true);        // 官方实现依赖回环判断自身公告
sock.addMembership(group);          // 收
sock.send({ data: JSON.stringify(info), address: group });  // 发
```

要点：
- **必须绑到 WLAN 网卡**，多网卡（含 VPN/虚拟网卡）要过滤，否则公告发到错误网段
- Wi-Fi 切换 / 息屏唤醒后要重建 socket（PC 端踩过同样的坑）
- 收到公告要丢掉 `fingerprint == 自己` 的包

### 5.2 HTTP 服务器（最大的自研工作量）

`TCPSocketServer` 只给到"字节流"，HTTP 要自己实现。好在 LocalSend 的用法极简：

- 请求行 + 头部逐行读到 `\r\n\r\n`
- 上传是 **裸 body**（`POST /api/localsend/v2/upload?...`），靠 `Content-Length` 读满 N 字节，**不用解析 multipart**
- 响应固定 JSON + `Content-Length`

需要处理的边界：
- 大文件流式落盘（边读边写，禁止整包进内存——手机内存经不起 4 GB 视频）
- 单个连接上多次请求 / `Connection: keep-alive`
- 并发（手机一般 1~2 个发送方，用简单连接表即可）
- 客户端中途断开 → 清理半成品文件

> 工作量评估：这部分约 **1 周**，是整个项目最"脏"的活。可以先用明文 TCP 跑通，再切 TLS。

### 5.3 证书与 HTTPS

`TLSSocketServer.listen()` 需要 `key` / `cert`（PEM）。两种方案：

| 方案 | 做法 | 取舍 |
|---|---|---|
| A. 内置证书（v1 推荐） | 构建期生成一对自签 PEM，打进 `resources/rawfile` | 5 分钟落地；缺点：所有安装共用同一私钥 |
| B. 首次启动生成 | `@kit.CryptoArchitectureKit` 生成 RSA 密钥对 + 自签 X.509 | 每个安装独立，和 PC 端一致；但要自己拼 X.509（工作量 2~3 天） |

无论哪种，都要把 **SHA-256 指纹**写进 info 的 `fingerprint` 字段（PC 端就是这么做的：
`[TLS] fingerprint 已同步为 mTLS 证书指纹`）。

先做 A，B 作为 M3 的增强。

### 5.4 文件落盘与权限

手机端和 PC 端最大的体验差异点：

- 应用沙箱目录可随意写，但用户"看不见"
- 存到相册 / Downloads 需要 `PhotoAccessHelper`（媒体库）或 `file.picker`（用户选目录）
- 接收多文件时保留目录结构 → 只能落在沙箱，再由用户"导出"

**方案**：默认落沙箱 `filesDir/received/`，接收完成通知里提供「保存到相册 / 另存到…」两个动作。
比竞品"存进兼容层目录拿不出来"要好，这也是差异化点之一。

### 5.5 后台常驻

```json5
// module.json5
"requestPermissions": [{ "name": "ohos.permission.KEEP_BACKGROUND_RUNNING" }],
"abilities": [{ "backgroundModes": ["dataTransfer"] }]
```

```ts
await backgroundTaskManager.startBackgroundRunning(context,
  backgroundTaskManager.BackgroundMode.DATA_TRANSFER, wantAgent);
```

合规红线（华为《Background Tasks Kit 接入规范》）：
- 通知栏必须可见，文案不得修改
- 传输结束必须 `stopBackgroundRunning()`
- **禁止**为了保活而伪造传输任务 → 会被下架

---

## 六、"同一个软件"的一致性设计

这是本方案的核心要求，落到可检查的清单：

| 维度 | 统一做法 |
|---|---|
| 名称 | 全部显示「快传」，包名 `com.kuai.chuan`，桌面图标用同一套绿色双向箭头 |
| 主色 | `#16A34A`，与 PC 端品牌色一致 |
| 间距 | 复用已定的刻度 **4 / 8 / 12 / 16 / 24**（见 `docs/UI-SPACING.md`），鸿蒙侧封装成同一套常量 |
| 圆角 | 卡片 12 / 按钮 8 / 行 10，与 PC 端一致 |
| 字号层级 | 22 标题 / 15 小节 / 13 正文 / 12 辅助 / 11 说明 |
| 页面结构 | 发送 / 接收 / 历史 / 设置，四 Tab；设置页分区顺序与 PC 端一致（身份、网络、接收、外观、关于） |
| 文案 | 用词统一（"待发送""接收中""会话"），不出现"设备列表/附近设备"两种叫法 |
| 状态语义 | 待发送灰、传输中蓝、成功绿、失败红、取消灰，与 PC 端状态色一致 |
| 空态 | 同样的"拖放/点选"引导文案，图标语义一致 |

> 判断标准：把手机截图和 PC 截图并排放，**不会觉得是两个产品**。

---

## 七、风险清单

| # | 风险 | 影响 | 对策 |
|---|---|---|---|
| 1 | TLS 服务端 `secureOptions` 对自签证书的兼容性 | 阻塞默认 HTTPS | M0 阶段第一件事就验证，跑不通则一期降级为明文（协议允许） |
| 2 | 手写 HTTP 在大文件下的稳定性 | 传输中断、内存溢出 | 流式落盘 + 分块校验；先用 4 GB 文件压测 |
| 3 | 组播在部分路由器/AP 隔离下收不到 | 发现不到设备 | 保留手动输入 IP + 二次探测（TCP 直连 info） |
| 4 | 后台被系统冻结 | 收不到文件 | 传输期间长时任务；空闲期接受"打开 App 才活跃" |
| 5 | 华为应用市场审核（后台任务、隐私） | 上架被拒 | 严格遵守 §5.5 红线；隐私政策逐项对应权限 |
| 6 | 与 PC 端 fingerprint 语义差异 | 白名单/指纹校验失败 | 严格按协议：https 模式下 fingerprint = 证书 SHA-256 |

---

## 八、里程碑

| 阶段 | 内容 | 验收标准 | 估时 |
|---|---|---|---|
| **M0 技术验证** | TLS 服务端 + 手写 HTTP + 组播发现 | 手机能被 PC 端的 `info` 探到；PC 能把 1 个文件传到手机 | 3~5 天 |
| **M1 协议互通** | 5 个端点 + 发送 + 接收 + 目录结构 | PC ⇄ 手机双向传 1 GB 文件成功；取消可用 | 2 周 |
| **M2 可用 UI** | 四 Tab + 设备列表 + 进度 + 空态 | 不用 adb，纯点击完成一次收发 | 2 周 |
| **M3 体验完善** | 后台常驻、通知进度、历史、白名单、PIN、文本传输 | 锁屏状态下 PC 能成功发文件到手机 | 2 周 |
| **M4 上架准备** | 隐私声明、许可页、图标、崩溃上报 | 过华为审核 | 1 周 |

合计约 **7~8 周**（单人全职）。M0 结束即可判断能否按期推进。

---

## 九、已确认的决策

| 项 | 决策 |
|---|---|
| 最低版本 | **API 12（HarmonyOS NEXT 5.0）** |
| HTTPS | **默认开启**，设置页可关闭（同 PC 端） |
| 功能范围 | **全量对齐 PC 端**，限制项见 `harmonyos-feature-parity.md` |
| 上架资质 | 用户自行解决，不进入技术方案 |

## 十、仍需验证的两点（不影响开工，影响细节）

1. **剪贴板文件**：能否从系统文件管理器复制的文件中取到 URI。跑不通就只做"发送文本"。
2. **自选目录持久授权**：`file.picker` 授权目录重启后是否仍可写。影响"默认保存目录"能否设为公共目录。

## 十一、真机实测结论与已知平台限制（2026-10-18，Mate 70 Pro）

### 11.1 组播发现的正确写法（重要）

鸿蒙 `MulticastSocket` 与 POSIX 习惯**相反**，实测矩阵：

| 写法 | 结果 |
|---|---|
| `bind` → `addMembership`（常规顺序） | ❌ 2301022 Invalid argument |
| `addMembership({group, port: 实际端口})` → `bind` | ⚠️ 不报错但 **membership 静默失效**，收不到任何包 |
| **`addMembership({group, port: 0})` → `bind`** | ✅ 正确 |

两条都要满足：**先 join 后 bind**，且 **join 的 port 必须传 0**。
传实际端口不报错，但会导致"能发公告、收不到公告"，极难排查。

### 11.2 TLS 服务端：无法接收大文件（平台缺陷）

| 传输方式 | 5MB 上传 | 20MB 上传 |
|---|---|---|
| 明文 HTTP（`TCPSocketServer`） | ✅ 200 / 2.2s | ✅ 200 / 3.6s（≈5.8MB/s） |
| HTTPS（TLS1.2 + `AES256-SHA256`） | ❌ 停在 5,234,688/5,242,880 | — |
| HTTPS（TLS1.3 + 默认套件） | ❌ 同样停住 | — |

表现：小请求（info / prepare-upload / 11 字节上传）全部正常；**多记录的大 body 永远差最后一个 8KB**，
且卡住后该连接会把服务端拖住（后续请求无响应）。已排除：消费速度（改异步队列无效）、
接收缓冲（从默认调到 8MB 只是把卡点从 4MB 推后）、双向认证（显式关闭无效）、TLS 版本与套件。

结论：这是 `TLSSocketServer` 在"客户端发完数据、不再有新包"时不投递最后一个记录的问题
（社区也有"一次最多 8192 字节、需再发消息才继续下发"的反馈）。

**当前处置**：`Https` 默认 `false`（明文 HTTP），设置页保留开关并注明"实验性"。
若要真正支持 HTTPS 大文件，需要绕开 `TLSSocketServer`，用 C++/OpenSSL 通过 NAPI 自建 TLS 层。

### 11.4 解决方案：NAPI + OpenSSL 自建 TLS 层（已落地并实测通过）

既然 `TLSSocketServer` 不可用、SDK 又没有 HTTP 服务端 API，唯一可行的路是把 TLS 挪到
native 层自己做。已实现并跑通：

```
entry/src/main/cpp/tls_server.cpp   // C++/OpenSSL：listen → SSL_accept → SSL_read/SSL_write
entry/src/main/cpp/CMakeLists.txt   // 依赖 ohpm 包 @ohos-rs/openssl（预编译 OpenSSL 3.4）
entry/src/main/ets/service/HttpServer.ets  // ArkTS 侧用 ConnAdapter 把字节喂给原有 HttpSession
```

关键点：
- **OpenSSL 不用自己交叉编译**：`ohpm install @ohos-rs/openssl`（MIT）已提供
  arm64-v8a / armeabi-v7a / x86_64 的 `libssl.so` + `libcrypto.so` + 头文件。
- **协议层零改动**：原生层只做"握手 + 加解密 + 收发原始字节"，HTTP 解析、PIN、token、
  分块落盘、路径校验全部复用原有 ArkTS 实现。
- 线程模型：accept 线程 → 每连接一线程做 `SSL_accept` + `SSL_read` 循环，
  解密后的字节经 `napi_threadsafe_function` 投递到 ArkTS 主线程；
  ArkTS 发送则直接调 `SSL_write`（OpenSSL 1.1+ 自带内部锁，读写可并发）。
- `closeConn` 用 `shutdown(fd, SHUT_RDWR)` 让阻塞中的 `SSL_read` 立刻返回。

实测结果（Mate 70 Pro，同一局域网）：

| 场景 | 结果 |
|---|---|
| `GET /info` over HTTPS | ✅ 正常返回 JSON |
| 5 MB 上传 over HTTPS | ✅ HTTP 200 / 2.6s / 文件完整 5242880 字节 |
| 20 MB 上传 over HTTPS | ✅ HTTP 200 / 4.9s（≈4.3 MB/s） / 完整 20971520 字节 |

对比：鸿蒙自带 `TLSSocketServer` 在 5MB 时永远停在 5234688 字节（差 8192），
换成 native TLS 后干净通过。因此 **`Https` 恢复为默认 `true`**。

参考：`HandySend`（Apache-2.0，已上架华为应用市场）采用同一思路——
Rust 协议核心 + NAPI，TLS 在 Rust 侧实现。方向上互为印证。

### 11.5 后台常驻实测（dataTransfer 长时任务）

| 操作 | 日志 | 结果 |
|---|---|---|
| 按 Home 切后台 | `已进入后台长时任务（dataTransfer）` | 通知栏出现长时任务 |
| 后台 + 锁屏，传 20MB | `开始接收 …` → `接收完成 (20971520/20971520)` | ✅ HTTP 200 / 9.6s |
| 回前台 | `已退出后台长时任务` | 及时释放 |

`dataTransfer` 类型无需 AGC 审批，但要求通知可见、业务结束即停，所以 `onForeground`
必须调 `stopBackgroundRunning`，不能常驻。

### 11.6 子网扫描（组播被拦时的兜底）

用户点击标题栏「扫描局域网」→ 逐 IP 调 `GET /info`，命中即写入设备表。
实测扫到 `XIAOXIAO-PC @ 192.168.3.190`。并发 16、单次 1s 超时，全段约 20-30s。
注意：该入口必须放在 `Scroll` 之外（见 §11.3）。

### 11.7 系统分享面板（sendData）

`module.json5` 的 EntryAbility 增加：

```json5
{ "actions": ["ohos.want.action.sendData"],
  "uris": [{ "type": "general.file" }, { "type": "general.image" },
           { "type": "general.video" }, { "type": "general.audio" }] }
```

文件 URI 在 `want.parameters['ability.params.stream']`（string 数组），单个文件时也兼容 `want.uri`。
**必须先把文件复制进沙箱**（`cacheDir/shares`）再发送：分享授予的读权限是临时的，
而传输可能持续几十秒到几分钟。`onCreate` 与 `onNewWant` 都要处理（冷启动/运行中）。

### 11.8 接收体验（进度 / 提醒 / 文件位置）

- **进度**：`FileReceiver` 提供 `setProgressListener`，按会话汇总（已收/总量 + 当前文件 +
  速度 + 完成文件数），150ms 节流。界面用全局浮层（Tab 栏上方），任意页面都能看到。
- **完成提醒**：前台 `promptAction.showToast` + 系统通知（`notificationManager.publish`）。
  通知未授权时返回 `1600004`，首次失败会自动 `requestEnableNotification` 一次。
- **文件位置**：沙箱 `filesDir/received`（绝对路径形如
  `/data/storage/el2/base/haps/entry/files/received`），设置页展示并可复制。
  历史记录的接收项支持「打开」（按扩展名给 MIME，精确拉系统应用）与「另存」
  （`DocumentViewPicker.save()` 导出到文件管理/相册）。
  注意：不给 MIME 直接 `viewData` 会弹出"选择应用"框，连本应用自己都会列进去。

### 11.3 其它已踩实的坑

- **客户端 socket 必须先 `bind` 再 `connect`**：否则 `send()` 报 `2303600 No bind socket`。
- **客户端的事件订阅必须在 `connect()` 之后**：`on('message')` 写在 connect 之前（官方示例的写法）
  会导致连接成功、请求发出、服务端也回了包，但客户端**一个字节都收不到**。
  这个坑极难排查，必须靠"回环自测"（自己连自己）才能定位。
- `TLSConnectOptions.skipRemoteValidation = true` 可以让客户端接受对端自签名证书。
- `TLSSocketConnection.send(data)` 直接收 payload；`TCPSocketConnection.send({data})` 要包一层。
- `TextEncoder.encodeInto('')` 在 ArkTS 会抛异常，空响应体必须单独判空（否则 upload 的 200 永远发不出去）。
- 不要在 `on('message')` 回调里同步 `send`，用 `setTimeout(0)` 跳出回调上下文。
- **`Scroll` 内的 `Text` / `Button` 点击可能不响应**：同一个页面上 Tab 栏、`Column` 里的
  chip 都能点，唯独 `Scroll` 里的按钮点不动（坐标换算已用 Tab 栏验证过是对的）。
  解决：把入口移到 `Scroll` 之外（如标题栏）。排查手法是先点一个已知有反馈的控件
  验证坐标映射，确认坐标没问题后再怀疑容器。
- **连接失败必须显式释放 socket**：`connect()` 里若把 `this.tls = t` 写在 `await connect`
  之后，超时/失败路径 `close()` 就拿不到引用 → socket 泄漏。子网扫描 254 个 IP 时
  fd 用尽，后续探测全部失败（表现为「扫描完成，新发现 0 台」，但设备明明在线）。
- **`close()` 的超时不要设太长**：失败连接上限 3s 会把 254 个 IP 的扫描从 20s 拖到 74s，
  改成 800ms 后明显好转。
- **单纯锁屏不会触发 `onBackground`**：只有按 Home / 切到其他应用才触发。
  因此「锁屏能不能收文件」要靠长时任务 + 进程仍在，验证时要先切后台再锁屏才是真实场景。
- **换成 native TLS 后必须删掉旧的"停滞看门狗"**：那段代码是给 `TLSSocketServer`
  写的补丁（400ms 无数据就发一个空 TLS 记录去"踢"）。原生 OpenSSL 下它会在 JS 线程
  并发调用 `SSL_write`，与读线程的 `SSL_read` 抢同一个 `SSL` 对象，把流搅乱。
  症状：**限速上传（如 2.5MB/s）会永久卡在某个整数 MB**，日志狂刷「上传停滞」。
  移除后限速 20MB 恢复正常（9.16s）。全速传输因为几乎不会触发看门狗，所以之前没暴露。
- 调试期记录：设备锁屏时 `aa start` 报 10106102；`hilog -x` 只保留约 1 分钟。

## 附：为什么这份方案不承诺"支持竞品的三个协议"

竞品（`cn.biandangroup.bcshare`）同时挂了 CatShare(MTA) / Quick Share / LocalSend 三个协议。
其中前两个在我们的平台上拿不到必需的系统能力（真实 MAC、Wi-Fi P2P、BLE 广播），
**不是工程投入能解决的**。我们的差异化应建立在：

- 与 PC 端真正同源（同一协议、同一视觉、同一套设置），跨端体验连贯
- 后台常驻接收做扎实（竞品在这里普遍不稳）
- 接收文件的可用性（目录结构、导出、历史）
