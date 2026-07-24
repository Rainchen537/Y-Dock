# Y-Dock 版本记录

## 当前版本

- 产品版本：`1.1.24`
- 构建号：`49`
- 状态：键盘卡顿修复已完成真实热键路径预验证；正式发布待重新生成双架构公证包
- Y-Framework/Monitoring：`1.0.0`

## 版本规则

- 修复、后台效率改进和保持兼容的内部重构递增补丁版本。
- 新增向后兼容的用户功能递增次版本。
- 不兼容的设置、数据、权限或更新协议变化递增主版本。
- 每次版本变化必须同步 Xcode 的 `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION`、README 下载链接、changelog、tag、两份 thin DMG
  和 GitHub Release。

## v1.1.24 (49)

- 首次接入 Monitoring 1.0.0。
- Y-Dock 的 AppKit global/local monitor 从 `5 + 5` 收敛为 `1 + 1`。
- 桌面红绿灯监听和计时器改为按功能状态与可见按钮动态启停。
- Esc 同步事件 tap 改为仅在 Option+Tab 会话期间启用，避免普通键盘输入被
  Y-Dock 主线程反压。
