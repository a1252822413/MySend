# LocalSend PC 安装包（MSI）

**版本** 1.1.0.0　**架构** x64　**大小** 约 92 MB　**无需证书、无需开发者模式**

## 怎么装

双击 `LocalSendPC-1.1.0.0-x64.msi` → 下一步 → 完成。

- 会弹一次 UAC（因为装到 `C:\Program Files\LocalSend PC`），提示「未知发布者」是正常的——
  安装包没有代码签名证书，点「是」继续即可。
- 装完会有**开始菜单**和**桌面**快捷方式。
- 卸载：设置 → 应用 → 已安装的应用 → 搜 `LocalSend PC`；或 `msiexec /x LocalSendPC-1.1.0.0-x64.msi`。

## 和 MSIX 版的区别

| | MSI（这个） | MSIX |
|---|---|---|
| 需要证书 | 否 | 是（自签名也要手动信任，需要管理员） |
| 需要开发者模式 | 否 | 部分系统需要 |
| 安装位置 | `C:\Program Files\LocalSend PC` | WindowsApps（系统托管） |
| 升级/卸载 | 标准 MSI，控制面板可见 | 设置里卸载 |
| 开机自启 | 写 `HKCU\...\Run` 注册表项 | MSIX StartupTask |
| 数据位置 | `%LOCALAPPDATA%\LocalSendPC` | `%LOCALAPPDATA%\Packages\<包名>\LocalState` |

两者功能完全一致（同一份代码，运行时用 `PathHelper.IsPackaged` 自动切换数据目录和自启方式）。

## 首次运行的注意事项

1. **防火墙**：首次启动 Windows 会弹「是否允许 LocalSend PC 通过防火墙」，
   勾选**专用网络**并允许——否则别的设备发现不了这台机器（接收依赖 53317 端口）。
2. **托盘**：关闭窗口只是缩到托盘，右键托盘图标 →「退出」才是真正结束。

## 重新打包

```cmd
installer\build.cmd
```

脚本会先 `dotnet publish` 出 unpackaged 自包含版本到 `build\out\portable`，
再用 WiX 打成 `build\out\LocalSendPC-1.1.0.0-x64.msi`。

前置条件：

```cmd
dotnet tool install --tool-path build\tools-wix5 wix --version 5.0.2
```

> 必须用 WiX **v5**：v7 需要先接受 OSMF 付费许可协议（`WIX7015`），v5 没有这个门槛。

改版本号要同步两处：`installer\LocalSendPC.wxs` 的 `Version`，以及 `build.cmd` 里的 `MSI` 文件名。
