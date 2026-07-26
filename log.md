# Y-Dock 工作记录

## 2026-07-27

- Dock 主按钮点击新增“最小化 / 隐藏”独立动作设置；触发范围继续支持关闭、仅单窗口
  App 和所有 App，默认动作保持最小化。
- 隐藏动作复用公开 `NSRunningApplication.hide()`，并继续要求目标 App 在点击前已经
  位于前台且其普通用户窗口位于窗口堆栈最上层；后台或被遮挡 App 保留原生行为。
- 关闭 Dock 点击触发时动作下拉框同步禁用；AppSettings 策略测试新增默认值、
  隐藏持久化、展示名称与无效值回退覆盖，arm64/x86_64 均通过。
- 资产选择、AppSettings 和 Monitoring 三组 standalone 测试在 arm64/x86_64
  均通过；Debug/Release arm64/x86_64 四种组合均构建通过并确认为
  `1.3.0 (52)` strict thin 对应架构，arm64 静态分析通过。
- 功能设置页截图确认 Dock 点击的“触发范围 / 执行动作”两行完整显示且无溢出，
  截图测试进程已关闭。
- 当前版本准备递增为 `1.3.0 (52)`，待完成双架构构建、正式发布与本机安装闭环。
- 将 Dock 悬浮缩略图卡片黄色按钮扩展为“最小化 / 隐藏”两种动作。
- 新增持久化设置与功能页下拉选项，默认保留原有“最小化”；选择“隐藏”时使用公开
  `NSRunningApplication.hide()` 隐藏所属 App，并让按钮提示同步变化。
- 受控外部 App 探针确认 `hide()` 即使瞬时返回 `false` 也会异步完成隐藏；实现改为
  接受已发出的公开隐藏请求，并延迟检查最终状态，避免动作成功后误响失败提示音。
- 资产选择、AppSettings 策略和 Monitoring 三组 standalone 测试在 arm64/x86_64
  均通过；Debug/Release arm64/x86_64 四种组合均构建通过并确认为
  `1.2.0 (51)` strict thin 对应架构，arm64 静态分析通过。
- 功能设置页截图确认新增下拉框完整显示且默认选择“最小化”；截图进程已关闭。
- 受控外部 App 通过本次真实动作路径隐藏成功，报告 `isHidden=true` 且窗口不可见，
  受控进程已自行退出。
- 从干净源码提交 `0f1df64` 完成正式双架构发布。arm64 App/DMG 公证 ID 为
  `126ae4ee-1101-427f-a67f-852e01a34c5d` /
  `beff02ea-63c6-4962-8a9c-3297e7fc8f45`；x86_64 App/DMG 为
  `eb44d789-ddc3-484e-a0f9-e27e87171e52` /
  `fddcb04f-6497-4ec2-9911-6ca9463c41f1`，全部 Accepted。
- 最终 arm64 DMG 为 `1,688,802` bytes，SHA-256
  `bed545c4f9fbed79990e39063c0c1c0cfedd48809f9c1c0582553d2d30338d4b`；
  x86_64 DMG 为 `1,718,525` bytes，SHA-256
  `d1da925b052ae15d0f59df63297242c30ce480e8f6a87b8cbf1c11f0a5dbfd55`。
  两包均通过独立签名、公证、staple、Gatekeeper、镜像和 strict thin 架构验证；
  x86_64 App 通过 Rosetta 启动并打开功能设置页后主动结束。
- 从最终 arm64 DMG 覆盖安装 `/Applications/Y-Dock.app`，确认版本
  `1.2.0 (51)`、thin arm64、Bundle ID、Developer ID、hardened runtime、
  签名、ticket 与 Gatekeeper 正常；被替换的 `1.1.25` App 已可恢复地移至
  `/Users/lixingchen/.Trash/Y-Dock-v1.1.25-pre-v1.2.0.app`。
- `v1.2.0` tag 保持指向功能源码提交 `0f1df64`。GitHub Release 已公开：
  `https://github.com/Rainchen537/Y-Dock/releases/tag/v1.2.0`；latest API
  与 GitHub App 均确认只有 arm64、x86_64 两份 DMG，arm64 在前，远端正文、
  大小与摘要均匹配本地。

## 2026-07-26

- 按用户要求完整移除难用且会引入覆盖扫描开销的桌面窗口红绿灯实验功能。
- 删除桌面控制器源码、工程引用、App 生命周期入口、覆盖面板、红黄绿动作、鼠标和工作区监听、0.45 秒刷新与 30 Hz 遮挡计时器。
- 删除功能页的桌面红绿灯和桌面红钮策略设置，以及相关策略/持久化代码；升级时清理现行与旧版遗留偏好键。
- 保留 macOS 原生红黄绿、Dock 预览卡片控制、Dock 点击最小化与 `Option+Tab` 关闭入口。
- 更新资产选择、AppSettings 策略和 Monitoring 框架三组 standalone 测试均以
  strict thin `arm64` / `x86_64` 编译运行通过。
- arm64/x86_64 Debug 与 Release 四种组合均构建通过，版本为 `1.1.25 (50)`，
  主可执行文件分别为目标单一架构；arm64 静态分析通过。
- 功能设置页截图确认只剩 Dock 悬浮预览和 Dock 点击设置，截图测试进程已关闭。
- 从干净源码提交 `c54183e` 完成双架构正式发布。arm64 App/DMG 公证 ID 为
  `267fd375-89fd-467b-b2d4-d74cde1354ed` /
  `e1dd0fe6-4499-496f-979e-b1090022076c`；x86_64 App/DMG 为
  `7480726c-5f76-4bfd-ba91-1cd81c20b3a2` /
  `9dd9f815-4173-44fd-91bf-066a6d835bb6`，全部 Accepted。
- 最终 arm64 DMG 为 `1,686,481` bytes，SHA-256
  `86057c7fc6fbc037a7a524d9b3b9a3997361843b830203d9e676f3e69b32533f`；
  x86_64 DMG 为 `1,715,772` bytes，SHA-256
  `7b4652a1965105602e84eec544de8d463ca07a9b39b5352bc4cc8f9d64bba6c8`。
  两包均通过独立签名、公证、staple、Gatekeeper、镜像和 strict thin 架构验证，
  x86_64 App 通过 Rosetta 短暂启动冒烟。
- 从最终 arm64 DMG 覆盖安装 `/Applications/Y-Dock.app`，确认版本
  `1.1.25 (50)`、thin arm64、签名、ticket 与 Gatekeeper 正常；运行日志确认
  consolidated NSEvent monitor 为单组 global/local，业务订阅为
  `2 global / 3 local`，废弃桌面控制偏好键未残留。
- `v1.1.25` tag 保持指向功能源码提交 `c54183e`。GitHub Release 已公开：
  `https://github.com/Rainchen537/Y-Dock/releases/tag/v1.1.25`；latest API
  确认只有 arm64、x86_64 两份 DMG，arm64 在前，远端大小与摘要均匹配本地。

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
- 收到正式安装版一启动即造成键盘输入卡顿、系统交互偶发卡顿的反馈后，现场读取
  `CGGetEventTapList`：空闲 Y-Dock 仅约 `0% CPU`，但其同步键盘 tap 已被
  macOS 自动置为 `enabled=false`，符合常驻主线程 tap 超时后由系统保护性停用
  的症状。修复为启动时零键盘 tap、仅在 Option+Tab 会话内临时启用。
- arm64 Debug/Release 修复版均构建通过。用相同 Developer ID 签名并放到
  `/Applications/Y-Dock.app` 后做真实 Carbon 热键路径验证：启动空闲时
  `idle_tap_count=0`；真实 Option+Tab 触发后 tap 对象按需创建，Option 松开后
  保留对象但 `enabled=false`，普通键盘输入不再经过同步拦截器。旧
  `1.1.23` 安装包完整保存在
  `/Applications/Y-Dock.app.pre-runtime-test-1.1.23`，当前测试副本仍不是
  最终公证 DMG 安装结果。
- 正式发布从提交 `45ebaf3` 的干净 worktree 启动：双架构 standalone
  测试再次通过，arm64 Debug/Release、Developer ID 签名、App 独立公证、
  staple 与 Gatekeeper 验证均通过，App 公证 submission ID 为
  `cfafdec8-f7ea-4181-9267-2a4735013039`。
- arm64 DMG 已生成、签名并提交 Apple，submission ID
  `b67340e1-105d-4492-9ae8-293cd7b9cc8a` 在持续约一小时后仍由 Apple
  返回 `In Progress`。本地发布脚本已安全中止并清理 DerivedData、stage 与
  release lock，仅在临时目录保留该 DMG 和 notary 日志供续查；未生成最终
  成套 `dist`、未创建 `v1.1.24` tag、未上传 GitHub Release、未替换
  `/Applications/Y-Dock.app`，因此不得宣称 `v1.1.24` 已正式发布。
