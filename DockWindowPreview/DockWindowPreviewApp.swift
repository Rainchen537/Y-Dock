import AppKit
import Foundation

final class DockWindowPreviewApp: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: DockWindowPreviewApp?

    private let settings = AppSettings.shared
    private let permissionsManager = PermissionsManager()
    private let windowCollector = WindowCollector()
    private let thumbnailProvider = WindowThumbnailProvider()
    private let windowActivator = WindowActivator()
    private let dockInspector = DockInspector()
    private let updateChecker = UpdateChecker.shared
    private lazy var desktopWindowControlsController =
        DesktopWindowControlsController(settings: settings)

    private struct PreviewContext {
        let appPID: pid_t
        let anchor: NSPoint
        let dockEdge: DockEdge?
    }

    private struct CachedPreviewWindows {
        let windows: [WindowInfo]
        let createdAt: TimeInterval
    }

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsWindowController: SettingsWindowController?
    private var previewContext: PreviewContext?
    private var previewWindowCache: [pid_t: CachedPreviewWindows] = [:]
    private let previewWindowCacheTTL: TimeInterval = 1.6
    private let previewPrewarmDelay: TimeInterval = 0.030
    private let maximumPrewarmedWindows = 6
    private let previewPrewarmQueue = DispatchQueue(label: "com.ydock.preview-prewarm", qos: .utility)
    private var previewPrewarmWorkItem: DispatchWorkItem?
    private var previewPrewarmIdentity: String?
    private var isDockContextMenuProtectionActive = false
    private var dockContextMenuProtectionStartedAt: TimeInterval?
    private var dockContextMenuProtectionWorkItem: DispatchWorkItem?
    private var dockPrimaryClickWorkItem: DispatchWorkItem?
    private let dockContextMenuMinimumProtectionDuration: TimeInterval = 0.65
    private let dockPrimaryClickResponseDelay: TimeInterval = 0.065

    private lazy var previewPanel: PreviewPanel = {
        let panel = PreviewPanel(thumbnailProvider: thumbnailProvider, settings: settings)
        panel.onSelectWindow = { [weak self] window in
            self?.windowActivator.activate(window)
            self?.previewPanel.hide()
            self?.previewContext = nil
        }
        panel.onCloseWindow = { [weak self] window in
            self?.closeWindowFromPreview(window)
        }
        panel.onMinimizeWindow = { [weak self] window in
            self?.minimizeWindowFromPreview(window)
        }
        panel.onQuitApplication = { [weak self] window in
            self?.quitApplicationFromPreview(window)
        }
        return panel
    }()

    private lazy var mouseTracker: MouseTracker = {
        let tracker = MouseTracker(
            dockInspector: dockInspector,
            windowCollector: windowCollector,
            settings: settings
        )
        tracker.isPointInsidePreviewPanel = { [weak self] point in
            self?.previewPanel.containsScreenPoint(point) ?? false
        }
        tracker.onHoverResolved = { [weak self] item, point in
            self?.showPreview(for: item, anchor: point)
        }
        tracker.onDockHoverCandidateChanged = { [weak self] item, hadPreviousHoverIdentity in
            if hadPreviousHoverIdentity {
                self?.previewPanel.hide()
                self?.previewContext = nil
            }
            self?.schedulePreviewPrewarm(for: item)
        }
        tracker.onMouseLeftDockAndPreview = { [weak self] in
            self?.cancelPreviewPrewarm()
            self?.previewPanel.hide()
            self?.previewContext = nil
        }
        tracker.onDockContextMenuTrackingBegan = { [weak self] point in
            self?.beginDockContextMenuProtection(at: point)
        }
        tracker.onDockContextMenuInteractionEnded = { [weak self] in
            self?.endDockContextMenuProtectionAfterMenuCloses()
        }
        tracker.onDockPrimaryClick = { [weak self] item, context in
            self?.handleDockPrimaryClick(item, context: context)
        }
        return tracker
    }()

    private lazy var optionTabSwitcher = OptionTabSwitcher(
        windowCollector: windowCollector,
        thumbnailProvider: thumbnailProvider,
        windowActivator: windowActivator,
        settings: settings
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.retainedDelegate = self
        NSApp.setActivationPolicy(.accessory)
        setupDockIcon()
        setupApplicationMenu()
        setupStatusItem()
        observeApplicationLifecycle()
        let isShowingStartupMenu = showRequestedStartupUIIfNeeded()
        let isSettingsPreview = ProcessInfo.processInfo.environment["Y_SETTINGS_PREVIEW"] == "1"
        if !isShowingStartupMenu && !isSettingsPreview {
            permissionsManager.showInitialPermissionGuidanceIfNeeded()
        }
        mouseTracker.start()
        optionTabSwitcher.start()
        desktopWindowControlsController.start()
        scheduleStartupUpdateCheck()
        showSettingsForPreviewIfRequested()
        DWLog("\(AppBranding.displayName) launched")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissionsManager.showMissingPermissionGuidance()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelPreviewPrewarm()
        cancelDockContextMenuProtectionTimer()
        dockPrimaryClickWorkItem?.cancel()
        dockPrimaryClickWorkItem = nil
        desktopWindowControlsController.stop()
        optionTabSwitcher.stop()
        mouseTracker.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }

    private func setupDockIcon() {
        NSApp.applicationIconImage = AppIconFactory.appIcon()
    }

    private func setupApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        appMenu.addItem(menuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ","))
        appMenu.addItem(menuItem(title: "请求隐私权限", action: #selector(requestPrivacyPermissions)))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(menuItem(title: "退出 \(AppBranding.displayName)", action: #selector(quit), keyEquivalent: "q"))

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.title = ""
            button.image = AppIconFactory.statusBarIcon()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = AppBranding.displayName
        }

        statusMenu = makeStatusMenu()
        item.menu = statusMenu
        statusItem = item
    }

    private func makeStatusMenu() -> NSMenu {
        YProjectStatusMenu.make(
            target: self,
            openSettingsAction: #selector(openSettings),
            quitAction: #selector(quit),
            appName: AppBranding.displayName
        )
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @discardableResult
    private func showRequestedStartupUIIfNeeded() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        NSLog("[\(AppBranding.displayName)] launch arguments: %@", arguments.joined(separator: " "))
        guard arguments.contains("--show-status-menu") else { return false }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            NSLog("[\(AppBranding.displayName)] showing settings window")
            self?.showSettingsWindow()
        }
        return true
    }

    private func showPreview(for dockItem: DockItem, anchor: NSPoint) {
        cancelPreviewPrewarm()
        guard let app = dockItem.runningApplication else {
            DWLog("Dock item '\(dockItem.title)' has no running app")
            previewPanel.hide()
            previewContext = nil
            return
        }

        let windows = previewWindows(for: app)
        guard !windows.isEmpty else {
            DWLog("No visible windows for \(app.localizedName ?? dockItem.title)")
            previewPanel.hide()
            previewContext = nil
            return
        }

        guard !isDockContextMenuProtectionActive else {
            return
        }

        previewContext = PreviewContext(appPID: app.processIdentifier, anchor: anchor, dockEdge: dockItem.dockEdge)
        previewPanel.show(windows: windows, app: app, anchor: anchor, dockEdge: dockItem.dockEdge)
    }

    private func handleDockPrimaryClick(
        _ dockItem: DockItem,
        context: DockPrimaryClickContext
    ) {
        guard
            context.targetWasFrontmostBeforeClick,
            context.targetOwnedTopmostUserWindowBeforeClick,
            settings.dockClickMinimizeMode != .off,
            let app = dockItem.runningApplication
        else {
            return
        }

        dockPrimaryClickWorkItem?.cancel()
        let pid = app.processIdentifier
        let workItem = DispatchWorkItem { [weak self] in
            guard
                let self,
                let runningApp = NSRunningApplication(
                    processIdentifier: pid
                ),
                !runningApp.isTerminated
            else {
                return
            }

            self.dockPrimaryClickWorkItem = nil
            let windows = self.windowCollector.windows(for: runningApp)
            guard DockClickMinimizePolicy.shouldMinimize(
                mode: self.settings.dockClickMinimizeMode,
                totalWindowCount: windows.count
            ) else {
                return
            }

            let minimizedCount = self.windowActivator.minimize(
                windows.filter { !$0.isMinimized }
            )
            guard minimizedCount > 0 else { return }

            self.invalidatePreviewCaches(ownerPID: pid)
            self.previewPanel.hide()
            self.previewContext = nil
        }
        dockPrimaryClickWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + dockPrimaryClickResponseDelay,
            execute: workItem
        )
    }

    private func beginDockContextMenuProtection(at point: NSPoint) {
        isDockContextMenuProtectionActive = true
        dockContextMenuProtectionStartedAt = Date.timeIntervalSinceReferenceDate
        cancelDockContextMenuProtectionTimer()
        cancelPreviewPrewarm()
        previewPanel.hide()
        previewContext = nil
    }

    private func endDockContextMenuProtectionAfterMenuCloses() {
        guard isDockContextMenuProtectionActive else { return }

        let elapsed = Date.timeIntervalSinceReferenceDate - (dockContextMenuProtectionStartedAt ?? 0)
        let delay = max(0.08, dockContextMenuMinimumProtectionDuration - elapsed)
        cancelDockContextMenuProtectionTimer()

        let workItem = DispatchWorkItem { [weak self] in
            self?.endDockContextMenuProtection()
        }
        dockContextMenuProtectionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func endDockContextMenuProtection() {
        guard isDockContextMenuProtectionActive else { return }

        cancelDockContextMenuProtectionTimer()
        isDockContextMenuProtectionActive = false
        dockContextMenuProtectionStartedAt = nil
        mouseTracker.refreshCurrentHover()
    }

    private func cancelDockContextMenuProtectionTimer() {
        dockContextMenuProtectionWorkItem?.cancel()
        dockContextMenuProtectionWorkItem = nil
    }

    private func schedulePreviewPrewarm(for dockItem: DockItem) {
        cancelPreviewPrewarm()

        guard dockItem.runningApplication != nil else { return }

        let identity = dockItem.identity
        previewPrewarmIdentity = identity

        let workItem = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.previewPrewarmIdentity == identity
            else {
                return
            }

            self.previewPrewarmWorkItem = nil
            self.prewarmPreview(for: dockItem)
        }

        previewPrewarmWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + previewPrewarmDelay, execute: workItem)
    }

    private func cancelPreviewPrewarm() {
        previewPrewarmWorkItem?.cancel()
        previewPrewarmWorkItem = nil
        previewPrewarmIdentity = nil
    }

    private func prewarmPreview(for dockItem: DockItem) {
        guard let app = dockItem.runningApplication else { return }

        let windows = previewWindows(for: app)
        guard !windows.isEmpty else { return }

        let windowsToWarm = Array(windows.prefix(maximumPrewarmedWindows))
        previewPrewarmQueue.async { [thumbnailProvider, settings] in
            thumbnailProvider.warmThumbnails(
                for: windowsToWarm,
                settings: settings
            )
        }
    }

    private func closeWindowFromPreview(_ window: WindowInfo) {
        invalidatePreviewCaches(ownerPID: window.ownerPID)
        guard windowActivator.close(window) else {
            NSSound.beep()
            return
        }

        previewPanel.removeWindow(window.windowID)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.refreshPreviewAfterClosingWindow(pid: window.ownerPID)
        }
    }

    private func minimizeWindowFromPreview(_ window: WindowInfo) {
        invalidatePreviewCaches(ownerPID: window.ownerPID)
        guard windowActivator.minimize(window) else {
            NSSound.beep()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.refreshPreviewAfterClosingWindow(pid: window.ownerPID)
        }
    }

    private func quitApplicationFromPreview(_ window: WindowInfo) {
        invalidatePreviewCaches(ownerPID: window.ownerPID)
        guard windowActivator.quitApplication(ownerPID: window.ownerPID) else {
            NSSound.beep()
            return
        }

        previewPanel.hide()
        previewContext = nil
    }

    private func refreshPreviewAfterClosingWindow(pid: pid_t) {
        invalidatePreviewCaches(ownerPID: pid)
        guard
            let context = previewContext,
            context.appPID == pid,
            let app = NSRunningApplication(processIdentifier: pid)
        else {
            previewPanel.hide()
            previewContext = nil
            return
        }

        let windows = windowCollector.windows(for: app)
        guard !windows.isEmpty else {
            previewPanel.hide()
            previewContext = nil
            return
        }

        previewPanel.show(windows: windows, app: app, anchor: context.anchor, dockEdge: context.dockEdge)
    }

    private func previewWindows(for app: NSRunningApplication) -> [WindowInfo] {
        let pid = app.processIdentifier
        let now = Date.timeIntervalSinceReferenceDate

        if let cached = previewWindowCache[pid], now - cached.createdAt <= previewWindowCacheTTL {
            return cached.windows
        }

        let windows = windowCollector.windows(for: app)
        previewWindowCache[pid] = CachedPreviewWindows(windows: windows, createdAt: now)
        return windows
    }

    private func invalidatePreviewCaches(ownerPID: pid_t) {
        previewWindowCache.removeValue(forKey: ownerPID)
        thumbnailProvider.invalidatePreviewCache(ownerPID: ownerPID)
    }

    private func observeApplicationLifecycle() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(runningApplicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc private func runningApplicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        invalidatePreviewCaches(ownerPID: app.processIdentifier)
    }

    @objc private func openSettings() {
        openSettingsWindow()
    }

    private func openSettingsWindow() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settings: settings,
                permissionsManager: permissionsManager,
                updateChecker: updateChecker
            )
        }
        settingsWindowController?.show()
    }

    private func showSettingsForPreviewIfRequested() {
        guard ProcessInfo.processInfo.environment["Y_SETTINGS_PREVIEW"] == "1" else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showSettingsWindow()
            if let identifier = ProcessInfo.processInfo.environment["Y_SETTINGS_PREVIEW_SECTION"] {
                self?.settingsWindowController?.selectItem(identifier)
            }
        }
    }

    private func scheduleStartupUpdateCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.checkForUpdatesOnLaunch()
        }
    }

    private func checkForUpdatesOnLaunch() {
        updateChecker.checkForUpdates { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .updateAvailable(_, let latest):
                    self?.showStartupUpdateAlert(latest)
                case .upToDate(let currentVersion, _):
                    DWLog("Update check: current version \(currentVersion) is up to date")
                case .failure(let error):
                    DWLog("Startup update check failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showStartupUpdateAlert(_ release: UpdateChecker.ReleaseInfo) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(AppBranding.displayName) 有新版本 \(release.displayVersion)"

        guard release.downloadURL != nil else {
            alert.informativeText = "\(release.name)\n\n未找到当前架构所需的 \(release.expectedAssetName)。为避免安装错误架构，Y-Dock 不会改用其他 DMG。请打开 Release 页面手动确认。"
            alert.addButton(withTitle: "打开 Release 页面")
            alert.addButton(withTitle: "稍后")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                updateChecker.openReleasePage(release)
            }
            return
        }

        alert.informativeText = "\(release.name)\n\n可以直接下载、安装并重启。"
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "打开页面")
        alert.addButton(withTitle: "稍后")

        NSApp.activate(ignoringOtherApps: true)
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
        updateChecker.downloadAndInstall(release) { status in
            DWLog("Update install status: \(status.displayText)")
        } completion: { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    self?.showUpdateInstallError(error)
                }
            }
        }
    }

    private func showUpdateInstallError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "自动更新失败"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc private func openAccessibilitySettings() {
        permissionsManager.openAccessibilitySettings()
    }

    @objc private func openScreenCaptureSettings() {
        permissionsManager.openScreenCaptureSettings()
    }

    @objc private func requestPrivacyPermissions() {
        _ = permissionsManager.requestMissingPrivacyPermissions()
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(AppBranding.repositoryURL)
    }

    @objc private func requestScreenCapturePermission() {
        switch permissionsManager.requestScreenCapturePermission() {
        case .active:
            DWLog("Screen capture permission is active")
        case .restartRequired:
            DWLog("Screen capture permission was granted and requires restart")
        case .missing:
            permissionsManager.openScreenCaptureSettings()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
