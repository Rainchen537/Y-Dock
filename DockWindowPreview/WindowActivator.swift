import AppKit
import ApplicationServices
import Foundation

final class WindowActivator {
    private enum AXAttributeNames {
        // Best-effort public Accessibility attribute. Some apps keep minimized
        // windows outside AXWindows until they are restored.
        static let minimizedWindows = "AXMinimizedWindows"

        // Best-effort public Accessibility attribute names observed on some
        // apps. Edge/Chrome do not expose these today, so title/geometry remain
        // the fallback path.
        static let possibleWindowIDs = ["AXWindowID", "AXWindowNumber"]
    }

    private struct MatchDetails {
        let window: AXUIElement
        let score: Int
        let titleScore: Int
        let windowIDScore: Int
        let geometryScore: Int

        var hasIdentityEvidence: Bool {
            titleScore > 0 || windowIDScore > 0
        }
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

            guard let matchingWindow = self.matchingWindow(for: window, appElement: appElement, allowCached: false) ?? matchedBeforeActivation else {
                DWLog("Could not match AX window for '\(window.title)'; app activation is the fallback")
                return
            }

            self.focus(matchingWindow, appElement: appElement, targetWindow: window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            guard let matchingWindow = self.matchingWindow(for: window, appElement: appElement, allowCached: false) ?? matchedBeforeActivation else {
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
    func minimize(_ windows: [WindowInfo]) -> Int {
        windows.reduce(into: 0) { minimizedCount, window in
            guard !window.isMinimized, minimize(window) else { return }
            minimizedCount += 1
        }
    }

    @discardableResult
    func gracefulQuitApplication(ownerPID: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: ownerPID) else {
            DWLog("Cannot find running application to gracefully quit for pid \(ownerPID)")
            return false
        }

        if ownerPID == ProcessInfo.processInfo.processIdentifier {
            NSApp.terminate(nil)
            return true
        }

        let didRequestTermination = app.terminate()
        if !didRequestTermination {
            DWLog("Graceful terminate failed for pid \(ownerPID)")
        }
        return didRequestTermination
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
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

            let raiseError = AXUIElementPerformAction(matchingWindow, kAXRaiseAction as CFString)
            if raiseError != AXError.success {
                DWLog("AXRaise failed for '\(targetWindow.title)': \(raiseError.rawValue)")
            }

            let appFocusError = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, matchingWindow)
            if appFocusError != AXError.success {
                DWLog("Setting AXFocusedWindow failed for '\(targetWindow.title)': \(appFocusError.rawValue)")
            }

            let mainError = AXUIElementSetAttributeValue(matchingWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            if mainError != AXError.success {
                DWLog("Setting AXMain failed for '\(targetWindow.title)': \(mainError.rawValue)")
            }

            let focusedError = AXUIElementSetAttributeValue(matchingWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if focusedError != AXError.success {
                DWLog("Setting AXFocused failed for '\(targetWindow.title)': \(focusedError.rawValue)")
            }

            let secondRaiseError = AXUIElementPerformAction(matchingWindow, kAXRaiseAction as CFString)
            if secondRaiseError != AXError.success {
                DWLog("Second AXRaise failed for '\(targetWindow.title)': \(secondRaiseError.rawValue)")
            }

            AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, matchingWindow)
        }

        if targetWindow.isMinimized {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: focusWork)
        } else {
            focusWork()
        }
    }

    private func matchingWindow(for targetWindow: WindowInfo, appElement: AXUIElement, allowCached: Bool = true) -> AXUIElement? {
        if allowCached,
           let cachedWindow = axWindowCache[targetWindow.windowID] {
            let cachedMatch = matchDetails(targetWindow: targetWindow, axWindow: cachedWindow)
            if cachedMatch.hasIdentityEvidence || cachedMatch.score >= 50 {
                return cachedWindow
            }

            // Browser windows often share identical geometry. A geometry-only
            // cached match can point to the previous Edge/Chrome window after a
            // tab title changes, so drop it and resolve from the current AX list.
            axWindowCache.removeValue(forKey: targetWindow.windowID)
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
        var best: MatchDetails?

        for axWindow in axWindows {
            let details = matchDetails(targetWindow: targetWindow, axWindow: axWindow)
            if details.score > (best?.score ?? 0) {
                best = details
            }
        }

        guard let best, best.score >= 28 else { return nil }
        if best.hasIdentityEvidence || axWindows.count == 1 {
            return best.window
        }

        if hasUsefulTargetTitle(targetWindow) {
            DWLog("Rejecting geometry-only AX match for '\(targetWindow.title)' because multiple windows are available")
            return nil
        }

        return best.score >= 50 ? best.window : nil
    }

    private func matchDetails(targetWindow: WindowInfo, axWindow: AXUIElement) -> MatchDetails {
        var titleScore = 0
        var windowIDScore = 0
        var geometryScore = 0

        let axTitle = (attribute(axWindow, kAXTitleAttribute) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let axTitle, !axTitle.isEmpty {
            titleScore = titleMatchScore(
                targetTitle: targetWindow.title,
                axTitle: axTitle,
                ownerName: targetWindow.ownerName
            )
        }

        if let axWindowID = windowID(of: axWindow),
           axWindowID == targetWindow.windowID {
            windowIDScore = 160
        }

        if let axFrame = frame(of: axWindow) {
            if abs(axFrame.width - targetWindow.bounds.width) < 12 {
                geometryScore += 12
            }
            if abs(axFrame.height - targetWindow.bounds.height) < 12 {
                geometryScore += 12
            }
            if abs(axFrame.minX - targetWindow.bounds.minX) < 24 {
                geometryScore += 8
            }
            if abs(axFrame.minY - targetWindow.bounds.minY) < 24 || abs(axFrame.maxY - targetWindow.bounds.maxY) < 24 {
                geometryScore += 8
            }
        }

        return MatchDetails(
            window: axWindow,
            score: titleScore + windowIDScore + geometryScore,
            titleScore: titleScore,
            windowIDScore: windowIDScore,
            geometryScore: geometryScore
        )
    }

    private func normalize(_ string: String) -> String {
        string
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
    }

    private func hasUsefulTargetTitle(_ targetWindow: WindowInfo) -> Bool {
        let normalizedTitle = normalize(targetWindow.title)
        guard !normalizedTitle.isEmpty else { return false }
        return normalizedTitle != normalize(targetWindow.ownerName)
    }

    private func titleMatchScore(targetTitle: String, axTitle: String, ownerName: String) -> Int {
        let normalizedAXTitle = normalize(axTitle)
        let normalizedTargetTitle = normalize(targetTitle)
        guard !normalizedTargetTitle.isEmpty, normalizedTargetTitle != normalize(ownerName) else {
            return 0
        }

        if normalizedAXTitle == normalizedTargetTitle {
            return 120
        }

        if normalizedAXTitle.contains(normalizedTargetTitle) || normalizedTargetTitle.contains(normalizedAXTitle) {
            return 80
        }

        if ellipsisTitleMatch(shortTitle: normalizedTargetTitle, fullTitle: normalizedAXTitle) {
            return 72
        }

        let fuzzyScore = fuzzyTitleScore(targetTitle: targetTitle, axTitle: axTitle)
        return fuzzyScore
    }

    private func ellipsisTitleMatch(shortTitle: String, fullTitle: String) -> Bool {
        let separators = ["…", "..."]
        var parts = [shortTitle]
        for separator in separators where shortTitle.contains(separator) {
            parts = shortTitle
                .components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
            break
        }

        guard parts.count >= 2 else { return false }

        var searchStart = fullTitle.startIndex
        for part in parts {
            guard let range = fullTitle.range(of: part, range: searchStart..<fullTitle.endIndex) else {
                return false
            }
            searchStart = range.upperBound
        }

        return true
    }

    private func fuzzyTitleScore(targetTitle: String, axTitle: String) -> Int {
        let targetTokens = titleTokens(targetTitle).filter { $0.count >= 3 }
        let axTokens = titleTokens(axTitle)
        guard !targetTokens.isEmpty, !axTokens.isEmpty else {
            return 0
        }

        let matchedCount = targetTokens.reduce(0) { count, token in
            let matched = axTokens.contains { axToken in
                tokenMatches(token, axToken)
            }
            return count + (matched ? 1 : 0)
        }

        if targetTokens.count == 1 {
            return matchedCount == 1 ? 45 : 0
        }

        let ratio = Double(matchedCount) / Double(targetTokens.count)
        if matchedCount >= 4, ratio >= 0.50 {
            return 65
        }

        if matchedCount >= 2, ratio >= 0.45 {
            return 45
        }

        return 0
    }

    private func titleTokens(_ string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)

        for scalar in string.lowercased().unicodeScalars {
            if separators.contains(scalar) {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.unicodeScalars.append(scalar)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private func tokenMatches(_ left: String, _ right: String) -> Bool {
        if left == right {
            return true
        }

        if left.count >= 4, right.hasPrefix(left) {
            return true
        }

        if right.count >= 4, left.hasPrefix(right) {
            return true
        }

        if left.count >= 5, right.contains(left) {
            return true
        }

        if right.count >= 5, left.contains(right) {
            return true
        }

        return false
    }

    private func windowID(of axWindow: AXUIElement) -> CGWindowID? {
        for attributeName in AXAttributeNames.possibleWindowIDs {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(axWindow, attributeName as CFString, &value)
            guard error == .success, let value else {
                continue
            }

            if let number = value as? NSNumber {
                return CGWindowID(number.uint32Value)
            }

            if let string = value as? String,
               let number = UInt32(string) {
                return CGWindowID(number)
            }
        }

        return nil
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
