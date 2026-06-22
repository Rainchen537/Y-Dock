import AppKit
import Foundation

final class SettingsPopoverController: NSObject, NSPopoverDelegate {
    private let viewController: SettingsViewController
    private let popover: NSPopover
    private weak var anchorButton: NSStatusBarButton?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    init(
        settings: AppSettings = .shared,
        permissionsManager: PermissionsManager = PermissionsManager(),
        launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager(),
        updateChecker: UpdateChecker = .shared
    ) {
        viewController = SettingsViewController(
            settings: settings,
            permissionsManager: permissionsManager,
            launchAtLoginManager: launchAtLoginManager,
            updateChecker: updateChecker
        )

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = viewController
        super.init()
        popover.delegate = self
    }

    deinit {
        removeEventMonitors()
    }

    var isShown: Bool {
        popover.isShown
    }

    func toggle(relativeTo button: NSStatusBarButton, requestPermissions: Bool = false) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show(relativeTo: button, requestPermissions: requestPermissions)
        }
    }

    func show(relativeTo button: NSStatusBarButton, requestPermissions: Bool = false) {
        anchorButton = button
        viewController.refreshForPresentation()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installEventMonitors()

        guard requestPermissions else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.viewController.requestMissingPermissions()
        }
    }

    func close() {
        popover.performClose(nil)
        removeEventMonitors()
        anchorButton = nil
    }

    func popoverDidClose(_ notification: Notification) {
        removeEventMonitors()
        anchorButton = nil
    }

    private func installEventMonitors() {
        removeEventMonitors()

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }

            if self.popover.isShown, !self.shouldKeepPopoverOpen(for: event) {
                self.close()
            }

            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            DispatchQueue.main.async {
                self?.close()
            }
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func shouldKeepPopoverOpen(for event: NSEvent) -> Bool {
        if let popoverWindow = viewController.view.window, event.window === popoverWindow {
            return true
        }

        guard let button = anchorButton, event.window === button.window else {
            return false
        }

        let pointInButton = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(pointInButton)
    }
}

private final class SettingsViewController: NSViewController {
    private let settings: AppSettings
    private let permissionsManager: PermissionsManager
    private let launchAtLoginManager: LaunchAtLoginManager
    private let updateChecker: UpdateChecker
    private let githubURL = AppBranding.repositoryURL

    private let hoverDelaySlider = NSSlider(value: 0.10, minValue: 0.05, maxValue: 0.8, target: nil, action: nil)
    private let hoverDelayValuePill = SettingsPill(text: "100 ms", tone: .accent)
    private let thumbnailSlider = NSSlider(value: 165, minValue: 100, maxValue: 260, target: nil, action: nil)
    private let thumbnailValuePill = SettingsPill(text: "165 px", tone: .neutral)
    private let launchAtLoginStatusPill = SettingsPill(text: "未开启", tone: .neutral)
    private let updateStatusPill = SettingsPill(text: "", tone: .neutral)
    private let accessibilityStatusPill = SettingsPill(text: "检测中", tone: .neutral)
    private let screenCaptureStatusPill = SettingsPill(text: "检测中", tone: .neutral)
    private let optionTabShortcutPill = SettingsPill(text: "⌥ Tab", tone: .accent)

    private lazy var showTitleSwitch = makeSwitch(action: #selector(showTitleChanged(_:)))
    private lazy var launchAtLoginSwitch = makeSwitch(action: #selector(launchAtLoginChanged(_:)))
    private lazy var debugSwitch = makeSwitch(action: #selector(debugChanged(_:)))
    private lazy var openLoginItemsButton = makeButton(title: "登录项", symbolName: "person.crop.circle.badge.checkmark", action: #selector(openLoginItemsSettings))
    private lazy var checkUpdatesButton = makeButton(title: "检查更新", symbolName: "arrow.triangle.2.circlepath", action: #selector(checkForUpdatesClicked))
    private lazy var githubButton = makeButton(title: "GitHub", symbolName: "chevron.left.forwardslash.chevron.right", action: #selector(openGitHub))
    private lazy var requestAccessibilityButton = makeButton(title: "请求", symbolName: "hand.raised", action: #selector(requestAccessibilityPermission))
    private lazy var openAccessibilityButton = makeButton(title: "打开", symbolName: "gearshape", action: #selector(openAccessibilitySettings))
    private lazy var requestScreenCaptureButton = makeButton(title: "请求", symbolName: "rectangle.on.rectangle", action: #selector(requestScreenCapturePermission))
    private lazy var openScreenCaptureButton = makeButton(title: "打开", symbolName: "gearshape", action: #selector(openScreenCaptureSettings))
    private lazy var requestAllButton = makeButton(title: "请求缺失权限", symbolName: "lock.open", action: #selector(requestAllPermissions))
    private lazy var recheckButton = makeButton(title: "重新检测", symbolName: "checkmark.shield", action: #selector(recheckPermissions))

    private var permissionRefreshTimer: Timer?

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
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: SettingsUI.panelWidth, height: SettingsUI.panelHeight)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        permissionRefreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let rootView = SettingsUI.rootView()
        view = rootView

        buildUI(in: rootView)
        refreshValues()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startPermissionRefreshTimer()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recheckPermissions),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    func refreshForPresentation() {
        guard isViewLoaded else { return }
        refreshValues()
    }

    private func buildUI(in rootView: NSView) {
        hoverDelaySlider.target = self
        hoverDelaySlider.action = #selector(hoverDelayChanged(_:))
        thumbnailSlider.target = self
        thumbnailSlider.action = #selector(thumbnailSizeChanged(_:))
        updateStatusPill.setText("v\(updateChecker.currentVersion)", tone: .neutral)

        let scrollView = SettingsUI.scrollView()
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        let stack = SettingsUI.contentStack()

        documentView.addSubview(stack)
        scrollView.documentView = documentView
        rootView.addSubview(scrollView)

        stack.addArrangedSubview(headerView())
        stack.addArrangedSubview(previewCard())
        stack.addArrangedSubview(systemCard())
        stack.addArrangedSubview(permissionsCard())
        stack.addArrangedSubview(aboutCard())

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
    }

    private func headerView() -> NSView {
        SettingsHeaderView(
            icon: AppIconFactory.appIcon(size: 52),
            title: AppBranding.displayName,
            subtitle: "Dock 多窗口预览 · v\(updateChecker.currentVersion)"
        )
    }

    private func previewCard() -> NSView {
        let card = SettingsCardView(title: "预览", symbolName: "rectangle.3.group")
        card.stack.addArrangedSubview(sliderRow(title: "悬停延迟", slider: hoverDelaySlider, valueLabel: hoverDelayValuePill))
        card.stack.addArrangedSubview(sliderRow(title: "缩略图高度", slider: thumbnailSlider, valueLabel: thumbnailValuePill))
        card.stack.addArrangedSubview(SettingsUI.divider())
        card.stack.addArrangedSubview(switchRow(title: "显示窗口标题", trailingView: showTitleSwitch))
        card.stack.addArrangedSubview(switchRow(title: "启用调试日志", trailingView: debugSwitch))
        return card
    }

    private func systemCard() -> NSView {
        let card = SettingsCardView(title: "系统", symbolName: "power")
        card.stack.addArrangedSubview(statusSwitchActionRow(
            title: "开机启动",
            statusPill: launchAtLoginStatusPill,
            switchControl: launchAtLoginSwitch,
            actionButton: openLoginItemsButton
        ))
        card.stack.addArrangedSubview(SettingsUI.divider())
        card.stack.addArrangedSubview(statusRow(title: "窗口切换", statusPill: nil, trailingView: optionTabShortcutPill))
        return card
    }

    private func permissionsCard() -> NSView {
        let card = SettingsCardView(title: "权限", symbolName: "lock.shield")
        card.stack.addArrangedSubview(permissionRow(
            title: "辅助功能",
            statusPill: accessibilityStatusPill,
            requestButton: requestAccessibilityButton,
            openButton: openAccessibilityButton
        ))
        card.stack.addArrangedSubview(permissionRow(
            title: "屏幕录制",
            statusPill: screenCaptureStatusPill,
            requestButton: requestScreenCaptureButton,
            openButton: openScreenCaptureButton
        ))
        card.stack.addArrangedSubview(actionRow(primary: requestAllButton, secondary: recheckButton))
        return card
    }

    private func aboutCard() -> NSView {
        let card = SettingsCardView(title: "关于", symbolName: "info.circle")
        card.stack.addArrangedSubview(statusRow(title: "当前版本", statusPill: updateStatusPill, trailingView: checkUpdatesButton))
        card.stack.addArrangedSubview(statusRow(title: "项目主页", statusPill: nil, trailingView: githubButton))
        return card
    }

    private func sliderRow(title: String, slider: NSSlider, valueLabel: SettingsPill) -> NSView {
        let label = SettingsUI.rowTitle(title)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let topRow = NSStackView(views: [label, SettingsUI.spacer(), valueLabel])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY

        slider.controlSize = .small

        let stack = NSStackView(views: [topRow, slider])
        stack.orientation = .vertical
        stack.spacing = 4
        return stack
    }

    private func switchRow(title: String, trailingView: NSView) -> NSView {
        statusRow(title: title, statusPill: nil, trailingView: trailingView)
    }

    private func statusSwitchRow(title: String, statusPill: SettingsPill, switchControl: NSSwitch) -> NSView {
        let trailing = NSStackView(views: [statusPill, switchControl])
        trailing.orientation = .horizontal
        trailing.spacing = 8
        trailing.alignment = .centerY
        return statusRow(title: title, statusPill: nil, trailingView: trailing)
    }

    private func statusSwitchActionRow(
        title: String,
        statusPill: SettingsPill,
        switchControl: NSSwitch,
        actionButton: NSButton
    ) -> NSView {
        let trailing = NSStackView(views: [statusPill, switchControl, actionButton])
        trailing.orientation = .horizontal
        trailing.spacing = 8
        trailing.alignment = .centerY
        return statusRow(title: title, statusPill: nil, trailingView: trailing)
    }

    private func statusRow(title: String, statusPill: SettingsPill?, trailingView: NSView) -> NSView {
        let titleLabel = SettingsUI.rowTitle(title)
        let views = statusPill.map { [titleLabel, SettingsUI.spacer(), $0, trailingView] } ?? [titleLabel, SettingsUI.spacer(), trailingView]
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = SettingsUI.rowSpacing
        row.alignment = .centerY
        return row
    }

    private func permissionRow(
        title: String,
        statusPill: SettingsPill,
        requestButton: NSButton,
        openButton: NSButton
    ) -> NSView {
        requestButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true

        let actions = NSStackView(views: [requestButton, openButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.alignment = .centerY
        return statusRow(title: title, statusPill: statusPill, trailingView: actions)
    }

    private func actionRow(primary: NSButton, secondary: NSButton? = nil) -> NSView {
        let actions = secondary.map { [primary, $0] } ?? [primary]
        let row = NSStackView(views: [SettingsUI.spacer()] + actions)
        row.orientation = .horizontal
        row.spacing = 7
        row.alignment = .centerY
        return row
    }

    private func makeSwitch(action: Selector) -> NSSwitch {
        SettingsUI.makeSwitch(target: self, action: action)
    }

    private func makeButton(title: String, symbolName: String, action: Selector) -> NSButton {
        SettingsUI.makeButton(title: title, symbolName: symbolName, target: self, action: action)
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
        let accessibilityTrusted = permissionsManager.isAccessibilityTrusted()
        accessibilityStatusPill.setText(accessibilityTrusted ? "已开启" : "未开启", tone: accessibilityTrusted ? .success : .warning)
        requestAccessibilityButton.isEnabled = !accessibilityTrusted

        let screenCaptureTrusted = permissionsManager.isScreenCaptureTrusted()
        screenCaptureStatusPill.setText(screenCaptureTrusted ? "已开启" : "未开启", tone: screenCaptureTrusted ? .success : .warning)
        requestScreenCaptureButton.isEnabled = !screenCaptureTrusted
        requestAllButton.isEnabled = !accessibilityTrusted || !screenCaptureTrusted
    }

    private func startPermissionRefreshTimer() {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatus()
        }
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

    @objc private func openScreenCaptureSettings() {
        permissionsManager.openScreenCaptureSettings()
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
        alert.informativeText = "\(release.name)\n\n当前可以打开下载页面获取最新 DMG。"
        alert.addButton(withTitle: "打开下载页面")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn {
            updateChecker.openDownloadOrReleasePage(release)
        }
    }

    private func showUpdateCheckError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "检查更新失败"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
