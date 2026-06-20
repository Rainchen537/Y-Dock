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
    private var settingsPopoverController: SettingsPopoverController?
    private var previewContext: PreviewContext?
    private var previewWindowCache: [pid_t: CachedPreviewWindows] = [:]
    private let previewWindowCacheTTL: TimeInterval = 0.8

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
        let tracker = MouseTracker(dockInspector: dockInspector, settings: settings)
        tracker.isPointInsidePreviewPanel = { [weak self] point in
            self?.previewPanel.containsScreenPoint(point) ?? false
        }
        tracker.onHoverResolved = { [weak self] item, point in
            self?.showPreview(for: item, anchor: point)
        }
        tracker.onMouseLeftDockAndPreview = { [weak self] in
            self?.previewPanel.hide()
            self?.previewContext = nil
        }
        return tracker
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.retainedDelegate = self
        NSApp.setActivationPolicy(.regular)
        setupDockIcon()
        setupApplicationMenu()
        setupStatusItem()
        let isShowingStartupMenu = showRequestedStartupUIIfNeeded()
        if !isShowingStartupMenu {
            permissionsManager.showInitialPermissionGuidanceIfNeeded()
        }
        mouseTracker.start()
        scheduleStartupUpdateCheck()
        DWLog("DockWindowPreview launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        mouseTracker.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsAndRequestPermissions()
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
        appMenu.addItem(menuItem(title: "退出 DockWindowPreview", action: #selector(quit), keyEquivalent: "q"))

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
            button.toolTip = "DockWindowPreview：点击打开设置"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusMenu = makeStatusMenu()
        statusItem = item
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(menuItem(title: "请求隐私权限", action: #selector(requestPrivacyPermissions)))
        menu.addItem(menuItem(title: "打开 Accessibility 权限", action: #selector(openAccessibilitySettings)))
        menu.addItem(menuItem(title: "打开屏幕录制权限", action: #selector(openScreenCaptureSettings)))
        menu.addItem(menuItem(title: "GitHub", action: #selector(openGitHub)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let shouldShowMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true

        if shouldShowMenu {
            showStatusMenu(from: sender)
        } else {
            toggleSettingsPopover(relativeTo: sender, requestPermissions: true)
        }
    }

    @discardableResult
    private func showRequestedStartupUIIfNeeded() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        NSLog("[DockWindowPreview] launch arguments: %@", arguments.joined(separator: " "))
        guard arguments.contains("--show-status-menu") else { return false }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            NSLog("[DockWindowPreview] showing settings popover")
            self?.showSettingsPopover(requestPermissions: false)
        }
        return true
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        settingsPopoverController?.close()
        statusMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    private func showPreview(for dockItem: DockItem, anchor: NSPoint) {
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

        previewContext = PreviewContext(appPID: app.processIdentifier, anchor: anchor, dockEdge: dockItem.dockEdge)
        previewPanel.show(windows: windows, app: app, anchor: anchor, dockEdge: dockItem.dockEdge)
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

    @objc private func openSettings() {
        openSettingsAndRequestPermissions()
    }

    private func openSettingsAndRequestPermissions() {
        showSettingsPopover(requestPermissions: true)
    }

    private func toggleSettingsPopover(relativeTo button: NSStatusBarButton, requestPermissions: Bool) {
        if settingsPopoverController == nil {
            settingsPopoverController = SettingsPopoverController(
                settings: settings,
                permissionsManager: permissionsManager,
                updateChecker: updateChecker
            )
        }
        settingsPopoverController?.toggle(relativeTo: button, requestPermissions: requestPermissions)
    }

    private func showSettingsPopover(requestPermissions: Bool) {
        guard let button = statusItem?.button else { return }
        if settingsPopoverController == nil {
            settingsPopoverController = SettingsPopoverController(
                settings: settings,
                permissionsManager: permissionsManager,
                updateChecker: updateChecker
            )
        }
        settingsPopoverController?.show(relativeTo: button, requestPermissions: requestPermissions)
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
        alert.messageText = "DockWindowPreview 有新版本 \(release.displayVersion)"
        alert.informativeText = "\(release.name)\n\n是否打开下载页面？"
        alert.addButton(withTitle: "打开下载页面")
        alert.addButton(withTitle: "稍后")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            updateChecker.openDownloadOrReleasePage(release)
        }
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
        guard let url = URL(string: "https://github.com/Rainchen537/DockWindowPreview") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func requestScreenCapturePermission() {
        if permissionsManager.requestScreenCapturePermission() {
            DWLog("Screen capture permission is already granted or was granted")
        } else {
            permissionsManager.openScreenCaptureSettings()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
