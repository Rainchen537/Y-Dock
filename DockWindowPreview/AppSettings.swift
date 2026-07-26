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
        static let defaultsRevision = "defaultsRevision"
    }

    private enum RemovedDesktopControlKeys {
        static let desktopHoverEnlargementEnabled =
            "desktopTrafficLightHoverEnlargementEnabled"
        static let desktopHoverTargetSize =
            "desktopTrafficLightHoverTargetSize"
        static let desktopRevealOnHover =
            "desktopTrafficLightsRevealOnHover"
        static let desktopCloseQuitsApplicationEnabled =
            "desktopCloseQuitsApplicationEnabled"
        static let desktopCloseQuitMode = "desktopCloseQuitMode"
        static let desktopCloseQuitBlacklist =
            "desktopCloseQuitBlacklist"
        static let desktopCloseQuitWhitelist =
            "desktopCloseQuitWhitelist"
        static let legacyHoverEnlargementEnabled =
            "previewControlHoverEnlargementEnabled"
        static let legacyHoverTargetSize = "previewControlHoverTargetSize"
        static let legacyRevealOnControlAreaOnly =
            "previewControlsRevealOnControlAreaOnly"
        static let legacyCloseQuitsApplicationEnabled =
            "previewCloseQuitsApplicationEnabled"
        static let legacyCloseQuitMode = "previewCloseQuitMode"
        static let legacyCloseQuitBlacklist = "previewCloseQuitBlacklist"
        static let legacyCloseQuitWhitelist = "previewCloseQuitWhitelist"

        static let all = [
            desktopHoverEnlargementEnabled,
            desktopHoverTargetSize,
            desktopRevealOnHover,
            desktopCloseQuitsApplicationEnabled,
            desktopCloseQuitMode,
            desktopCloseQuitBlacklist,
            desktopCloseQuitWhitelist,
            legacyHoverEnlargementEnabled,
            legacyHoverTargetSize,
            legacyRevealOnControlAreaOnly,
            legacyCloseQuitsApplicationEnabled,
            legacyCloseQuitMode,
            legacyCloseQuitBlacklist,
            legacyCloseQuitWhitelist
        ]
    }

    private let currentDefaultsRevision = 3
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

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.hoverDelay: 0.10,
            Keys.thumbnailHeight: 165.0,
            Keys.showWindowTitles: true,
            Keys.launchAtLogin: false,
            Keys.debugLoggingEnabled: false,
            Keys.dockClickMinimizeMode:
                DockClickMinimizeMode.off.rawValue,
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

        if revision < 3 {
            purgeRemovedDesktopControlSettings()
        }

        defaults.set(currentDefaultsRevision, forKey: Keys.defaultsRevision)
    }

    private func purgeRemovedDesktopControlSettings() {
        for key in RemovedDesktopControlKeys.all {
            defaults.removeObject(forKey: key)
        }
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
