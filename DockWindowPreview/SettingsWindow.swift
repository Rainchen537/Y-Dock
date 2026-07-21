import AppKit
import Foundation

final class SettingsWindowController: NSObject {
    private let contentController: SettingsContentController
    private let windowController: YSettingWindowController

    init(
        settings: AppSettings = .shared,
        permissionsManager: PermissionsManager = PermissionsManager(),
        launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager(),
        updateChecker: UpdateChecker = .shared
    ) {
        contentController = SettingsContentController(
            settings: settings,
            permissionsManager: permissionsManager,
            launchAtLoginManager: launchAtLoginManager,
            updateChecker: updateChecker
        )

        let descriptor = YSettingAppDescriptor(
            displayName: AppBranding.displayName,
            subtitle: "Dock 多窗口预览",
            version: "v\(updateChecker.currentVersion)",
            icon: AppIconFactory.appIcon(size: 78)
        )
        let items = YSettingStandardSidebar.all
        let contentController = contentController
        windowController = YSettingWindowController(
            descriptor: descriptor,
            sidebarItems: items,
            initialIdentifier: "general"
        ) { identifier in
            contentController.makeContent(for: identifier)
        }

        super.init()

        windowController.onClose = { [weak self] in
            self?.contentController.stopPresentation()
        }
    }

    var isShown: Bool {
        windowController.isVisible
    }

    func show() {
        contentController.refreshForPresentation()
        contentController.startPresentation()
        windowController.showAndActivate()
    }

    func close() {
        windowController.close()
    }

    func selectItem(_ identifier: String) {
        windowController.selectItem(identifier)
    }
}

private final class SettingsContentController {
    private let settings: AppSettings
    private let permissionsManager: PermissionsManager
    private let launchAtLoginManager: LaunchAtLoginManager
    private let updateChecker: UpdateChecker
    private let githubURL = AppBranding.repositoryURL

    private let hoverDelaySlider = NSSlider(value: 0.10, minValue: 0.05, maxValue: 0.8, target: nil, action: nil)
    private let hoverDelayValuePill = YSettingPill(text: "100 ms", tone: .accent)
    private let thumbnailSlider = NSSlider(value: 165, minValue: 100, maxValue: 260, target: nil, action: nil)
    private let thumbnailValuePill = YSettingPill(text: "165 px", tone: .neutral)
    private let launchAtLoginStatusPill = YSettingPill(text: "未开启", tone: .neutral)
    private let updateStatusPill = YSettingPill(text: "", tone: .neutral)
    private let accessibilityStatusPill = YSettingPill(text: "检测中", tone: .neutral)
    private let screenCaptureStatusPill = YSettingPill(text: "检测中", tone: .neutral)
    private let runtimeIdentityPill = YSettingPill(text: "检测中", tone: .neutral)
    private let optionTabShortcutPill = YSettingPill(text: "⌥ Tab", tone: .accent)

    private lazy var showTitleSwitch = YSettingUI.makeSwitch(target: self, action: #selector(showTitleChanged(_:)))
    private lazy var launchAtLoginSwitch = YSettingUI.makeSwitch(target: self, action: #selector(launchAtLoginChanged(_:)))
    private lazy var debugSwitch = YSettingUI.makeSwitch(target: self, action: #selector(debugChanged(_:)))
    private lazy var openLoginItemsButton = makeButton(title: "登录项", symbolName: "person.crop.circle.badge.checkmark", action: #selector(openLoginItemsSettings))
    private lazy var checkUpdatesButton = makeButton(title: "检查更新", symbolName: "arrow.triangle.2.circlepath", role: .primary, action: #selector(checkForUpdatesClicked))
    private lazy var githubButton = makeButton(title: "GitHub", symbolName: "chevron.left.forwardslash.chevron.right", role: .link, action: #selector(openGitHub))
    private lazy var requestAccessibilityButton = makeButton(title: "请求", symbolName: "hand.raised", action: #selector(requestAccessibilityPermission))
    private lazy var openAccessibilityButton = makeButton(title: "打开", symbolName: "gearshape", action: #selector(openAccessibilitySettings))
    private lazy var requestScreenCaptureButton = makeButton(title: "请求", symbolName: "rectangle.on.rectangle", action: #selector(requestScreenCapturePermission))
    private lazy var openScreenCaptureButton = makeButton(title: "打开", symbolName: "gearshape", action: #selector(openScreenCaptureSettings))
    private lazy var restartForScreenCaptureButton = makeButton(title: "重启", symbolName: "arrow.clockwise", role: .primary, action: #selector(restartForScreenCapture))
    private lazy var switchToInstalledButton = makeButton(title: "切换到安装版", symbolName: "arrow.right.app", role: .primary, action: #selector(switchToInstalledCopy))
    private lazy var requestAllButton = makeButton(title: "请求缺失权限", symbolName: "lock.open", role: .primary, action: #selector(requestAllPermissions))
    private lazy var resetPermissionsButton = makeButton(title: "刷新权限记录", symbolName: "arrow.counterclockwise", action: #selector(resetPrivacyPermissions))
    private lazy var recheckButton = makeButton(title: "重新检测", symbolName: "checkmark.shield", action: #selector(recheckPermissions))

    private var isObservingApplicationActivation = false

    init(
        settings: AppSettings,
        permissionsManager: PermissionsManager,
        launchAtLoginManager: LaunchAtLoginManager,
        updateChecker: UpdateChecker
    ) {
        self.settings = settings
        self.permissionsManager = permissionsManager
        self.launchAtLoginManager = launchAtLoginManager
        self.updateChecker = updateChecker
        configureControls()
        refreshValues()
    }

    deinit {
        stopPresentation()
    }

    func makeContent(for identifier: String) -> NSView {
        switch identifier {
        case "features":
            return featuresContent()
        case "permissions":
            return permissionsContent()
        case "updates":
            return updatesContent()
        case "about":
            return aboutContent()
        default:
            return generalContent()
        }
    }

    func refreshForPresentation() {
        refreshValues()
    }

    func startPresentation() {
        if !isObservingApplicationActivation {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(recheckPermissions),
                name: NSApplication.didBecomeActiveNotification,
                object: nil
            )
            isObservingApplicationActivation = true
        }
    }

    func stopPresentation() {
        if isObservingApplicationActivation {
            NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
            isObservingApplicationActivation = false
        }
    }

    private func generalContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "通用",
            symbolName: "gearshape"
        )

        stack.addArrangedSubview(YSettingSectionView(
            title: "启动与快捷键",
            symbolName: "menubar.rectangle",
            views: [
                statusSwitchActionRow(
                    title: "开机启动",
                    statusPill: launchAtLoginStatusPill,
                    switchControl: launchAtLoginSwitch,
                    actionButton: openLoginItemsButton
                ),
                YSettingUI.divider(),
                statusRow(title: "窗口切换", statusPill: nil, trailingView: optionTabShortcutPill),
                YSettingUI.row(title: "启用调试日志", trailingView: debugSwitch)
            ]
        ))

        return stack
    }

    private func featuresContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "功能",
            symbolName: "slider.horizontal.3"
        )

        stack.addArrangedSubview(YSettingSectionView(
            title: "Dock 悬浮预览",
            symbolName: "dock.rectangle",
            views: [
                YSettingUI.sliderRow(title: "悬停延迟", slider: hoverDelaySlider, valueView: hoverDelayValuePill),
                YSettingUI.sliderRow(title: "缩略图高度", slider: thumbnailSlider, valueView: thumbnailValuePill),
                YSettingUI.divider(),
                YSettingUI.row(title: "显示窗口标题", trailingView: showTitleSwitch)
            ]
        ))

        return stack
    }

    private func updatesContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "更新",
            symbolName: "arrow.triangle.2.circlepath"
        )

        stack.addArrangedSubview(YSettingSectionView(
            title: "版本更新",
            symbolName: "sparkles",
            views: [
                statusRow(title: "当前版本", statusPill: updateStatusPill, trailingView: checkUpdatesButton),
                statusRow(title: "发布渠道", statusPill: nil, trailingView: YSettingPill(text: "GitHub Release", tone: .accent))
            ]
        ))

        return stack
    }

    private func permissionsContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "权限",
            symbolName: "lock.shield"
        )

        stack.addArrangedSubview(YSettingSectionView(
            title: "隐私权限",
            symbolName: "checkmark.shield",
            views: [
                YSettingUI.row(
                    title: "当前副本",
                    trailingView: YSettingUI.horizontal([runtimeIdentityPill, switchToInstalledButton], spacing: 6)
                ),
                permissionRow(
                    title: "辅助功能",
                    statusPill: accessibilityStatusPill,
                    requestButton: requestAccessibilityButton,
                    openButton: openAccessibilityButton
                ),
                YSettingUI.row(title: "屏幕录制", trailingView: screenCaptureStatusPill),
                YSettingUI.row(
                    title: "屏幕录制操作",
                    trailingView: YSettingUI.horizontal([requestScreenCaptureButton, openScreenCaptureButton, restartForScreenCaptureButton], spacing: 6)
                ),
                YSettingUI.row(
                    title: "权限修复",
                    trailingView: YSettingUI.horizontal([resetPermissionsButton, recheckButton], spacing: 6)
                ),
                actionRow(primary: requestAllButton)
            ]
        ))

        return stack
    }

    private func aboutContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "关于",
            symbolName: "info.circle"
        )

        stack.addArrangedSubview(YSettingSectionView(
            title: "Y-Project",
            symbolName: "app.connected.to.app.below.fill",
            views: [
                statusRow(title: "产品定位", statusPill: nil, trailingView: YSettingPill(text: "Dock 多窗口预览", tone: .accent)),
                statusRow(title: "项目主页", statusPill: nil, trailingView: githubButton)
            ]
        ))

        return stack
    }

    private func statusSwitchActionRow(
        title: String,
        statusPill: YSettingPill,
        switchControl: NSSwitch,
        actionButton: NSButton
    ) -> NSView {
        let trailing = YSettingUI.horizontal([statusPill, switchControl, actionButton])
        return statusRow(title: title, statusPill: nil, trailingView: trailing)
    }

    private func statusRow(title: String, statusPill: YSettingPill?, trailingView: NSView) -> NSView {
        if let statusPill {
            return YSettingUI.row(title: title, trailingView: YSettingUI.horizontal([statusPill, trailingView]))
        }

        return YSettingUI.row(title: title, trailingView: trailingView)
    }

    private func permissionRow(
        title: String,
        statusPill: YSettingPill,
        requestButton: NSButton,
        openButton: NSButton
    ) -> NSView {
        let actions = YSettingUI.horizontal([requestButton, openButton], spacing: 6)
        return statusRow(title: title, statusPill: statusPill, trailingView: actions)
    }

    private func actionRow(primary: NSButton, secondary: NSButton? = nil) -> NSView {
        let actions = secondary.map { [primary, $0] } ?? [primary]
        let row = NSStackView(views: [YSettingUI.spacer()] + actions)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func makeButton(
        title: String,
        symbolName: String,
        role: YSettingButtonRole = .secondary,
        action: Selector
    ) -> NSButton {
        YSettingUI.makeButton(title: title, symbolName: symbolName, role: role, target: self, action: action)
    }

    private func configureControls() {
        hoverDelaySlider.target = self
        hoverDelaySlider.action = #selector(hoverDelayChanged(_:))
        hoverDelaySlider.controlSize = .small

        thumbnailSlider.target = self
        thumbnailSlider.action = #selector(thumbnailSizeChanged(_:))
        thumbnailSlider.controlSize = .small

        updateStatusPill.setText("v\(updateChecker.currentVersion)", tone: .neutral)
    }

    private func refreshValues() {
        hoverDelaySlider.doubleValue = settings.hoverDelay
        hoverDelayValuePill.setText(String(format: "%.0f ms", settings.hoverDelay * 1000), tone: .accent)

        thumbnailSlider.doubleValue = Double(settings.thumbnailHeight)
        thumbnailValuePill.setText(String(format: "%.0f px", settings.thumbnailHeight), tone: .neutral)

        showTitleSwitch.state = settings.showWindowTitles ? .on : .off
        debugSwitch.state = settings.debugLoggingEnabled ? .on : .off
        refreshLaunchAtLoginStatus()
        refreshPermissionStatus()
    }

    private func refreshLaunchAtLoginStatus() {
        switch launchAtLoginManager.status {
        case .enabled:
            launchAtLoginSwitch.state = .on
            launchAtLoginStatusPill.setText("已开启", tone: .success)
        case .requiresApproval:
            launchAtLoginSwitch.state = .on
            launchAtLoginStatusPill.setText("需批准", tone: .warning)
        case .notRegistered:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatusPill.setText("未开启", tone: .neutral)
        case .notFound:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatusPill.setText("不可用", tone: .danger)
        @unknown default:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatusPill.setText("未知", tone: .warning)
        }

        settings.launchAtLogin = launchAtLoginManager.isEnabled
    }

    func refreshPermissionStatus() {
        let isInstalledCopy = permissionsManager.isRunningInstalledCopy()
        let hasInstalledCopy = permissionsManager.hasValidInstalledApplication()
        runtimeIdentityPill.setText(isInstalledCopy ? "正式安装版" : "开发副本", tone: isInstalledCopy ? .success : .warning)
        switchToInstalledButton.isHidden = isInstalledCopy
        switchToInstalledButton.isEnabled = hasInstalledCopy

        let accessibilityTrusted = permissionsManager.isAccessibilityTrusted()
        if accessibilityTrusted {
            accessibilityStatusPill.setText("已开启", tone: .success)
        } else if !isInstalledCopy, hasInstalledCopy {
            accessibilityStatusPill.setText("当前副本未授权", tone: .warning)
        } else {
            accessibilityStatusPill.setText("未开启", tone: .warning)
        }
        requestAccessibilityButton.isEnabled = !accessibilityTrusted

        let screenCaptureState = permissionsManager.screenCapturePermissionState()
        switch screenCaptureState {
        case .missing where !isInstalledCopy && hasInstalledCopy:
            screenCaptureStatusPill.setText("当前副本未授权", tone: .warning)
        case .missing:
            screenCaptureStatusPill.setText("未开启", tone: .warning)
        case .restartRequired:
            screenCaptureStatusPill.setText("需要重启", tone: .accent)
        case .active:
            screenCaptureStatusPill.setText("已开启", tone: .success)
        }
        requestScreenCaptureButton.isHidden = screenCaptureState != .missing
        restartForScreenCaptureButton.isHidden = screenCaptureState != .restartRequired
        restartForScreenCaptureButton.title = isInstalledCopy ? "重启" : "切换安装版"
        restartForScreenCaptureButton.isEnabled = isInstalledCopy || hasInstalledCopy
        requestAllButton.isEnabled = !accessibilityTrusted || screenCaptureState == .missing
    }

    func requestMissingPermissions() {
        _ = permissionsManager.requestMissingPrivacyPermissions()
        refreshPermissionStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshPermissionStatus()
        }
    }

    @objc private func hoverDelayChanged(_ sender: NSSlider) {
        settings.hoverDelay = sender.doubleValue
        refreshValues()
    }

    @objc private func thumbnailSizeChanged(_ sender: NSSlider) {
        settings.thumbnailHeight = CGFloat(sender.doubleValue)
        refreshValues()
    }

    @objc private func showTitleChanged(_ sender: NSSwitch) {
        settings.showWindowTitles = sender.state == .on
        refreshValues()
    }

    @objc private func launchAtLoginChanged(_ sender: NSSwitch) {
        let shouldEnable = sender.state == .on
        switch launchAtLoginManager.setEnabled(shouldEnable) {
        case .success:
            refreshLaunchAtLoginStatus()
            if launchAtLoginManager.status == .requiresApproval {
                showLaunchAtLoginApprovalAlert()
            }
        case .failure(let error):
            refreshLaunchAtLoginStatus()
            showLaunchAtLoginError(error)
        }
    }

    @objc private func debugChanged(_ sender: NSSwitch) {
        settings.debugLoggingEnabled = sender.state == .on
        refreshValues()
    }

    @objc private func checkForUpdatesClicked() {
        checkUpdatesButton.isEnabled = false
        updateStatusPill.setText("检查中", tone: .neutral)

        updateChecker.checkForUpdates { [weak self] result in
            DispatchQueue.main.async {
                self?.checkUpdatesButton.isEnabled = true
                self?.handleUpdateCheckResult(result, showsAlert: true)
            }
        }
    }

    private func handleUpdateCheckResult(_ result: UpdateChecker.CheckResult, showsAlert: Bool) {
        switch result {
        case .updateAvailable(_, let latest):
            updateStatusPill.setText("新版本 \(latest.displayVersion)", tone: .accent)
            if showsAlert {
                showUpdateAvailableAlert(latest)
            }
        case .upToDate(let currentVersion, _):
            updateStatusPill.setText("最新版 \(currentVersion)", tone: .success)
        case .failure(let error):
            updateStatusPill.setText("检查失败", tone: .warning)
            if showsAlert {
                showUpdateCheckError(error)
            }
        }
    }

    @objc private func requestAllPermissions() {
        requestMissingPermissions()
    }

    @objc private func recheckPermissions() {
        refreshLaunchAtLoginStatus()
        refreshPermissionStatus()
    }

    @objc private func requestAccessibilityPermission() {
        _ = permissionsManager.requestAccessibilityPermission()
        refreshPermissionStatus()
    }

    @objc private func openAccessibilitySettings() {
        permissionsManager.openAccessibilitySettings()
    }

    @objc private func requestScreenCapturePermission() {
        _ = permissionsManager.requestScreenCapturePermission()
        refreshPermissionStatus()
    }

    @objc private func restartForScreenCapture() {
        permissionsManager.relaunchInstalledApplication()
    }

    @objc private func switchToInstalledCopy() {
        permissionsManager.relaunchInstalledApplication()
    }

    @objc private func resetPrivacyPermissions() {
        resetPermissionsButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                guard let self else { return }
                try self.permissionsManager.resetPrivacyPermissions()
                DispatchQueue.main.async {
                    self.permissionsManager.didResetPrivacyPermissions()
                    self.resetPermissionsButton.isEnabled = true
                    self.refreshPermissionStatus()
                    self.showPermissionResetAlert()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.resetPermissionsButton.isEnabled = true
                    let alert = NSAlert(error: error)
                    alert.messageText = "刷新权限记录失败"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    @objc private func openScreenCaptureSettings() {
        permissionsManager.openScreenCaptureSettings()
        refreshPermissionStatus()
    }

    private func showPermissionResetAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "已刷新 Y-Dock 权限记录"
        alert.informativeText = "请重新开启辅助功能和屏幕录制权限，然后使用“重启”从 /Applications 启动正式安装版。"
        alert.addButton(withTitle: "打开辅助功能")
        alert.addButton(withTitle: "打开屏幕录制")
        alert.addButton(withTitle: "稍后")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            permissionsManager.openAccessibilitySettings()
        case .alertSecondButtonReturn:
            permissionsManager.openScreenCaptureSettings()
            refreshPermissionStatus()
        default:
            break
        }
    }

    @objc private func openLoginItemsSettings() {
        launchAtLoginManager.openLoginItemsSettings()
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(githubURL)
    }

    private func showLaunchAtLoginApprovalAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要批准开机启动"
        alert.informativeText = "请在 System Settings → General → Login Items 中允许 \(AppBranding.displayName)。"
        alert.addButton(withTitle: "打开登录项设置")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn {
            launchAtLoginManager.openLoginItemsSettings()
        }
    }

    private func showLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "开机启动设置失败"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func showUpdateAvailableAlert(_ release: UpdateChecker.ReleaseInfo) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 \(release.displayVersion)"

        guard release.downloadURL != nil else {
            alert.informativeText = "\(release.name)\n\n未找到当前架构所需的 \(release.expectedAssetName)。为避免安装错误架构，Y-Dock 不会改用其他 DMG。请打开 Release 页面手动确认。"
            alert.addButton(withTitle: "打开 Release 页面")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                updateChecker.openReleasePage(release)
            }
            return
        }

        alert.informativeText = "\(release.name)\n\n可以直接下载、安装并重启。"
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "打开页面")
        alert.addButton(withTitle: "稍后")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            installUpdate(release)
        case .alertSecondButtonReturn:
            updateChecker.openDownloadOrReleasePage(release)
        default:
            break
        }
    }

    private func installUpdate(_ release: UpdateChecker.ReleaseInfo) {
        checkUpdatesButton.isEnabled = false
        updateChecker.downloadAndInstall(release) { [weak self] status in
            DispatchQueue.main.async {
                self?.updateStatusPill.setText(status.displayText, tone: .accent)
            }
        } completion: { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.updateStatusPill.setText("正在重启", tone: .accent)
                case .failure(let error):
                    self?.checkUpdatesButton.isEnabled = true
                    self?.updateStatusPill.setText("安装失败", tone: .warning)
                    self?.showUpdateInstallError(error)
                }
            }
        }
    }

    private func showUpdateCheckError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "检查更新失败"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func showUpdateInstallError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "自动更新失败"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
