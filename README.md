# Sideload Updater

**简体中文** · [繁體中文](README.zh-Hant.md) · [English](README.en.md) · [日本語](README.ja.md)

在 iPhone 上查看哪些侧载 App 有更新。Sideload Updater 读取已安装的版本，与 App Store 原版比较，无需导入这些 App 的 IPA。点列表里的「更新」可查看商店页面，侧载版仍用自己的工具安装。

[下载未签名 IPA](https://github.com/sanwan1174/SideloadUpdater/releases/latest) · 支持 iOS 17 及以上版本

<img src="docs/demo.jpg" width="280" alt="更新列表列出每个 App 的本机版本、商店版本和更新按钮">

## 首次使用

1. **安装并连接。** 用自己的侧载工具签名并安装下载的 IPA。iPhone 连上 Wi-Fi，开启开发者模式，允许 App 访问本地网络，并启用 LocalDevVPN 或 Surge 的 Local Device Loopback 模块。
2. **与本机配对。** 在 iOS 27 及以上版本，点 App 内的「开始配对」，前往系统「设置 → 隐私与安全性 → 开发者模式」选择 Sideload Updater，再把 App 显示的六位码填入系统提示。如果已有这台 iPhone 的 RPPairing 文件，可从 App 的「设置 → 其他配对方式」导入。
3. **检查更新。** 添加 App Store 地区并排好顺序，再点「检查更新」。每个 App 都使用第一个查到原版的地区。如果某个 App 重签时改过 Bundle ID，可在它的详情页粘贴原版商店链接，手动绑定。

之后每次冷启动会自动检查一次。从后台切回来会保留列表，需要时可下拉刷新。配对记录存放在本机钥匙串，查询商店时使用 App 标识和地区代码。

## 从源码构建

在装有 Xcode 和 Rust 稳定版工具链的 Mac 上运行以下命令，再在 Xcode 中选择自己的签名团队和 iPhone。

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
bash Vendor/setup-idevice.sh
open SideloadUpdater.xcodeproj
```

配对组件使用 [idevice（MIT 许可）](Vendor/IDevice-LICENSE.txt)。
