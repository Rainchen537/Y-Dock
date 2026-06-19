import AppKit
import ApplicationServices
import Foundation

final class WindowActivator {
    private enum AXAttributeNames {
        // Best-effort public Accessibility attribute. Some apps keep minimized
        // windows outside AXWindows until they are restored.
        static let minimizedWindows = "AXMinimizedWindows"
    }

    private var axWindowCache: [CGWindowID: AXUIElement] = [:]

    func activate(_ window: WindowInfo) {
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else {
            DWLog("Cannot find running application for pid \(window.ownerPID)")
            return
        }

        app.unhide()

        guard AXIsProcessTrusted() else {
            app.activate(options: [.activateIgnoringOtherApps])
            DWLog("Accessibility is not trusted; activated app but cannot raise a specific window")
            return
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let matchedBeforeActivation = matchingWindow(for: window, appElement: appElement)

        app.activate(options: [.activateIgnoringOtherApps])
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        if let matchedBeforeActivation {
            focus(matchedBeforeActivation, appElement: appElement, targetWindow: window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            app.activate(options: [.activateIgnoringOtherApps])
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

            guard let matchingWindow = self.matchingWindow(for: window, appElement: appElement) ?? matchedBeforeActivation else {
                DWLog("Could not match AX window for '\(window.title)'; app activation is the fallback")
                return
            }

            self.focus(matchingWindow, appElement: appElement, targetWindow: window)
        }
    }

    @discardableResult
    func close(_ window: WindowInfo) -> Bool {
        guard AXIsProcessTrusted() else {
            DWLog("Accessibility is not trusted; cannot close a specific window")
            return false
        }

        // Best-effort with public Accessibility APIs: windows do not reliably
        // expose their CGWindowID, so this uses the same title/geometry match as
        // focus, then presses the standard AX close button when available.
        let appElement = AXUIElementCreateApplication(window.ownerPID)
        guard let matchingWindow = matchingWindow(for: window, appElement: appElement) else {
            DWLog("Could not match AX window to close '\(window.title)'")
            return false
        }

        guard let closeButton = attribute(matchingWindow, kAXCloseButtonAttribute) as AXUIElement? else {
            DWLog("Matched AX window has no close button for '\(window.title)'")
            return false
        }

        let closeError = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        if closeError != AXError.success {
            DWLog("Pressing AX close button failed for '\(window.title)': \(closeError.rawValue)")
            return false
        }

        axWindowCache.removeValue(forKey: window.windowID)
        return true
    }

    @discardableResult
    func minimize(_ window: WindowInfo) -> Bool {
        guard AXIsProcessTrusted() else {
            DWLog("Accessibility is not trusted; cannot minimize a specific window")
            return false
        }

        let appElement = AXUIElementCreateApplication(window.ownerPID)
        guard let matchingWindow = matchingWindow(for: window, appElement: appElement) else {
            DWLog("Could not match AX window to minimize '\(window.title)'")
            return false
        }

        let error = AXUIElementSetAttributeValue(matchingWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        if error != .success {
            DWLog("Setting AXMinimized failed for '\(window.title)': \(error.rawValue)")
            return false
        }

        axWindowCache.removeValue(forKey: window.windowID)
        return true
    }

    @discardableResult
    func quitApplication(ownerPID: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: ownerPID) else {
            DWLog("Cannot find running application to quit for pid \(ownerPID)")
            return false
        }

        if ownerPID == ProcessInfo.processInfo.processIdentifier {
            NSApp.terminate(nil)
            return true
        }

        if app.terminate() {
            return true
        }

        DWLog("Graceful terminate failed for pid \(ownerPID); trying forceTerminate")
        return app.forceTerminate()
    }

    private func focus(_ matchingWindow: AXUIElement, appElement: AXUIElement, targetWindow: WindowInfo) {
        if targetWindow.isMinimized {
            let minimizeError = AXUIElementSetAttributeValue(matchingWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            if minimizeError != AXError.success {
                DWLog("Restoring minimized window failed for '\(targetWindow.title)': \(minimizeError.rawValue)")
            }
        }

        let focusWork = {
            let appFocusError = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, matchingWindow)
            if appFocusError != AXError.success {
                DWLog("Setting AXFocusedWindow failed for '\(targetWindow.title)': \(appFocusError.rawValue)")
            }

            let raiseError = AXUIElementPerformAction(matchingWindow, kAXRaiseAction as CFString)
            if raiseError != AXError.success {
                DWLog("AXRaise failed for '\(targetWindow.title)': \(raiseError.rawValue)")
            }

            let mainError = AXUIElementSetAttributeValue(matchingWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            if mainError != AXError.success {
                DWLog("Setting AXMain failed for '\(targetWindow.title)': \(mainError.rawValue)")
            }

            let focusedError = AXUIElementSetAttributeValue(matchingWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if focusedError != AXError.success {
                DWLog("Setting AXFocused failed for '\(targetWindow.title)': \(focusedError.rawValue)")
            }
        }

        if targetWindow.isMinimized {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: focusWork)
        } else {
            focusWork()
        }
    }

    private func matchingWindow(for targetWindow: WindowInfo, appElement: AXUIElement) -> AXUIElement? {
        if let cachedWindow = axWindowCache[targetWindow.windowID],
           matchScore(targetWindow: targetWindow, axWindow: cachedWindow) >= 28 {
            return cachedWindow
        }

        let axWindows = candidateWindows(for: appElement)
        guard !axWindows.isEmpty else {
            DWLog("No AX windows available for pid \(targetWindow.ownerPID)")
            return nil
        }

        guard let matchingWindow = bestMatch(for: targetWindow, in: axWindows) else {
            return nil
        }

        axWindowCache[targetWindow.windowID] = matchingWindow
        return matchingWindow
    }

    private func candidateWindows(for appElement: AXUIElement) -> [AXUIElement] {
        let normalWindows = attribute(appElement, kAXWindowsAttribute) as [AXUIElement]? ?? []
        let minimizedWindows = attribute(appElement, AXAttributeNames.minimizedWindows) as [AXUIElement]? ?? []
        return uniqueAXWindows(normalWindows + minimizedWindows)
    }

    private func uniqueAXWindows(_ windows: [AXUIElement]) -> [AXUIElement] {
        var seen = Set<CFHashCode>()
        var unique: [AXUIElement] = []

        for window in windows {
            let hash = CFHash(window)
            guard seen.insert(hash).inserted else { continue }
            unique.append(window)
        }

        return unique
    }

    private func bestMatch(for targetWindow: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        var best: (window: AXUIElement, score: Int)?

        for axWindow in axWindows {
            let score = matchScore(targetWindow: targetWindow, axWindow: axWindow)
            if score > (best?.score ?? 0) {
                best = (axWindow, score)
            }
        }

        guard let best, best.score >= 28 else { return nil }
        return best.window
    }

    private func matchScore(targetWindow: WindowInfo, axWindow: AXUIElement) -> Int {
        var score = 0

        let axTitle = (attribute(axWindow, kAXTitleAttribute) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let axTitle, !axTitle.isEmpty {
            let normalizedAXTitle = normalize(axTitle)
            let normalizedCGTitle = normalize(targetWindow.title)
            if normalizedAXTitle == normalizedCGTitle {
                score += 80
            } else if normalizedAXTitle.contains(normalizedCGTitle) || normalizedCGTitle.contains(normalizedAXTitle) {
                score += 35
            }
        }

        if let axFrame = frame(of: axWindow) {
            if abs(axFrame.width - targetWindow.bounds.width) < 12 {
                score += 12
            }
            if abs(axFrame.height - targetWindow.bounds.height) < 12 {
                score += 12
            }
            if abs(axFrame.minX - targetWindow.bounds.minX) < 24 {
                score += 8
            }
            if abs(axFrame.minY - targetWindow.bounds.minY) < 24 || abs(axFrame.maxY - targetWindow.bounds.maxY) < 24 {
                score += 8
            }
        }

        return score
    }

    private func normalize(_ string: String) -> String {
        string
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
    }

    private func attribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? T
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = attribute(element, kAXPositionAttribute) as AXValue?,
            let sizeValue = attribute(element, kAXSizeAttribute) as AXValue?
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue, .cgPoint, &point),
            AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }
}
