# Y-Dock 工作记录

## 2026-07-24

- 从已提交的 `v1.1.23` 后基线创建 `codex/unify-ydock-monitoring` 分支；保留并排除用户已有的 `.claude/`、`OptionTabSwitcher 2.swift` 和 `PreviewPanel 2.swift` 未跟踪内容。
- vendoring `Y-Framework/Monitoring` v1.0.0，并加入 Xcode target Sources。
- 以单个 `YNSEventMonitorHub` 接入 MouseTracker、OptionTabSwitcher 和 DesktopWindowControlsController，把原有 `5 global + 5 local` 原生 AppKit monitor 收敛为 `1 global + 1 local`。
- 保留 Carbon `Option+Tab`、Esc 同步消费 `CGEventTap`、AXObserver、Workspace 通知、截图和业务计时器的原有所有权。
- local observer 先完成全部状态更新，再由 Option+Tab local interceptor 决定是否消费事件，避免吞键或吞点击导致其他模块状态丢失。
- 桌面红绿灯关闭时不再保留其鼠标订阅和 descriptor timer；30 Hz 遮挡 timer 只在至少一颗增强按钮实际可见时运行。
- 新增 Monitoring fake-backend standalone 测试，并把双架构测试及 vendored 非符号链接检查加入 `release.sh`。
- 当前源码版本递增为 `1.1.24 (49)`。
- Monitoring standalone 测试在 `arm64` / `x86_64` 均通过；App 的
  Debug 与 Release 均完成双架构构建，两个 Release 主可执行文件分别断言为
  thin `arm64` / thin `x86_64`，版本与构建号一致；arm64 静态分析通过。
- 单实例运行日志确认桌面增强关闭时业务订阅为 `2 global / 3 local`、开启时为
  `3 global / 4 local`，两种状态的底层原生 monitor 均保持为
  `1 global + 1 local`；测试后已关闭所有 Y-Dock 实例并恢复用户偏好。
- 临时未安装构建因签名身份不匹配无法复用安装版的 Esc event-tap 权限；该路径
  留待最终签名、公证并从 DMG 安装后复核，不能据此宣称正式交互验证完成。
- 正式发布结果在完成后继续追加。
