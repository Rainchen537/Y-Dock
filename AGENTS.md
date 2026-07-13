# Y-Dock Agent 规范

本项目遵守父目录 `../AGENTS.md` 和 `../Y_PROJECT_APP_STANDARD.me`。开始任务前必须阅读本文件、`AI_CONTEXT.me`、`CHANGELOG.me`、`CHANGELOG.md` 和 `README.md`。

## 项目身份

- GitHub：`https://github.com/Rainchen537/Y-Dock`
- 默认分支：`master`
- Bundle ID：`com.lixingchen.DockWindowPreview`
- 产品和可执行文件名：`Y-Dock`
- 安装路径：`/Applications/Y-Dock.app`
- 版本位置：`DockWindowPreview.xcodeproj/project.pbxproj` 中 Debug/Release 两处 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`
- 正式 DMG：`dist/Y-Dock-vX.Y.Z.dmg`

Xcode project 和 scheme 的内部名称继续使用 `DockWindowPreview`，不得因仓库改名而修改。

## 每次任务的发布闭环

1. 先完成 Debug 和 Release 构建验证，确保 `Y-Framework/Setting/YSettingsFramework.swift` 位于 target Sources。
2. 同步更新两套版本字段、README 和两个 changelog。
3. 运行 `./release.sh`，确认 App/DMG 已签名、公证、staple 且 Gatekeeper 验证通过。
4. 提交源码，创建并推送 `vX.Y.Z` tag，在 `Rainchen537/Y-Dock` 创建 Release 并上传该 DMG。
5. 退出 `Y-Dock`，挂载最终 DMG，将其中的 `Y-Dock.app` 覆盖安装到 `/Applications`，验证签名和版本后启动。
6. 验证 Dock hover、多窗口卡片、Option+Tab、辅助功能和屏幕录制权限、设置页及更新入口。

不得引入 macOS 私有 API，也不得跳过真实窗口交互验证。
