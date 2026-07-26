# Y-Dock 版本记录

## 当前版本

- 产品版本：`1.1.25`
- 构建号：`50`
- 状态：已正式发布；桌面窗口红绿灯覆盖功能已完整移除
- Y-Framework/Monitoring：`1.0.0`

## 版本规则

- 修复、后台效率改进和保持兼容的内部重构递增补丁版本。
- 新增向后兼容的用户功能递增次版本。
- 不兼容的设置、数据、权限或更新协议变化递增主版本。
- 每次版本变化必须同步 Xcode 的 `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION`、README 下载链接、changelog、tag、两份 thin DMG
  和 GitHub Release。

## v1.1.25 (50)

- 完整删除桌面窗口红绿灯增强、覆盖面板、红黄绿动作、红钮退出策略及其设置。
- 删除相关 CGWindow/AXWindow 匹配、鼠标订阅、窗口/Space 观察、刷新和 30 Hz
  遮挡计时器；升级时清理已废弃的桌面红绿灯及旧预览策略偏好键。
- 保留 Dock 预览卡片控制、Dock 点击最小化和 `Option+Tab` 单窗口关闭入口。
- 延续 Monitoring 1.0.0 的单组 AppKit global/local monitor，并保持 Esc 同步
  event tap 仅在 `Option+Tab` 会话期间启用。
- arm64/x86_64 两份 strict thin DMG 已分别完成 Developer ID 签名、公证、
  staple、Gatekeeper 与镜像验证；正式 arm64 安装版已覆盖安装并通过运行冒烟。
- 发布源码提交与 tag：`c54183e` / `v1.1.25`。
- GitHub Release：`https://github.com/Rainchen537/Y-Dock/releases/tag/v1.1.25`。
