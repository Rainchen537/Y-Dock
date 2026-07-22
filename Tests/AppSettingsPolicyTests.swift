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
        testDockClickFrontmostSnapshot()
        testDockClickTopmostWindowPolicy()
        testDockClickTopmostWindowSnapshot()
        testPreviewClosePolicies()
        testIndependentListPersistence()
        testInvalidRawValuesFallBackSafely()
        testControlHoverSizeClamp()

        guard failureCount == 0 else {
            fputs("\(failureCount) AppSettings/policy test(s) failed.\n", stderr)
            exit(1)
        }
        print("All AppSettings/policy tests passed.")
    }

    private static func testDockClickMinimizeModes() {
        expect(
            !DockClickMinimizePolicy.shouldMinimize(mode: .off, totalWindowCount: 1),
            "off mode must never minimize"
        )
        expect(
            DockClickMinimizePolicy.shouldMinimize(mode: .onlySingleWindow, totalWindowCount: 1),
            "onlySingleWindow must minimize exactly one user window"
        )
        expect(
            !DockClickMinimizePolicy.shouldMinimize(mode: .onlySingleWindow, totalWindowCount: 0),
            "onlySingleWindow must reject zero windows"
        )
        expect(
            !DockClickMinimizePolicy.shouldMinimize(mode: .onlySingleWindow, totalWindowCount: 2),
            "onlySingleWindow must reject multiple windows"
        )
        expect(
            DockClickMinimizePolicy.shouldMinimize(mode: .allWindows, totalWindowCount: 3),
            "allWindows must accept one or more windows"
        )
        expect(
            !DockClickMinimizePolicy.shouldMinimize(mode: .allWindows, totalWindowCount: 0),
            "allWindows must reject an empty window list"
        )
    }

    private static func testDockClickFrontmostSnapshot() {
        let targetPID: pid_t = 100
        let otherPID: pid_t = 200

        expect(
            DockClickMinimizePolicy.targetWasFrontmostBeforeClick(
                targetPID: targetPID,
                observedFrontmostPID: targetPID,
                trackedFrontmostPID: targetPID,
                previousTrackedFrontmostPID: otherPID,
                frontmostPIDAtLastPointerMove: targetPID,
                frontmostChangedAt: 10,
                lastPointerMoveAt: 11
            ),
            "a target that remained frontmost through the last pointer move must be accepted"
        )
        expect(
            !DockClickMinimizePolicy.targetWasFrontmostBeforeClick(
                targetPID: targetPID,
                observedFrontmostPID: otherPID,
                trackedFrontmostPID: otherPID,
                previousTrackedFrontmostPID: targetPID,
                frontmostPIDAtLastPointerMove: targetPID,
                frontmostChangedAt: 12,
                lastPointerMoveAt: 11
            ),
            "a background target must be rejected before Dock activates it"
        )
        expect(
            !DockClickMinimizePolicy.targetWasFrontmostBeforeClick(
                targetPID: targetPID,
                observedFrontmostPID: targetPID,
                trackedFrontmostPID: otherPID,
                previousTrackedFrontmostPID: targetPID,
                frontmostPIDAtLastPointerMove: targetPID,
                frontmostChangedAt: 12,
                lastPointerMoveAt: 11
            ),
            "an in-flight Dock activation must be rejected before the workspace notification arrives"
        )
        expect(
            !DockClickMinimizePolicy.targetWasFrontmostBeforeClick(
                targetPID: targetPID,
                observedFrontmostPID: targetPID,
                trackedFrontmostPID: targetPID,
                previousTrackedFrontmostPID: otherPID,
                frontmostPIDAtLastPointerMove: targetPID,
                frontmostChangedAt: 12,
                lastPointerMoveAt: 11
            ),
            "a target activated after the last pointer move must be rejected"
        )
        expect(
            DockClickMinimizePolicy.targetWasFrontmostBeforeClick(
                targetPID: targetPID,
                observedFrontmostPID: targetPID,
                trackedFrontmostPID: targetPID,
                previousTrackedFrontmostPID: otherPID,
                frontmostPIDAtLastPointerMove: targetPID,
                frontmostChangedAt: 12,
                lastPointerMoveAt: 13
            ),
            "a new pointer move after activation must refresh the frontmost snapshot"
        )

        let mismatchedSnapshots: [(pid_t?, pid_t?, pid_t?)] = [
            (otherPID, targetPID, targetPID),
            (targetPID, otherPID, targetPID),
            (targetPID, targetPID, otherPID),
            (nil, targetPID, targetPID),
            (targetPID, nil, targetPID),
            (targetPID, targetPID, nil)
        ]
        for (observedPID, trackedPID, pointerMovePID) in mismatchedSnapshots {
            expect(
                !DockClickMinimizePolicy.targetWasFrontmostBeforeClick(
                    targetPID: targetPID,
                    observedFrontmostPID: observedPID,
                    trackedFrontmostPID: trackedPID,
                    previousTrackedFrontmostPID: targetPID,
                    frontmostPIDAtLastPointerMove: pointerMovePID,
                    frontmostChangedAt: 10,
                    lastPointerMoveAt: 11
                ),
                "all frontmost snapshots must match the target"
            )
        }
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
            ),
            DockClickWindowStackEntry(
                ownerPID: otherPID,
                layer: 0,
                isOnscreen: true,
                alpha: 1,
                bounds: CGRect(x: 0, y: 0, width: 500, height: 300),
                isRegularApplication: false,
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
            "Y-Dock, transparent, and non-regular windows must not cover the target"
        )
        expect(
            DockClickMinimizePolicy.topmostUserWindowOwnerPID(
                in: ignoredEntries + [otherEntry, targetEntry]
            ) == otherPID,
            "the first eligible ordinary user window must determine the topmost owner"
        )
        expect(
            DockClickMinimizePolicy.topmostUserWindowOwnerPID(
                in: ignoredEntries
            ) == nil,
            "a window stack without an eligible ordinary user window must return nil"
        )
    }

    private static func testDockClickTopmostWindowSnapshot() {
        let targetPID: pid_t = 100
        let otherPID: pid_t = 200

        expect(
            DockClickMinimizePolicy.targetOwnedTopmostUserWindowBeforeClick(
                targetPID: targetPID,
                observedTopmostUserWindowOwnerPID: targetPID,
                topmostUserWindowOwnerPIDAtLastPointerMove: targetPID
            ),
            "the target must be accepted when both topmost-window snapshots match"
        )
        expect(
            !DockClickMinimizePolicy.targetOwnedTopmostUserWindowBeforeClick(
                targetPID: targetPID,
                observedTopmostUserWindowOwnerPID: otherPID,
                topmostUserWindowOwnerPIDAtLastPointerMove: targetPID
            ),
            "a different currently topmost window owner must reject the Dock action"
        )
        expect(
            !DockClickMinimizePolicy.targetOwnedTopmostUserWindowBeforeClick(
                targetPID: targetPID,
                observedTopmostUserWindowOwnerPID: targetPID,
                topmostUserWindowOwnerPIDAtLastPointerMove: otherPID
            ),
            "a target activated after the last pointer move must not pass the topmost check"
        )
        expect(
            !DockClickMinimizePolicy.targetOwnedTopmostUserWindowBeforeClick(
                targetPID: targetPID,
                observedTopmostUserWindowOwnerPID: nil,
                topmostUserWindowOwnerPIDAtLastPointerMove: nil
            ),
            "missing topmost-window evidence must fail closed"
        )
    }

    private static func testPreviewClosePolicies() {
        let blacklist: Set<String> = ["com.example.blocked"]
        let whitelist: Set<String> = ["com.example.allowed"]

        expect(
            PreviewCloseActionPolicy.action(
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
            PreviewCloseActionPolicy.action(
                isEnabled: true,
                mode: .all,
                bundleIdentifier: nil,
                hasRunningApplication: true,
                blacklist: blacklist,
                whitelist: whitelist
            ) == .quitApplication,
            "all mode may quit a known running app even without a bundle ID"
        )
        expect(
            PreviewCloseActionPolicy.action(
                isEnabled: true,
                mode: .blacklist,
                bundleIdentifier: "com.example.blocked",
                hasRunningApplication: true,
                blacklist: blacklist,
                whitelist: whitelist
            ) == .closeWindow,
            "blacklisted apps must keep close-window behavior"
        )
        expect(
            PreviewCloseActionPolicy.action(
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
            PreviewCloseActionPolicy.action(
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
            PreviewCloseActionPolicy.action(
                isEnabled: true,
                mode: .whitelist,
                bundleIdentifier: "com.example.other",
                hasRunningApplication: true,
                blacklist: blacklist,
                whitelist: whitelist
            ) == .closeWindow,
            "apps outside the whitelist must close the window"
        )
        for mode in [PreviewCloseQuitMode.blacklist, .whitelist] {
            expect(
                PreviewCloseActionPolicy.action(
                    isEnabled: true,
                    mode: mode,
                    bundleIdentifier: nil,
                    hasRunningApplication: true,
                    blacklist: blacklist,
                    whitelist: whitelist
                ) == .closeWindow,
                "list modes must conservatively close when bundle ID is missing"
            )
        }
        expect(
            PreviewCloseActionPolicy.action(
                isEnabled: true,
                mode: .all,
                bundleIdentifier: "com.example.app",
                hasRunningApplication: false,
                blacklist: blacklist,
                whitelist: whitelist
            ) == .closeWindow,
            "quit policy must close when the running app cannot be obtained"
        )
    }

    private static func testIndependentListPersistence() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.previewCloseQuitBlacklist = ["com.example.black.one", "com.example.black.two"]
            settings.previewCloseQuitWhitelist = ["com.example.white"]
            settings.previewCloseQuitMode = .blacklist
            settings.previewCloseQuitMode = .whitelist
            settings.previewCloseQuitsApplicationEnabled = false

            let reloaded = AppSettings(defaults: defaults)
            expect(
                reloaded.previewCloseQuitBlacklist == ["com.example.black.one", "com.example.black.two"],
                "blacklist must persist independently"
            )
            expect(
                reloaded.previewCloseQuitWhitelist == ["com.example.white"],
                "whitelist must persist independently"
            )
        }
    }

    private static func testInvalidRawValuesFallBackSafely() {
        withDefaults { defaults in
            defaults.set("not-a-mode", forKey: "dockClickMinimizeMode")
            defaults.set("not-a-mode", forKey: "previewCloseQuitMode")
            let settings = AppSettings(defaults: defaults)

            expect(settings.dockClickMinimizeMode == .off, "invalid Dock mode must fall back to off")
            expect(settings.previewCloseQuitMode == .all, "invalid close policy mode must fall back to all")
        }
    }

    private static func testControlHoverSizeClamp() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.previewControlHoverTargetSize = -100
            expect(
                settings.previewControlHoverTargetSize == AppSettings.minimumPreviewControlSize,
                "hover size must clamp to its minimum"
            )

            settings.previewControlHoverTargetSize = 100
            expect(
                settings.previewControlHoverTargetSize == AppSettings.maximumPreviewControlSize,
                "hover size must clamp to its maximum"
            )

            defaults.set(Double.nan, forKey: "previewControlHoverTargetSize")
            expect(
                settings.previewControlHoverTargetSize == AppSettings.defaultPreviewControlHoverTargetSize,
                "non-finite hover size must fall back to the default"
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

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            failureCount += 1
            fputs("FAIL: \(message)\n", stderr)
            return
        }
    }
}
