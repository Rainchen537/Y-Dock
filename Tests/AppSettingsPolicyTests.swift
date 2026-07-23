import AppKit
import Foundation

struct WindowInfo {
    let bounds: CGRect
}

@main
private enum AppSettingsPolicyTests {
    private static var failureCount = 0

    static func main() {
        testDockClickMinimizeModes()
        testDockClickFrontmostEvidence()
        testDockClickSnapshotRefreshPolicy()
        testDockClickTopmostWindowPolicy()
        testDockClickTimestampedSnapshots()
        testDesktopClosePolicies()
        testIndependentListPersistence()
        testLegacyDesktopSettingsMigration()
        testInvalidRawValuesFallBackSafely()
        testTrafficLightHoverSizeClamp()

        guard failureCount == 0 else {
            fputs("\(failureCount) AppSettings/policy test(s) failed.\n", stderr)
            exit(1)
        }
        print("All AppSettings/policy tests passed.")
    }

    private static func testDockClickMinimizeModes() {
        expect(
            !DockClickMinimizePolicy.shouldMinimize(
                mode: .off,
                totalWindowCount: 1
            ),
            "off mode must never minimize"
        )
        expect(
            DockClickMinimizePolicy.shouldMinimize(
                mode: .onlySingleWindow,
                totalWindowCount: 1
            ),
            "onlySingleWindow must minimize exactly one user window"
        )
        expect(
            !DockClickMinimizePolicy.shouldMinimize(
                mode: .onlySingleWindow,
                totalWindowCount: 0
            ),
            "onlySingleWindow must reject zero windows"
        )
        expect(
            !DockClickMinimizePolicy.shouldMinimize(
                mode: .onlySingleWindow,
                totalWindowCount: 2
            ),
            "onlySingleWindow must reject multiple windows"
        )
        expect(
            DockClickMinimizePolicy.shouldMinimize(
                mode: .allWindows,
                totalWindowCount: 3
            ),
            "allWindows must accept one or more windows"
        )
    }

    private static func testDockClickFrontmostEvidence() {
        let targetPID: pid_t = 100
        let otherPID: pid_t = 200

        let direct = DockClickMinimizePolicy.frontmostDecision(
            targetPID: targetPID,
            observedFrontmostPID: targetPID,
            trackedFrontmostPID: targetPID,
            previousTrackedFrontmostPID: otherPID,
            frontmostPIDAtLastPointerMove: targetPID,
            frontmostChangedAt: 10,
            lastPointerMoveAt: 11,
            clickAt: 11.1
        )
        expect(direct.isAccepted, "matching pointer evidence must be accepted")
        expect(
            !direct.acceptedStableActivationAfterPointerMove,
            "matching pointer evidence must use the direct path"
        )

        let background = DockClickMinimizePolicy.frontmostDecision(
            targetPID: targetPID,
            observedFrontmostPID: otherPID,
            trackedFrontmostPID: otherPID,
            previousTrackedFrontmostPID: targetPID,
            frontmostPIDAtLastPointerMove: targetPID,
            frontmostChangedAt: 12,
            lastPointerMoveAt: 11,
            clickAt: 12.3
        )
        expect(!background.isAccepted, "a background target must be rejected")

        let unstableActivation = DockClickMinimizePolicy.frontmostDecision(
            targetPID: targetPID,
            observedFrontmostPID: targetPID,
            trackedFrontmostPID: targetPID,
            previousTrackedFrontmostPID: otherPID,
            frontmostPIDAtLastPointerMove: otherPID,
            frontmostChangedAt: 12,
            lastPointerMoveAt: 11.9,
            clickAt: 12.1
        )
        expect(
            !unstableActivation.isAccepted,
            "a recent activation after the last pointer move must be rejected"
        )

        let stableActivation = DockClickMinimizePolicy.frontmostDecision(
            targetPID: targetPID,
            observedFrontmostPID: targetPID,
            trackedFrontmostPID: targetPID,
            previousTrackedFrontmostPID: otherPID,
            frontmostPIDAtLastPointerMove: otherPID,
            frontmostChangedAt: 12,
            lastPointerMoveAt: 11.7,
            clickAt: 12.2
        )
        expect(
            stableActivation.isAccepted,
            "a stable activation may use fresh post-activation window snapshots"
        )
        expect(
            stableActivation.acceptedStableActivationAfterPointerMove,
            "stable post-move activation must be marked for stricter snapshot filtering"
        )
    }

    private static func testDockClickSnapshotRefreshPolicy() {
        expect(
            DockClickMinimizePolicy.shouldRefreshTopmostSnapshot(
                isEnabled: true,
                isInsideSnapshotRegion: true,
                wasInsideSnapshotRegion: false,
                now: 10,
                lastSnapshotAt: 9.99,
                minimumInterval: 0.08
            ),
            "entering the Dock region must capture immediately"
        )
        expect(
            !DockClickMinimizePolicy.shouldRefreshTopmostSnapshot(
                isEnabled: true,
                isInsideSnapshotRegion: true,
                wasInsideSnapshotRegion: true,
                now: 10,
                lastSnapshotAt: 9.95,
                minimumInterval: 0.08
            ),
            "a recent snapshot must not be refreshed too early"
        )
        expect(
            DockClickMinimizePolicy.shouldRefreshTopmostSnapshot(
                isEnabled: true,
                isInsideSnapshotRegion: true,
                wasInsideSnapshotRegion: true,
                now: 10.04,
                lastSnapshotAt: 9.95,
                minimumInterval: 0.08
            ),
            "a stale snapshot must refresh while the pointer remains over Dock"
        )
        expect(
            !DockClickMinimizePolicy.shouldRefreshTopmostSnapshot(
                isEnabled: false,
                isInsideSnapshotRegion: true,
                wasInsideSnapshotRegion: false,
                now: 10,
                lastSnapshotAt: 0,
                minimumInterval: 0.08
            ),
            "disabled Dock minimization must not collect snapshots"
        )
    }

    private static func testDockClickTopmostWindowPolicy() {
        let targetPID: pid_t = 100
        let otherPID: pid_t = 200
        let yDockPID: pid_t = 300

        let ignoredEntries = [
            DockClickWindowStackEntry(
                ownerPID: yDockPID,
                layer: 999,
                isOnscreen: true,
                alpha: 1,
                bounds: CGRect(x: 0, y: 0, width: 500, height: 300),
                isRegularApplication: false,
                isExcludedOwner: true,
                isLikelyUserWindow: true
            ),
            DockClickWindowStackEntry(
                ownerPID: otherPID,
                layer: 0,
                isOnscreen: true,
                alpha: 0,
                bounds: CGRect(x: 0, y: 0, width: 500, height: 300),
                isRegularApplication: true,
                isExcludedOwner: false,
                isLikelyUserWindow: true
            )
        ]
        let targetEntry = DockClickWindowStackEntry(
            ownerPID: targetPID,
            layer: 0,
            isOnscreen: true,
            alpha: 1,
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
            isRegularApplication: true,
            isExcludedOwner: false,
            isLikelyUserWindow: true
        )
        let otherEntry = DockClickWindowStackEntry(
            ownerPID: otherPID,
            layer: 0,
            isOnscreen: true,
            alpha: 1,
            bounds: CGRect(x: 120, y: 120, width: 700, height: 500),
            isRegularApplication: true,
            isExcludedOwner: false,
            isLikelyUserWindow: true
        )

        expect(
            DockClickMinimizePolicy.topmostUserWindowOwnerPID(
                in: ignoredEntries + [targetEntry]
            ) == targetPID,
            "excluded and transparent windows must not cover the target"
        )
        expect(
            DockClickMinimizePolicy.topmostUserWindowOwnerPID(
                in: ignoredEntries + [otherEntry, targetEntry]
            ) == otherPID,
            "the first eligible ordinary window must determine the topmost owner"
        )
    }

    private static func testDockClickTimestampedSnapshots() {
        let targetPID: pid_t = 100
        let otherPID: pid_t = 200
        let snapshots = [
            DockClickTopmostSnapshot(ownerPID: targetPID, capturedAt: 10.00),
            DockClickTopmostSnapshot(ownerPID: otherPID, capturedAt: 10.12),
            DockClickTopmostSnapshot(ownerPID: targetPID, capturedAt: 10.30)
        ]

        expect(
            DockClickMinimizePolicy.recentTopmostSnapshotOwnerPID(
                targetPID: targetPID,
                snapshots: snapshots,
                clickAt: 10.35
            ) == targetPID,
            "the newest fresh target snapshot must be accepted"
        )
        expect(
            DockClickMinimizePolicy.recentTopmostSnapshotOwnerPID(
                targetPID: targetPID,
                snapshots: snapshots,
                clickAt: 10.60
            ) == nil,
            "a snapshot older than the maximum age must be rejected"
        )
        expect(
            DockClickMinimizePolicy.stableTopmostSnapshotOwnerPID(
                targetPID: targetPID,
                snapshots: snapshots,
                frontmostChangedAt: 10.15,
                clickAt: 10.35,
                minimumStableActivationDuration: 0.18
            ) == nil,
            "stable activation evidence must be captured after the stability threshold"
        )

        let stableSnapshots = snapshots + [
            DockClickTopmostSnapshot(ownerPID: targetPID, capturedAt: 10.34)
        ]
        expect(
            DockClickMinimizePolicy.stableTopmostSnapshotOwnerPID(
                targetPID: targetPID,
                snapshots: stableSnapshots,
                frontmostChangedAt: 10.15,
                clickAt: 10.35,
                minimumStableActivationDuration: 0.18
            ) == targetPID,
            "a fresh post-threshold target snapshot must be accepted"
        )
        expect(
            DockClickMinimizePolicy.targetOwnedTopmostUserWindowBeforeClick(
                targetPID: targetPID,
                observedTopmostUserWindowOwnerPID: targetPID,
                preClickTopmostUserWindowOwnerPID: targetPID
            ),
            "current and pre-click topmost evidence must both match"
        )
        expect(
            !DockClickMinimizePolicy.targetOwnedTopmostUserWindowBeforeClick(
                targetPID: targetPID,
                observedTopmostUserWindowOwnerPID: otherPID,
                preClickTopmostUserWindowOwnerPID: targetPID
            ),
            "a covering ordinary window must reject minimization"
        )
    }

    private static func testDesktopClosePolicies() {
        let blacklist: Set<String> = ["com.example.blocked"]
        let whitelist: Set<String> = ["com.example.allowed"]

        expect(
            DesktopCloseActionPolicy.action(
                isEnabled: false,
                mode: .all,
                bundleIdentifier: "com.example.app",
                hasRunningApplication: true,
                blacklist: blacklist,
                whitelist: whitelist
            ) == .closeWindow,
            "disabled quit policy must close the window"
        )
        expect(
            DesktopCloseActionPolicy.action(
                isEnabled: true,
                mode: .all,
                bundleIdentifier: nil,
                hasRunningApplication: true,
                blacklist: blacklist,
                whitelist: whitelist
            ) == .quitApplication,
            "all mode may quit a known running app without a bundle ID"
        )
        expect(
            DesktopCloseActionPolicy.action(
                isEnabled: true,
                mode: .blacklist,
                bundleIdentifier: "com.example.blocked",
                hasRunningApplication: true,
                blacklist: blacklist,
                whitelist: whitelist
            ) == .closeWindow,
            "blacklisted apps must retain close-window behavior"
        )
        expect(
            DesktopCloseActionPolicy.action(
                isEnabled: true,
                mode: .blacklist,
                bundleIdentifier: "com.example.other",
                hasRunningApplication: true,
                blacklist: blacklist,
                whitelist: whitelist
            ) == .quitApplication,
            "apps outside the blacklist must request quit"
        )
        expect(
            DesktopCloseActionPolicy.action(
                isEnabled: true,
                mode: .whitelist,
                bundleIdentifier: "com.example.allowed",
                hasRunningApplication: true,
                blacklist: blacklist,
                whitelist: whitelist
            ) == .quitApplication,
            "whitelisted apps must request quit"
        )
        expect(
            DesktopCloseActionPolicy.action(
                isEnabled: true,
                mode: .whitelist,
                bundleIdentifier: "com.example.other",
                hasRunningApplication: true,
                blacklist: blacklist,
                whitelist: whitelist
            ) == .closeWindow,
            "apps outside the whitelist must close the window"
        )
        expect(
            DesktopCloseActionPolicy.action(
                isEnabled: true,
                mode: .whitelist,
                bundleIdentifier: nil,
                hasRunningApplication: true,
                blacklist: blacklist,
                whitelist: whitelist
            ) == .closeWindow,
            "list modes must fail closed when the bundle ID is missing"
        )
    }

    private static func testIndependentListPersistence() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.desktopCloseQuitBlacklist = [
                "com.example.black.one",
                "com.example.black.two"
            ]
            settings.desktopCloseQuitWhitelist = ["com.example.white"]
            settings.desktopCloseQuitMode = .blacklist
            settings.desktopCloseQuitMode = .whitelist
            settings.desktopCloseQuitsApplicationEnabled = false

            let reloaded = AppSettings(defaults: defaults)
            expect(
                reloaded.desktopCloseQuitBlacklist == [
                    "com.example.black.one",
                    "com.example.black.two"
                ],
                "desktop blacklist must persist independently"
            )
            expect(
                reloaded.desktopCloseQuitWhitelist == ["com.example.white"],
                "desktop whitelist must persist independently"
            )
        }
    }

    private static func testLegacyDesktopSettingsMigration() {
        withDefaults { defaults in
            defaults.set(1, forKey: "defaultsRevision")
            defaults.set(true, forKey: "previewControlHoverEnlargementEnabled")
            defaults.set(27.0, forKey: "previewControlHoverTargetSize")
            defaults.set(true, forKey: "previewControlsRevealOnControlAreaOnly")
            defaults.set(true, forKey: "previewCloseQuitsApplicationEnabled")
            defaults.set("whitelist", forKey: "previewCloseQuitMode")
            defaults.set(
                ["com.example.black"],
                forKey: "previewCloseQuitBlacklist"
            )
            defaults.set(
                ["com.example.white"],
                forKey: "previewCloseQuitWhitelist"
            )

            let settings = AppSettings(defaults: defaults)
            expect(
                settings.desktopTrafficLightHoverEnlargementEnabled,
                "legacy hover enlargement must migrate to desktop controls"
            )
            expect(
                settings.desktopTrafficLightHoverTargetSize == 27,
                "legacy hover size must migrate to desktop controls"
            )
            expect(
                settings.desktopTrafficLightsRevealOnHover,
                "legacy reveal mode must migrate to desktop controls"
            )
            expect(
                settings.desktopCloseQuitsApplicationEnabled,
                "legacy close policy enablement must migrate"
            )
            expect(
                settings.desktopCloseQuitMode == .whitelist,
                "legacy close policy mode must migrate"
            )
            expect(
                settings.desktopCloseQuitBlacklist == ["com.example.black"],
                "legacy blacklist must migrate"
            )
            expect(
                settings.desktopCloseQuitWhitelist == ["com.example.white"],
                "legacy whitelist must migrate"
            )
        }
    }

    private static func testInvalidRawValuesFallBackSafely() {
        withDefaults { defaults in
            defaults.set("not-a-mode", forKey: "dockClickMinimizeMode")
            defaults.set("not-a-mode", forKey: "desktopCloseQuitMode")
            let settings = AppSettings(defaults: defaults)

            expect(
                settings.dockClickMinimizeMode == .off,
                "invalid Dock mode must fall back to off"
            )
            expect(
                settings.desktopCloseQuitMode == .all,
                "invalid desktop close mode must fall back to all"
            )
        }
    }

    private static func testTrafficLightHoverSizeClamp() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.desktopTrafficLightHoverTargetSize = -100
            expect(
                settings.desktopTrafficLightHoverTargetSize
                    == AppSettings.minimumDesktopTrafficLightSize,
                "desktop traffic-light size must clamp to its minimum"
            )

            settings.desktopTrafficLightHoverTargetSize = 100
            expect(
                settings.desktopTrafficLightHoverTargetSize
                    == AppSettings.maximumDesktopTrafficLightSize,
                "desktop traffic-light size must clamp to its maximum"
            )

            defaults.set(
                Double.nan,
                forKey: "desktopTrafficLightHoverTargetSize"
            )
            expect(
                settings.desktopTrafficLightHoverTargetSize
                    == AppSettings.defaultDesktopTrafficLightHoverTargetSize,
                "non-finite desktop traffic-light size must use the default"
            )
        }
    }

    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "com.ydock.AppSettingsPolicyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            failureCount += 1
            fputs("FAIL: could not create isolated UserDefaults suite\n", stderr)
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        body(defaults)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            failureCount += 1
            fputs("FAIL: \(message)\n", stderr)
            return
        }
    }
}
