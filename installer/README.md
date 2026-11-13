# 快传 安装包

**版本** 1.2.1.0　**架构** x64　**大小** 约 88 MB　**无需证书、无需开发者模式**

## 怎么装

双击 `KuaiChuan-1.2.1.0-x64.msi` → 下一步 → 完成。

- 会弹一次 UAC（因为装到 `C:\Program Files\快传`），提示「未知发布者」是正常的——
  安装包没有代码签名，点「是」继续即可。
- 装完会有**开始菜单**和**桌面**快捷方式，名字都是「快传」。
- 卸载：设置 → 应用 → 已安装的应用 → 搜 `快传`；或 `msiexec /x KuaiChuan-1.2.1.0-x64.msi`。

> 之前装过任何旧版本的，直接装这个就会**自动升级**并清掉旧版本，
> 不用手动卸载（同一 UpgradeCode + 更高版本号）。

## 本次更新

- **默认启用 HTTPS**：传输端口（53317）直接以 TLS 提供，不再默认明文。
  老配置会自动迁移一次（`SettingsService` 的 v1 迁移）；之后你在设置页关掉「使用 HTTPS」
  会持久保存，不会被改回去。
  - 服务端证书是首次启动自动生成的自签名证书（`CN=LocalSend User`），存于
    `%LOCALAPPDATA%\LocalSendPC\client-identity.pfx`，卸载重装会重新生成。
  - 需要和对端协议一致：双方都支持 https 才能互传；遇到只支持明文的老设备，
    可在「设置 → 使用 HTTPS」临时关闭。

- **修复托盘图标不显示**：原来用固定资源 ID 1 去 `LoadIcon`，但 `<ApplicationIcon>` 生成的
  图标组 ID 并不是 1，加载失败后静默退回系统默认图标。改为从 exe 抽取第 0 个图标组，
  与资源 ID 无关。诊断日志里会打印 `[Tray] icon source = ...`，可确认取的是 exe 内嵌图标。
- **应用改名为「快传」**：窗口标题、托盘提示与菜单、开始菜单、安装目录、设置页文案全部更新。
  可执行文件仍叫 `PcDemo.exe`（改会牵动清单与安装器路径，收益不大）。

## 首次运行的注意事项

1. **防火墙**：首次启动 Windows 会弹「是否允许快传通过防火墙」，勾选**专用网络**并允许——
   否则别的设备发现不了这台机器（接收依赖 53317 端口）。
2. **托盘**：关闭窗口只是缩到托盘，右键托盘图标 →「退出」才是真正结束。

## 数据位置

- 设置/历史/证书：`%LOCALAPPDATA%\LocalSendPC`（卸载不删除）
- 程序文件：`C:\Program Files\快传`

## 重新打包

```cmd
installer\build.cmd
```

前置条件（只需一次）：

```cmd
dotnet tool install --tool-path build\tools-wix5 wix --version 5.0.2
```

> 必须用 WiX **v5**：v7 会报 `WIX7015` 要求接受 OSMF 付费许可，v5 没有这个门槛。
> 另外构建时**必须带 `-loc installer\zh-CN.wxl -culture zh-CN`**，否则 MSI 数据库的
> codepage 会是 1252，中文产品名会被写成 0x7F 占位符（装出来乱码）。`build.cmd` 里已包含。

## 构建验证记录（2026-11-13，UI 重构后首次打包）

- 工具链：.NET SDK **11.0.100**（工程仍 target `net8.0-windows10.0.19041.0`，SDK 11 可正常还原并编译）、WindowsAppSDK 1.8、WiX 5.0.2。
- `dotnet build -c Release -r win-x64 --self-contained true -p:WindowsPackageType=None` → **0 警告 0 错误**。
  编译期只发现并修掉一处真实错误：`TopToast.xaml.cs` 的 `AutomationLiveSetting` 枚举在
  `Microsoft.UI.Xaml.Automation.Peers`（不是 `Microsoft.UI.Xaml.Automation`），补 using 即可。
  首次构建伴随出现的 `WMC9999 / WMC1509` 是 C# 编译失败时 XAML 编译器的连带崩溃，修复后自动消失。
- 新增的 `TopToast` / `FileProgressRow` / `ClearHistoryDialog` 三个 XAML 都生成了 `.g.cs`，确认参与编译；
  `PcDemo.pri` 1.4 MB，资源索引完整。
- 便携目录 **646 个文件 / 284 MB**；MSI **87.6 MB**。MSI 内 GBK(936) 的「快传」出现 4 处
  （产品名/目录名/快捷方式名），未出现 0x7F 占位符乱码。

### 已知问题：ICE03 Invalid Language Id

全量 `wix msi validate` 会报 **6 error + 2 warning**，全部是 `Table: File, Column: Language`。
根因是 WindowsAppSDK 自带的 `Microsoft.ui.xaml.dll(.mui)` / `Microsoft.UI.Xaml.Phone.dll(.mui)`
——约 90 个语言子目录里少数带脚本/变体区域名的 `.mui`，其版本资源里的 Language 不是合法 LANGID
（多语言列表或超长字符串），WiX v5 的 `<Files Include="**">` 自动采集后写进了 `File.Language`。

WiX v5 的 `<Files>` 只有 `Directory / Include / Subdirectory` 三个属性（子元素仅 `Exclude`），
无法批量覆盖 Language；试过 `<Files Language="0">`，编译器直接报 `WIX0004 unexpected attribute`。

**影响**：只影响 MSI 规范性校验，不影响安装、卸载、升级。包里配了 `MajorUpgrade`（先卸载旧版），
不依赖 `File.Language` 做文件版本比较，且这些文件都是纯语言资源。跳过该项后其余 ICE 全部通过：

```cmd
build\tools-wix5\wix.exe msi validate build\out\KuaiChuan-1.2.1.0-x64.msi -sice ICE03
```

刻意**不**在 wxs 里写死这 8 个文件的特例：WindowsAppSDK 一升级，语言目录集合就会变，特例会失效。
也不采用 WiX v3 时代的 `light.exe -sh` 全局抑制文件信息（会丢掉全部 646 个文件的 hash/version）。
