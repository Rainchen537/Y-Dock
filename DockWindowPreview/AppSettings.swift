import AppKit
import Foundation

enum AppBranding {
    static let displayName = "Y-Dock"
    static let repositoryName = "Y-Dock"
    static let repositoryURL = URL(string: "https://github.com/Rainchen537/Y-Dock")!
}

enum DockClickMinimizeMode: String, CaseIterable {
    case off
    case onlySingleWindow
    case allWindows

    var displayName: String {
        switch self {
        case .off:
            return "关闭"
        case .onlySingleWindow:
            return "仅单窗口 App"
        case .allWindows:
            return "所有窗口"
        }
    }
}

enum PreviewCloseQuitMode: String, CaseIterable {
    case all
    case blacklist
    case whitelist

    var displayName: String {
        switch self {
        case .all:
            return "全部 App"
        case .blacklist:
            return "黑名单"
        case .whitelist:
            return "白名单"
        }
    }
}

enum PreviewCloseAction: Equatable {
    case closeWindow
    case quitApplication
}

struct DockClickWindowStackEntry {
    let ownerPID: pid_t
    let layer: Int
    let isOnscreen: Bool
    let alpha: Double
    let bounds: CGRect
    let isRegularApplication: Bool
    let isExcludedOwner: Bool
    let isLikelyUserWindow: Bool
}

enum DockClickMinimizePolicy {
    static func shouldMinimize(mode: DockClickMinimizeMode, totalWindowCount: Int) -> Bool {
        switch mode {
        case .off:
            return false
        case .onlySingleWindow:
            return totalWindowCount == 1
        case .allWindows:
            return totalWindowCount > 0
        }
    }

    static func targetWasFrontmostBeforeClick(
        targetPID: pid_t,
        observedFrontmostPID: pid_t?,
        trackedFrontmostPID: pid_t?,
        previousTrackedFrontmostPID: pid_t?,
        frontmostPIDAtLastPointerMove: pid_t?,
        frontmostChangedAt: TimeInterval,
        lastPointerMoveAt: TimeInterval
    ) -> Bool {
        let targetWasActivatedAfterLastPointerMove = trackedFrontmostPID == targetPID
            && previousTrackedFrontmostPID != targetPID
            && frontmostChangedAt > lastPointerMoveAt

        return observedFrontmostPID == targetPID
            && trackedFrontmostPID == targetPID
            && frontmostPIDAtLastPointerMove == targetPID
            && !targetWasActivatedAfterLastPointerMove
    }

    static func isEligibleTopmostUserWindow(
        _ entry: DockClickWindowStackEntry
    ) -> Bool {
        entry.layer == 0
            && entry.isOnscreen
            && entry.alpha.isFinite
            && entry.alpha > 0.01
            && entry.bounds.width.isFinite
            && entry.bounds.height.isFinite
            && entry.bounds.width >= 40
            && entry.bounds.height >= 40
            && entry.isRegularApplication
            && !entry.isExcludedOwner
            && entry.isLikelyUserWindow
    }

    static func topmostUserWindowOwnerPID(
        in entries: [DockClickWindowStackEntry]
    ) -> pid_t? {
        entries.first(where: isEligibleTopmostUserWindow)?.ownerPID
    }

    static func targetOwnedTopmostUserWindowBeforeClick(
        targetPID: pid_t,
        observedTopmostUserWindowOwnerPID: pid_t?,
        topmostUserWindowOwnerPIDAtLastPointerMove: pid_t?
    ) -> Bool {
        observedTopmostUserWindowOwnerPID == targetPID
            && topmostUserWindowOwnerPIDAtLastPointerMove == targetPID
    }
}

enum PreviewCloseActionPolicy {
    static func action(
        isEnabled: Bool,
        mode: PreviewCloseQuitMode,
        bundleIdentifier: String?,
        hasRunningApplication: Bool,
        blacklist: Set<String>,
        whitelist: Set<String>
    ) -> PreviewCloseAction {
        guard isEnabled, hasRunningApplication else {
            return .closeWindow
        }

        switch mode {
        case .all:
            return .quitApplication
        case .blacklist:
            guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
                return .closeWindow
            }
            return blacklist.contains(bundleIdentifier) ? .closeWindow : .quitApplication
        case .whitelist:
            guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
                return .closeWindow
            }
            return whitelist.contains(bundleIdentifier) ? .quitApplication : .closeWindow
        }
    }
}

extension Notification.Name {
    static let appSettingsChanged = Notification.Name("DockWindowPreview.appSettingsChanged")
}

final class AppSettings {
    static let shared = AppSettings()

    private enum Keys {
        static let hoverDelay = "hoverDelay"
        static let thumbnailHeight = "thumbnailHeight"
        static let showWindowTitles = "showWindowTitles"
        static let launchAtLogin = "launchAtLogin"
        static let debugLoggingEnabled = "debugLoggingEnabled"
        static let dockClickMinimizeMode = "dockClickMinimizeMode"
        static let previewControlHoverEnlargementEnabled = "previewControlHoverEnlargementEnabled"
        static let previewControlHoverTargetSize = "previewControlHoverTargetSize"
        static let previewControlsRevealOnControlAreaOnly = "previewControlsRevealOnControlAreaOnly"
        static let previewCloseQuitsApplicationEnabled = "previewCloseQuitsApplicationEnabled"
        static let previewCloseQuitMode = "previewCloseQuitMode"
        static let previewCloseQuitBlacklist = "previewCloseQuitBlacklist"
        static let previewCloseQuitWhitelist = "previewCloseQuitWhitelist"
        static let defaultsRevision = "defaultsRevision"
    }

    static let minimumPreviewControlSize: CGFloat = 16.5
    static let maximumPreviewControlSize: CGFloat = 30
    static let defaultPreviewControlHoverTargetSize: CGFloat = 23

    private let currentDefaultsRevision = 1
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    var hoverDelay: TimeInterval {
        get { clamped(defaults.double(forKey: Keys.hoverDelay), min: 0.05, max: 0.8) }
        set { set(newValue, forKey: Keys.hoverDelay) }
    }

    var thumbnailHeight: CGFloat {
        get { CGFloat(clamped(defaults.double(forKey: Keys.thumbnailHeight), min: 100, max: 260)) }
        set { set(Double(newValue), forKey: Keys.thumbnailHeight) }
    }

    var thumbnailSize: NSSize {
        NSSize(width: thumbnailHeight * 1.6, height: thumbnailHeight)
    }

    func thumbnailSize(for window: WindowInfo) -> NSSize {
        let height = thumbnailHeight
        let aspectRatio = window.bounds.height > 0 ? window.bounds.width / window.bounds.height : 1.6
        let width = clamped(Double(height * aspectRatio), min: 120, max: 460)
        return NSSize(width: CGFloat(width), height: height)
    }

    var showWindowTitles: Bool {
        get { defaults.bool(forKey: Keys.showWindowTitles) }
        set { set(newValue, forKey: Keys.showWindowTitles) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { set(newValue, forKey: Keys.launchAtLogin) }
    }

    var debugLoggingEnabled: Bool {
        get { defaults.bool(forKey: Keys.debugLoggingEnabled) }
        set { set(newValue, forKey: Keys.debugLoggingEnabled) }
    }

    var dockClickMinimizeMode: DockClickMinimizeMode {
        get {
            guard
                let rawValue = defaults.string(forKey: Keys.dockClickMinimizeMode),
                let mode = DockClickMinimizeMode(rawValue: rawValue)
            else {
                return .off
            }
            return mode
        }
        set { set(newValue.rawValue, forKey: Keys.dockClickMinimizeMode) }
    }

    var previewControlHoverEnlargementEnabled: Bool {
        get { defaults.bool(forKey: Keys.previewControlHoverEnlargementEnabled) }
        set { set(newValue, forKey: Keys.previewControlHoverEnlargementEnabled) }
    }

    var previewControlHoverTargetSize: CGFloat {
        get {
            CGFloat(clamped(
                defaults.double(forKey: Keys.previewControlHoverTargetSize),
                min: Double(Self.minimumPreviewControlSize),
                max: Double(Self.maximumPreviewControlSize),
                fallback: Double(Self.defaultPreviewControlHoverTargetSize)
            ))
        }
        set {
            let value = clamped(
                Double(newValue),
                min: Double(Self.minimumPreviewControlSize),
                max: Double(Self.maximumPreviewControlSize),
                fallback: Double(Self.defaultPreviewControlHoverTargetSize)
            )
            set(value, forKey: Keys.previewControlHoverTargetSize)
        }
    }

    var previewControlsRevealOnControlAreaOnly: Bool {
        get { defaults.bool(forKey: Keys.previewControlsRevealOnControlAreaOnly) }
        set { set(newValue, forKey: Keys.previewControlsRevealOnControlAreaOnly) }
    }

    var previewCloseQuitsApplicationEnabled: Bool {
        get { defaults.bool(forKey: Keys.previewCloseQuitsApplicationEnabled) }
        set { set(newValue, forKey: Keys.previewCloseQuitsApplicationEnabled) }
    }

    var previewCloseQuitMode: PreviewCloseQuitMode {
        get {
            guard
                let rawValue = defaults.string(forKey: Keys.previewCloseQuitMode),
                let mode = PreviewCloseQuitMode(rawValue: rawValue)
            else {
                return .all
            }
            return mode
        }
        set { set(newValue.rawValue, forKey: Keys.previewCloseQuitMode) }
    }

    var previewCloseQuitBlacklist: Set<String> {
        get { bundleIdentifiers(forKey: Keys.previewCloseQuitBlacklist) }
        set { setBundleIdentifiers(newValue, forKey: Keys.previewCloseQuitBlacklist) }
    }

    var previewCloseQuitWhitelist: Set<String> {
        get { bundleIdentifiers(forKey: Keys.previewCloseQuitWhitelist) }
        set { setBundleIdentifiers(newValue, forKey: Keys.previewCloseQuitWhitelist) }
    }

    func previewCloseAction(bundleIdentifier: String?, hasRunningApplication: Bool) -> PreviewCloseAction {
        PreviewCloseActionPolicy.action(
            isEnabled: previewCloseQuitsApplicationEnabled,
            mode: previewCloseQuitMode,
            bundleIdentifier: bundleIdentifier,
            hasRunningApplication: hasRunningApplication,
            blacklist: previewCloseQuitBlacklist,
            whitelist: previewCloseQuitWhitelist
        )
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.hoverDelay: 0.10,
            Keys.thumbnailHeight: 165.0,
            Keys.showWindowTitles: true,
            Keys.launchAtLogin: false,
            Keys.debugLoggingEnabled: false,
            Keys.dockClickMinimizeMode: DockClickMinimizeMode.off.rawValue,
            Keys.previewControlHoverEnlargementEnabled: false,
            Keys.previewControlHoverTargetSize: Double(Self.defaultPreviewControlHoverTargetSize),
            Keys.previewControlsRevealOnControlAreaOnly: false,
            Keys.previewCloseQuitsApplicationEnabled: false,
            Keys.previewCloseQuitMode: PreviewCloseQuitMode.all.rawValue,
            Keys.previewCloseQuitBlacklist: [String](),
            Keys.previewCloseQuitWhitelist: [String](),
            Keys.defaultsRevision: 0
        ])
        migrateDefaultsIfNeeded()
    }

    private func migrateDefaultsIfNeeded() {
        let revision = defaults.integer(forKey: Keys.defaultsRevision)
        guard revision < currentDefaultsRevision else { return }

        let currentHeight = defaults.double(forKey: Keys.thumbnailHeight)
        if abs(currentHeight - 150.0) < 0.5 {
            defaults.set(165.0, forKey: Keys.thumbnailHeight)
        }

        defaults.set(currentDefaultsRevision, forKey: Keys.defaultsRevision)
    }

    private func bundleIdentifiers(forKey key: String) -> Set<String> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(normalizedBundleIdentifier))
    }

    private func setBundleIdentifiers(_ identifiers: Set<String>, forKey key: String) {
        let normalized = Set(identifiers.compactMap(normalizedBundleIdentifier))
        set(normalized.sorted(), forKey: key)
    }

    private func normalizedBundleIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func set(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .appSettingsChanged, object: self)
    }

    private func clamped(
        _ value: Double,
        min: Double,
        max: Double,
        fallback: Double? = nil
    ) -> Double {
        guard value.isFinite else {
            return fallback ?? min
        }
        return Swift.max(min, Swift.min(max, value))
    }
}

func DWLog(_ message: @autoclosure () -> String) {
    guard AppSettings.shared.debugLoggingEnabled else { return }
    NSLog("[\(AppBranding.displayName)] %@", message())
}
