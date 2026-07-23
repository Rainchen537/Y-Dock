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

enum DesktopCloseQuitMode: String, CaseIterable {
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

enum DesktopCloseAction: Equatable {
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

struct DockClickTopmostSnapshot {
    let ownerPID: pid_t?
    let capturedAt: TimeInterval
}

struct DockClickFrontmostDecision {
    let isAccepted: Bool
    let acceptedStableActivationAfterPointerMove: Bool

    static let rejected = DockClickFrontmostDecision(
        isAccepted: false,
        acceptedStableActivationAfterPointerMove: false
    )
}

enum DockClickMinimizePolicy {
    static let minimumStableFrontmostActivationDuration: TimeInterval = 0.18
    static let maximumPreClickTopmostSnapshotAge: TimeInterval = 0.25

    static func shouldMinimize(
        mode: DockClickMinimizeMode,
        totalWindowCount: Int
    ) -> Bool {
        switch mode {
        case .off:
            return false
        case .onlySingleWindow:
            return totalWindowCount == 1
        case .allWindows:
            return totalWindowCount > 0
        }
    }

    static func frontmostDecision(
        targetPID: pid_t,
        observedFrontmostPID: pid_t?,
        trackedFrontmostPID: pid_t?,
        previousTrackedFrontmostPID: pid_t?,
        frontmostPIDAtLastPointerMove: pid_t?,
        frontmostChangedAt: TimeInterval,
        lastPointerMoveAt: TimeInterval,
        clickAt: TimeInterval,
        minimumStableActivationDuration: TimeInterval =
            minimumStableFrontmostActivationDuration
    ) -> DockClickFrontmostDecision {
        guard
            observedFrontmostPID == targetPID,
            trackedFrontmostPID == targetPID,
            clickAt.isFinite,
            frontmostChangedAt.isFinite,
            frontmostChangedAt <= clickAt
        else {
            return .rejected
        }

        if frontmostPIDAtLastPointerMove == targetPID,
           lastPointerMoveAt.isFinite,
           lastPointerMoveAt > 0,
           lastPointerMoveAt <= clickAt,
           lastPointerMoveAt >= frontmostChangedAt {
            return DockClickFrontmostDecision(
                isAccepted: true,
                acceptedStableActivationAfterPointerMove: false
            )
        }

        guard
            previousTrackedFrontmostPID != targetPID,
            frontmostChangedAt > lastPointerMoveAt,
            clickAt - frontmostChangedAt >= minimumStableActivationDuration
        else {
            return .rejected
        }

        return DockClickFrontmostDecision(
            isAccepted: true,
            acceptedStableActivationAfterPointerMove: true
        )
    }

    static func targetWasFrontmostBeforeClick(
        targetPID: pid_t,
        observedFrontmostPID: pid_t?,
        trackedFrontmostPID: pid_t?,
        previousTrackedFrontmostPID: pid_t?,
        frontmostPIDAtLastPointerMove: pid_t?,
        frontmostChangedAt: TimeInterval,
        lastPointerMoveAt: TimeInterval,
        clickAt: TimeInterval,
        minimumStableActivationDuration: TimeInterval =
            minimumStableFrontmostActivationDuration
    ) -> Bool {
        frontmostDecision(
            targetPID: targetPID,
            observedFrontmostPID: observedFrontmostPID,
            trackedFrontmostPID: trackedFrontmostPID,
            previousTrackedFrontmostPID: previousTrackedFrontmostPID,
            frontmostPIDAtLastPointerMove: frontmostPIDAtLastPointerMove,
            frontmostChangedAt: frontmostChangedAt,
            lastPointerMoveAt: lastPointerMoveAt,
            clickAt: clickAt,
            minimumStableActivationDuration:
                minimumStableActivationDuration
        ).isAccepted
    }

    static func shouldRefreshTopmostSnapshot(
        isEnabled: Bool,
        isInsideSnapshotRegion: Bool,
        wasInsideSnapshotRegion: Bool,
        now: TimeInterval,
        lastSnapshotAt: TimeInterval,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard isEnabled, isInsideSnapshotRegion else { return false }
        return !wasInsideSnapshotRegion
            || now - lastSnapshotAt >= minimumInterval
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

    static func recentTopmostSnapshotOwnerPID(
        targetPID: pid_t,
        snapshots: [DockClickTopmostSnapshot],
        clickAt: TimeInterval,
        capturedNotBefore: TimeInterval? = nil,
        maximumSnapshotAge: TimeInterval =
            maximumPreClickTopmostSnapshotAge
    ) -> pid_t? {
        guard clickAt.isFinite else { return nil }

        let latestSnapshot = snapshots
            .filter { snapshot in
                snapshot.capturedAt.isFinite
                    && snapshot.capturedAt <= clickAt
                    && capturedNotBefore.map {
                        snapshot.capturedAt >= $0
                    } ?? true
            }
            .max { $0.capturedAt < $1.capturedAt }

        guard
            let latestSnapshot,
            clickAt - latestSnapshot.capturedAt <= maximumSnapshotAge,
            latestSnapshot.ownerPID == targetPID
        else {
            return nil
        }
        return targetPID
    }

    static func stableTopmostSnapshotOwnerPID(
        targetPID: pid_t,
        snapshots: [DockClickTopmostSnapshot],
        frontmostChangedAt: TimeInterval,
        clickAt: TimeInterval,
        minimumStableActivationDuration: TimeInterval =
            minimumStableFrontmostActivationDuration,
        maximumSnapshotAge: TimeInterval =
            maximumPreClickTopmostSnapshotAge
    ) -> pid_t? {
        recentTopmostSnapshotOwnerPID(
            targetPID: targetPID,
            snapshots: snapshots,
            clickAt: clickAt,
            capturedNotBefore:
                frontmostChangedAt + minimumStableActivationDuration,
            maximumSnapshotAge: maximumSnapshotAge
        )
    }

    static func targetOwnedTopmostUserWindowBeforeClick(
        targetPID: pid_t,
        observedTopmostUserWindowOwnerPID: pid_t?,
        preClickTopmostUserWindowOwnerPID: pid_t?
    ) -> Bool {
        observedTopmostUserWindowOwnerPID == targetPID
            && preClickTopmostUserWindowOwnerPID == targetPID
    }
}

enum DesktopCloseActionPolicy {
    static func action(
        isEnabled: Bool,
        mode: DesktopCloseQuitMode,
        bundleIdentifier: String?,
        hasRunningApplication: Bool,
        blacklist: Set<String>,
        whitelist: Set<String>
    ) -> DesktopCloseAction {
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
            return blacklist.contains(bundleIdentifier)
                ? .closeWindow
                : .quitApplication
        case .whitelist:
            guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
                return .closeWindow
            }
            return whitelist.contains(bundleIdentifier)
                ? .quitApplication
                : .closeWindow
        }
    }
}

extension Notification.Name {
    static let appSettingsChanged = Notification.Name(
        "DockWindowPreview.appSettingsChanged"
    )
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
        static let desktopTrafficLightHoverEnlargementEnabled =
            "desktopTrafficLightHoverEnlargementEnabled"
        static let desktopTrafficLightHoverTargetSize =
            "desktopTrafficLightHoverTargetSize"
        static let desktopTrafficLightsRevealOnHover =
            "desktopTrafficLightsRevealOnHover"
        static let desktopCloseQuitsApplicationEnabled =
            "desktopCloseQuitsApplicationEnabled"
        static let desktopCloseQuitMode = "desktopCloseQuitMode"
        static let desktopCloseQuitBlacklist =
            "desktopCloseQuitBlacklist"
        static let desktopCloseQuitWhitelist =
            "desktopCloseQuitWhitelist"
        static let defaultsRevision = "defaultsRevision"
    }

    private enum LegacyKeys {
        static let hoverEnlargementEnabled =
            "previewControlHoverEnlargementEnabled"
        static let hoverTargetSize = "previewControlHoverTargetSize"
        static let revealOnControlAreaOnly =
            "previewControlsRevealOnControlAreaOnly"
        static let closeQuitsApplicationEnabled =
            "previewCloseQuitsApplicationEnabled"
        static let closeQuitMode = "previewCloseQuitMode"
        static let closeQuitBlacklist = "previewCloseQuitBlacklist"
        static let closeQuitWhitelist = "previewCloseQuitWhitelist"
    }

    static let minimumDesktopTrafficLightSize: CGFloat = 14
    static let maximumDesktopTrafficLightSize: CGFloat = 30
    static let defaultDesktopTrafficLightHoverTargetSize: CGFloat = 23

    private let currentDefaultsRevision = 2
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    var hoverDelay: TimeInterval {
        get {
            clamped(
                defaults.double(forKey: Keys.hoverDelay),
                min: 0.05,
                max: 0.8
            )
        }
        set { set(newValue, forKey: Keys.hoverDelay) }
    }

    var thumbnailHeight: CGFloat {
        get {
            CGFloat(clamped(
                defaults.double(forKey: Keys.thumbnailHeight),
                min: 100,
                max: 260
            ))
        }
        set { set(Double(newValue), forKey: Keys.thumbnailHeight) }
    }

    var thumbnailSize: NSSize {
        NSSize(width: thumbnailHeight * 1.6, height: thumbnailHeight)
    }

    func thumbnailSize(for window: WindowInfo) -> NSSize {
        let height = thumbnailHeight
        let aspectRatio = window.bounds.height > 0
            ? window.bounds.width / window.bounds.height
            : 1.6
        let width = clamped(
            Double(height * aspectRatio),
            min: 120,
            max: 460
        )
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
                let rawValue = defaults.string(
                    forKey: Keys.dockClickMinimizeMode
                ),
                let mode = DockClickMinimizeMode(rawValue: rawValue)
            else {
                return .off
            }
            return mode
        }
        set {
            set(newValue.rawValue, forKey: Keys.dockClickMinimizeMode)
        }
    }

    var desktopTrafficLightHoverEnlargementEnabled: Bool {
        get {
            defaults.bool(
                forKey: Keys.desktopTrafficLightHoverEnlargementEnabled
            )
        }
        set {
            set(
                newValue,
                forKey: Keys.desktopTrafficLightHoverEnlargementEnabled
            )
        }
    }

    var desktopTrafficLightHoverTargetSize: CGFloat {
        get {
            CGFloat(clamped(
                defaults.double(
                    forKey: Keys.desktopTrafficLightHoverTargetSize
                ),
                min: Double(Self.minimumDesktopTrafficLightSize),
                max: Double(Self.maximumDesktopTrafficLightSize),
                fallback: Double(
                    Self.defaultDesktopTrafficLightHoverTargetSize
                )
            ))
        }
        set {
            let value = clamped(
                Double(newValue),
                min: Double(Self.minimumDesktopTrafficLightSize),
                max: Double(Self.maximumDesktopTrafficLightSize),
                fallback: Double(
                    Self.defaultDesktopTrafficLightHoverTargetSize
                )
            )
            set(value, forKey: Keys.desktopTrafficLightHoverTargetSize)
        }
    }

    var desktopTrafficLightsRevealOnHover: Bool {
        get {
            defaults.bool(forKey: Keys.desktopTrafficLightsRevealOnHover)
        }
        set {
            set(newValue, forKey: Keys.desktopTrafficLightsRevealOnHover)
        }
    }

    var desktopCloseQuitsApplicationEnabled: Bool {
        get {
            defaults.bool(
                forKey: Keys.desktopCloseQuitsApplicationEnabled
            )
        }
        set {
            set(
                newValue,
                forKey: Keys.desktopCloseQuitsApplicationEnabled
            )
        }
    }

    var desktopCloseQuitMode: DesktopCloseQuitMode {
        get {
            guard
                let rawValue = defaults.string(
                    forKey: Keys.desktopCloseQuitMode
                ),
                let mode = DesktopCloseQuitMode(rawValue: rawValue)
            else {
                return .all
            }
            return mode
        }
        set {
            set(newValue.rawValue, forKey: Keys.desktopCloseQuitMode)
        }
    }

    var desktopCloseQuitBlacklist: Set<String> {
        get {
            bundleIdentifiers(forKey: Keys.desktopCloseQuitBlacklist)
        }
        set {
            setBundleIdentifiers(
                newValue,
                forKey: Keys.desktopCloseQuitBlacklist
            )
        }
    }

    var desktopCloseQuitWhitelist: Set<String> {
        get {
            bundleIdentifiers(forKey: Keys.desktopCloseQuitWhitelist)
        }
        set {
            setBundleIdentifiers(
                newValue,
                forKey: Keys.desktopCloseQuitWhitelist
            )
        }
    }

    var requiresDesktopTrafficLightOverlay: Bool {
        desktopTrafficLightHoverEnlargementEnabled
            || desktopTrafficLightsRevealOnHover
            || desktopCloseQuitsApplicationEnabled
    }

    func desktopCloseAction(
        bundleIdentifier: String?,
        hasRunningApplication: Bool
    ) -> DesktopCloseAction {
        DesktopCloseActionPolicy.action(
            isEnabled: desktopCloseQuitsApplicationEnabled,
            mode: desktopCloseQuitMode,
            bundleIdentifier: bundleIdentifier,
            hasRunningApplication: hasRunningApplication,
            blacklist: desktopCloseQuitBlacklist,
            whitelist: desktopCloseQuitWhitelist
        )
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.hoverDelay: 0.10,
            Keys.thumbnailHeight: 165.0,
            Keys.showWindowTitles: true,
            Keys.launchAtLogin: false,
            Keys.debugLoggingEnabled: false,
            Keys.dockClickMinimizeMode:
                DockClickMinimizeMode.off.rawValue,
            Keys.desktopTrafficLightHoverEnlargementEnabled: false,
            Keys.desktopTrafficLightHoverTargetSize: Double(
                Self.defaultDesktopTrafficLightHoverTargetSize
            ),
            Keys.desktopTrafficLightsRevealOnHover: false,
            Keys.desktopCloseQuitsApplicationEnabled: false,
            Keys.desktopCloseQuitMode:
                DesktopCloseQuitMode.all.rawValue,
            Keys.desktopCloseQuitBlacklist: [String](),
            Keys.desktopCloseQuitWhitelist: [String](),
            Keys.defaultsRevision: 0
        ])
        migrateDefaultsIfNeeded()
    }

    private func migrateDefaultsIfNeeded() {
        let revision = defaults.integer(forKey: Keys.defaultsRevision)
        guard revision < currentDefaultsRevision else { return }

        if revision < 1 {
            let currentHeight = defaults.double(forKey: Keys.thumbnailHeight)
            if abs(currentHeight - 150.0) < 0.5 {
                defaults.set(165.0, forKey: Keys.thumbnailHeight)
            }
        }

        if revision < 2 {
            migrateLegacyDesktopTrafficLightSettings()
        }

        defaults.set(currentDefaultsRevision, forKey: Keys.defaultsRevision)
    }

    private func migrateLegacyDesktopTrafficLightSettings() {
        if let value = defaults.object(
            forKey: LegacyKeys.hoverEnlargementEnabled
        ) as? Bool {
            defaults.set(
                value,
                forKey: Keys.desktopTrafficLightHoverEnlargementEnabled
            )
        }
        if let value = defaults.object(
            forKey: LegacyKeys.hoverTargetSize
        ) as? NSNumber {
            defaults.set(
                value.doubleValue,
                forKey: Keys.desktopTrafficLightHoverTargetSize
            )
        }
        if let value = defaults.object(
            forKey: LegacyKeys.revealOnControlAreaOnly
        ) as? Bool {
            defaults.set(
                value,
                forKey: Keys.desktopTrafficLightsRevealOnHover
            )
        }
        if let value = defaults.object(
            forKey: LegacyKeys.closeQuitsApplicationEnabled
        ) as? Bool {
            defaults.set(
                value,
                forKey: Keys.desktopCloseQuitsApplicationEnabled
            )
        }
        if let value = defaults.string(
            forKey: LegacyKeys.closeQuitMode
        ), DesktopCloseQuitMode(rawValue: value) != nil {
            defaults.set(value, forKey: Keys.desktopCloseQuitMode)
        }
        if let value = defaults.stringArray(
            forKey: LegacyKeys.closeQuitBlacklist
        ) {
            defaults.set(value, forKey: Keys.desktopCloseQuitBlacklist)
        }
        if let value = defaults.stringArray(
            forKey: LegacyKeys.closeQuitWhitelist
        ) {
            defaults.set(value, forKey: Keys.desktopCloseQuitWhitelist)
        }
    }

    private func bundleIdentifiers(forKey key: String) -> Set<String> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(
            normalizedBundleIdentifier
        ))
    }

    private func setBundleIdentifiers(
        _ identifiers: Set<String>,
        forKey key: String
    ) {
        let normalized = Set(identifiers.compactMap(
            normalizedBundleIdentifier
        ))
        set(normalized.sorted(), forKey: key)
    }

    private func normalizedBundleIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private func set(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(
            name: .appSettingsChanged,
            object: self
        )
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
