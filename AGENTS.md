# Y-Dock Agent 规范

本项目遵守父目录 `../AGENTS.md` 和 `../Y_PROJECT_APP_STANDARD.me`。开始任务前阅读本文件、`AI_CONTEXT.me`、`CHANGELOG.me`、`CHANGELOG.md` 和 `README.md`。

## 项目身份

- GitHub：`https://github.com/Rainchen537/Y-Dock`
- 默认分支：`master`
- Bundle ID：`com.lixingchen.DockWindowPreview`
- 产品和可执行文件名：`Y-Dock`
- 安装路径：`/Applications/Y-Dock.app`
- 版本位置：`DockWindowPreview.xcodeproj/project.pbxproj` 中 Debug/Release 两处 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`
- 正式 DMG：`dist/Y-Dock-vX.Y.Z.dmg`

Xcode project 和 scheme 的内部名称继续使用 `DockWindowPreview`，不得因仓库改名而修改。不得引入 macOS 私有 API。

## 构建、验证与发布

- 只在 Y-Dock 实际被修改时处理本项目；其他 App 或未同步进本仓库的共享框架变化不触发 Y-Dock 构建和发布。
- 构建使用 `DockWindowPreview` scheme，并确保 vendored Setting 与 Permission 框架仍在 target Sources。
- 验证范围跟随改动：Dock hover、窗口卡片或 Option+Tab 只检查相关交互；权限、设置、更新等未受影响功能不重复做全量回归。
- 需要正式分发时递增版本和构建号，更新 README 与 changelog，并以 `./release.sh` 作为唯一发布入口。
- 正式发布产物必须完成 Developer ID 签名、公证、staple 和 Gatekeeper 验证；从最终 DMG 覆盖安装后，仅对本次改动和必要核心入口做冒烟检查。
