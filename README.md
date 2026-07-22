<p align="center">
  <img src="assets/readme/logo-v0.4.8.png" width="128" height="128" alt="Y-Dock logo">
</p>

<h1 align="center">Y-Dock</h1>

<p align="center">
  <strong>让 macOS Dock 拥有接近 Windows 任务栏的窗口预览体验。</strong>
</p>

<p align="center">
  鼠标悬停 Dock 图标，即刻查看该 App 的所有窗口；也可以按住 Option+Tab，用 Windows Alt+Tab 的方式快速切换窗口，按 Esc 随时取消。
</p>

<p align="center">
  <a href="https://github.com/Rainchen537/Y-Dock/releases/tag/v1.1.21">
    <img alt="Release" src="https://img.shields.io/github/v/release/Rainchen537/Y-Dock?style=for-the-badge&color=1f8fff">
  </a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-13%2B-111827?style=for-the-badge&logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5-F05138?style=for-the-badge&logo=swift&logoColor=white">
  <img alt="AppKit" src="https://img.shields.io/badge/AppKit-native-0EA5E9?style=for-the-badge">
  <img alt="Private API" src="https://img.shields.io/badge/Private%20API-none-22C55E?style=for-the-badge">
</p>

<p align="center">
  <a href="https://github.com/Rainchen537/Y-Dock/releases/download/v1.1.21/Y-Dock-v1.1.21-arm64.dmg">
    <img alt="Download Apple Silicon DMG" src="https://img.shields.io/badge/Download-Apple%20Silicon-2563EB?style=for-the-badge&logo=apple">
  </a>
  <a href="https://github.com/Rainchen537/Y-Dock/releases/download/v1.1.21/Y-Dock-v1.1.21-x86_64.dmg">
    <img alt="Download Intel DMG" src="https://img.shields.io/badge/Download-Intel-4B5563?style=for-the-badge&logo=apple">
  </a>
</p>

<p align="center">
  <img src="assets/readme/preview.svg" alt="Y-Dock preview">
</p>

## ✨ 主要功能

| 功能 | 体验 |
| --- | --- |
| 🪟 Dock 悬浮预览 | 鼠标停在 Dock 中某个 App 图标上，弹出该 App 的窗口预览面板。 |
| 🧩 Dock 拼接式卡片 | Dock 悬浮预览去掉外层矩形容器，多窗口像 Windows 任务栏一样合并成一组。 |
| ⚡ 快速切换窗口 | 点击任意缩略图，直接激活 App 并聚焦对应窗口。 |
| 🖱️ Dock 点击最小化 | 可关闭，或仅在 App 只有一个窗口时最小化，也可一次最小化该 App 的全部窗口；仅对点击前已在前台的 App 生效，后台 App 点击仍保持系统原生激活行为。 |
| ⌥ Option+Tab 切换 | 按住 `Option` 后按 `Tab` 呼出亚克力窗口切换器，严格按最近聚焦顺序排列并默认选择第二张（仅一张时选择第一张）；hover 卡片时可从左上角半透明 X 直接关闭对应窗口，按 `Esc` 安全取消。 |
| 🚀 异步缩略图 | 首屏先显示轻量卡片，缩略图后台补齐，减少热键和 Dock 横扫卡顿。 |
| 💤 唤回最小化窗口 | 被最小化的窗口也会出现在预览里，点击后自动恢复并置前。 |
| 🎚 卡片窗口控制 | hover 某个窗口卡片，左上角显示退出 App、关闭窗口、最小化窗口三颗控制按钮；可调整单颗按钮 hover 放大尺寸，也可改为仅在进入左上控制区域时显示。 |
| ⏻ 关闭按钮策略 | 红色关闭按钮可继续关闭单个窗口，也可按全部 App、黑名单或白名单请求正常退出所属 App；黑白名单会独立保存。 |
| 🎯 临时聚焦预览 | hover 卡片超过 `50ms` 后，用轻量覆盖层突出当前窗口快照，不改变真实桌面状态。 |
| 🎛 设置窗口 | 独立设置窗口采用左侧栏和右侧内容区，可调整悬停延迟、缩略图高度、Dock 点击、卡片控制按钮、关闭策略、标题显示、开机启动和调试日志。 |
| ⬇️ 直接更新 | 检测到新版本后按当前编译架构精确选择 `arm64` 或 `x86_64` DMG，并要求下载 App 的内部版本与 GitHub Release 完全一致且严格高于当前版本；挂载源、同卷候选副本和最终安装路径都会验证身份、Developer ID、hardened runtime、签名、Gatekeeper 与严格 thin 架构。普通与管理员路径复用带固定互斥锁的 candidate + backup 原子事务；direct 安装器的 `READY\n` 必须随即关闭通道且不允许尾随内容。提权时只执行摘要匹配的 root-owned installer 和已重新验证的完整 helper App 副本，失败时保留或恢复有效 App。 |
| 🛡️ 权限状态诊断 | 权限页区分屏幕录制“未开启 / 需要重启 / 已开启”，并提供对应的请求、重启或安装版切换操作。 |
| 📍 正式安装版切换 | 区分正式安装版与开发副本，并可切换到签名验证通过的 `/Applications/Y-Dock.app`。 |
| 🔐 公开 API 实现 | 使用 AppKit、Accessibility、CoreGraphics，不依赖 macOS 私有 API。 |

## 📦 安装

1. 按 Mac 架构下载最新版 DMG：
   - Apple Silicon（M 系列）：[Y-Dock-v1.1.21-arm64.dmg](https://github.com/Rainchen537/Y-Dock/releases/download/v1.1.21/Y-Dock-v1.1.21-arm64.dmg)
   - Intel：[Y-Dock-v1.1.21-x86_64.dmg](https://github.com/Rainchen537/Y-Dock/releases/download/v1.1.21/Y-Dock-v1.1.21-x86_64.dmg)
2. 打开对应架构的 DMG。
3. 将 `Y-Dock.app` 拖到 `Applications`。
4. 启动 `Y-Dock`，按提示开启权限。

> 正式发布的两个架构 DMG 都必须独立完成 Developer ID 签名、Apple notarization、ticket 装订和 Gatekeeper 验证，首次打开不需要绕过 Gatekeeper。

## 🔑 权限说明

Y-Dock 需要两项系统权限，都是为了实现窗口预览和窗口切换：

| 权限 | 用途 |
| --- | --- |
| Accessibility / 辅助功能 | 读取 Dock 的 Accessibility 元素、匹配窗口、恢复最小化窗口、raise/focus 指定窗口。 |
| Screen & System Audio Recording / 屏幕与系统音频录制 | 使用 CoreGraphics 生成其他 App 的窗口缩略图。 |

授权路径：

```text
System Settings
→ Privacy & Security
→ Accessibility

System Settings
→ Privacy & Security
→ Screen & System Audio Recording
```

权限页会把屏幕录制状态明确区分为 **「未开启」**、**「需要重启」** 和 **「已开启」**。首次启动会汇总尚未完成的权限，后续从系统设置返回时按顺序处理当前第一项未完成步骤，并抑制完全相同状态的重复弹窗。初次引导会先调用系统权限请求，再打开对应设置页；仅打开系统设置不会提前显示需要重启。只有系统报告请求已授权、但当前进程预检仍未生效时，正式安装版才会显示 **「重启」**，开发副本会显示 **「切换安装版」**。

权限页也会验证当前副本是否为 `/Applications/Y-Dock.app` 中 Bundle ID 与 Developer ID 团队签名均匹配的正式安装版。开发副本只有在该安装版有效时才允许执行 **「切换安装版」**。**「刷新权限记录」** 只会重置 Y-Dock 自身 Bundle ID 的 Accessibility 与 Screen Capture TCC 记录，不影响其他 App；刷新后需要重新授权并从 `/Applications` 启动正式安装版。

## 🧭 使用方式

1. 启动 Y-Dock。
2. 将鼠标移动到 Dock 中正在运行的 App 图标上。
3. 等待约 `100ms`，预览面板会自动弹出。
4. 点击缩略图切换到对应窗口。
5. hover 某张卡片，左上角可退出所属 App、关闭窗口或最小化窗口；如果开启隐藏式控制按钮，先将鼠标移入卡片左上区域。
6. 可在设置中启用 Dock 点击最小化。目标 App 必须在点击前已经处于前台；点击后台 App 时只执行 macOS 原生激活，不会立即反向最小化。按住 `Control`、`Command`、`Option` 或 `Shift` 点击时也不会触发。
7. 也可以按住 `Option` 并按 `Tab` 打开窗口切换器；首次呼出默认选中 MRU 列表的第二张，只有一张窗口时回退到第一张，继续按 `Tab` 循环，松开 `Option` 后切到当前选中的窗口。hover 某张卡片时，其左上角 App icon 会覆盖为半透明 X，点击可关闭该窗口且不会误激活卡片；关闭后其余列表继续可用。按 `Esc` 会取消并吞掉对应按键事件，不影响底层窗口。

## ⚙️ 设置

点击菜单栏中的双窗口 + Dock 线稿图标可打开设置。该模板图标会自动适配系统浅色/深色菜单栏；Y-Dock 仍是后台菜单栏工具，默认不会显示在 Dock 或 Cmd-Tab 中。

可调整：

- `悬停延迟`：默认 `100ms`。
- `缩略图高度`：默认 `165px`，窗口宽度会按原始比例自适应。
- `显示窗口标题`：控制预览卡片顶部标题栏。
- `开机启动`：使用 macOS 官方 `SMAppService.mainApp`。
- `Dock 点击`：关闭、仅单窗口 App、所有窗口三档；多窗口模式会最小化该 App 当前全部未最小化窗口。
- `控制按钮显示`：可让左上控制按钮默认隐藏，仅悬浮对应区域时显示。
- `控制按钮放大`：可开关 hover 放大，并在设置中连续调整和预览 `16.5–30pt` 的目标尺寸。
- `关闭按钮策略`：可让红色关闭按钮请求正常退出 App，并在全部 App、黑名单、白名单之间切换；两份名单独立持久化。
- `窗口切换`：显示全局快捷键 `Option+Tab`。
- `权限状态`：分别检查辅助功能和屏幕录制，并在屏幕录制授权需要进程重新载入时提供重启或安装版切换操作。
- `当前副本`：诊断正式安装版与开发副本，只切换到签名验证通过的 `/Applications/Y-Dock.app`。
- `调试日志`：输出 `[Y-Dock]` 前缀日志。

## 🛠 技术栈

```text
Swift
AppKit
Accessibility API / AXUIElement
CoreGraphics / CGWindowListCopyWindowInfo / CGWindowListCreateImage
NSPanel / NSStatusItem / NSWorkspace
Carbon / RegisterEventHotKey
ServiceManagement / SMAppService
```

## 🧑‍💻 从源码构建

GitHub 仓库：[Rainchen537/Y-Dock](https://github.com/Rainchen537/Y-Dock)

```sh
git clone https://github.com/Rainchen537/Y-Dock.git
cd Y-Dock
open DockWindowPreview.xcodeproj
```

命令行构建：

```sh
xcodebuild -project DockWindowPreview.xcodeproj \
  -scheme DockWindowPreview \
  -configuration Release \
  -derivedDataPath build/Release-arm64 \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build
```

将 `ARCHS` 和 DerivedData 路径改为 `x86_64` 可构建 Intel thin App。正式发布只通过 `./release.sh` 一次生成并分别验证两个架构的 DMG。

## 🧾 更新日志

完整更新记录见 [CHANGELOG.md](CHANGELOG.md)。

## 🚧 已知限制

macOS 没有公开的 Dock hover API，也没有公开 API 可以从 Dock 图标直接得到 bundle identifier。Y-Dock 通过 Dock.app 的 Accessibility hit-test 读取 `AXTitle` / `AXDescription`，再 best-effort 映射到正在运行的 App。

公开 Accessibility API 也不稳定暴露 `CGWindowID`。窗口激活使用标题、位置、尺寸等信息匹配 AXWindow，再执行 `AXRaise`、`AXMain` 和 `AXFocused`。

最小化窗口无法通过公开 CoreGraphics API 截取实时缩略图，所以会显示“已最小化”占位图。点击后会通过 `AXMinimized = false` 尝试恢复窗口。

hover 卡片时的“只看当前窗口”效果是公开 API 下的视觉模拟：App 会覆盖一层半透明面板并绘制当前窗口截图，不会真的隐藏其它窗口。

`Option+Tab` 通过公开 Carbon HotKey API 注册全局快捷键，并用公开事件监听支持 `Esc` 取消。窗口聚焦仍依赖 Accessibility；如果缺少辅助功能权限，可能只能激活 App，无法稳定聚焦到精确窗口。

全屏 Space、Stage Manager、多显示器、Dock 自动隐藏和 Dock 放大可能影响命中测试和面板定位。

## 🗺 后续计划

- 更稳定的 Dock 图标命中缓存。
- 多屏幕坐标修正。
- 更漂亮的动效和 hover 过渡。
