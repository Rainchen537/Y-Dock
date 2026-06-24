import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct WindowInfo: Hashable, Identifiable {
    let windowID: CGWindowID
    let title: String
    let bounds: CGRect
    let ownerPID: pid_t
    let ownerName: String
    let isMinimized: Bool

    var id: CGWindowID { windowID }
}

final class WindowCollector {
    private struct CGWindowCandidate {
        let windowID: CGWindowID
        let title: String
        let bounds: CGRect
        let ownerName: String
    }

    private enum AXAttributeNames {
        // Best-effort public Accessibility attribute. Several apps remove
        // minimized windows from AXWindows and expose them only here.
        static let minimizedWindows = "AXMinimizedWindows"
    }

    func windows(for app: NSRunningApplication) -> [WindowInfo] {
        windows(for: app.processIdentifier, fallbackOwnerName: app.localizedName ?? "Unknown App")
    }

    func windows(for processIdentifier: pid_t, fallbackOwnerName: String = "Unknown App") -> [WindowInfo] {
        // Do not use optionOnScreenOnly here. Some minimized windows still have
        // a CG window record with kCGWindowIsOnscreen = false; keeping those
        // candidates gives us a chance to reuse a real CGWindowID for capture.
        let options: CGWindowListOption = [.excludeDesktopElements]
        let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        if rawWindows == nil {
            DWLog("CGWindowListCopyWindowInfo returned no window list")
        }

        var seenWindowIDs = Set<CGWindowID>()
        var results: [WindowInfo] = []
        var offscreenCandidates: [CGWindowCandidate] = []

        for dictionary in rawWindows ?? [] {
            guard
                let ownerPID = dictionary[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == processIdentifier,
                let windowNumber = dictionary[kCGWindowNumber as String] as? CGWindowID,
                !seenWindowIDs.contains(windowNumber),
                let layer = dictionary[kCGWindowLayer as String] as? Int,
                layer == 0
            else {
                continue
            }

            let isOnscreen = (dictionary[kCGWindowIsOnscreen as String] as? Bool) ?? false

            let alpha = (dictionary[kCGWindowAlpha as String] as? Double) ?? 1
            if isOnscreen, alpha <= 0.01 { continue }

            guard
                let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width >= 40,
                bounds.height >= 40
            else {
                continue
            }

            let title = (dictionary[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let ownerName = (dictionary[kCGWindowOwnerName as String] as? String) ?? fallbackOwnerName
            let displayTitle = title?.isEmpty == false ? title! : ownerName

            guard isLikelyUserWindow(title: title, ownerName: ownerName, bounds: bounds) else {
                continue
            }

            if !isOnscreen {
                offscreenCandidates.append(CGWindowCandidate(
                    windowID: windowNumber,
                    title: displayTitle,
                    bounds: bounds,
                    ownerName: ownerName
                ))
                continue
            }

            seenWindowIDs.insert(windowNumber)
            results.append(WindowInfo(
                windowID: windowNumber,
                title: displayTitle,
                bounds: bounds,
                ownerPID: ownerPID,
                ownerName: ownerName,
                isMinimized: false
            ))
        }

        appendMinimizedAXWindows(
            to: &results,
            processIdentifier: processIdentifier,
            fallbackOwnerName: fallbackOwnerName,
            offscreenCandidates: offscreenCandidates
        )

        return results
    }

    func switchableWindows(includeMinimized: Bool = true) -> [WindowInfo] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let switchableApps = NSWorkspace.shared.runningApplications.filter { app in
            !app.isTerminated
                && app.processIdentifier != currentPID
                && app.activationPolicy == .regular
        }
        let appsByPID = Dictionary(uniqueKeysWithValues: switchableApps.map { ($0.processIdentifier, $0) })

        let options: CGWindowListOption = [.excludeDesktopElements]
        let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        if rawWindows == nil {
            DWLog("CGWindowListCopyWindowInfo returned no switcher window list")
        }

        var seenWindowIDs = Set<CGWindowID>()
        var seenPIDs = Set<pid_t>()
        var pidOrder: [pid_t] = []
        var results: [WindowInfo] = []
        var offscreenCandidatesByPID: [pid_t: [CGWindowCandidate]] = [:]

        func rememberPID(_ pid: pid_t) {
            guard seenPIDs.insert(pid).inserted else { return }
            pidOrder.append(pid)
        }

        for dictionary in rawWindows ?? [] {
            guard
                let ownerPID = dictionary[kCGWindowOwnerPID as String] as? pid_t,
                let app = appsByPID[ownerPID],
                let windowNumber = dictionary[kCGWindowNumber as String] as? CGWindowID,
                !seenWindowIDs.contains(windowNumber),
                let layer = dictionary[kCGWindowLayer as String] as? Int,
                layer == 0
            else {
                continue
            }

            let isOnscreen = (dictionary[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let alpha = (dictionary[kCGWindowAlpha as String] as? Double) ?? 1
            if isOnscreen, alpha <= 0.01 { continue }

            guard
                let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width >= 40,
                bounds.height >= 40
            else {
                continue
            }

            let title = (dictionary[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let ownerName = (dictionary[kCGWindowOwnerName as String] as? String) ?? app.localizedName ?? "Unknown App"
            let displayTitle = title?.isEmpty == false ? title! : ownerName

            guard isLikelyUserWindow(title: title, ownerName: ownerName, bounds: bounds) else {
                continue
            }

            if !isOnscreen {
                offscreenCandidatesByPID[ownerPID, default: []].append(CGWindowCandidate(
                    windowID: windowNumber,
                    title: displayTitle,
                    bounds: bounds,
                    ownerName: ownerName
                ))
                continue
            }

            seenWindowIDs.insert(windowNumber)
            rememberPID(ownerPID)
            results.append(WindowInfo(
                windowID: windowNumber,
                title: displayTitle,
                bounds: bounds,
                ownerPID: ownerPID,
                ownerName: ownerName,
                isMinimized: false
            ))
        }

        guard includeMinimized else {
            return results
        }

        let remainingPIDs = switchableApps
            .map(\.processIdentifier)
            .filter { !seenPIDs.contains($0) }

        for pid in pidOrder + remainingPIDs {
            guard let app = appsByPID[pid] else { continue }
            appendMinimizedAXWindows(
                to: &results,
                processIdentifier: pid,
                fallbackOwnerName: app.localizedName ?? "Unknown App",
                offscreenCandidates: offscreenCandidatesByPID[pid] ?? []
            )
        }

        return results
    }

    private func appendMinimizedAXWindows(
        to results: inout [WindowInfo],
        processIdentifier: pid_t,
        fallbackOwnerName: String,
        offscreenCandidates: [CGWindowCandidate]
    ) {
        guard AXIsProcessTrusted() else { return }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        let axWindows = attribute(appElement, kAXWindowsAttribute) as [AXUIElement]? ?? []
        let axMinimizedWindows = attribute(appElement, AXAttributeNames.minimizedWindows) as [AXUIElement]? ?? []
        let minimizedWindows = uniqueAXWindows(
            axMinimizedWindows + axWindows.filter { (attribute($0, kAXMinimizedAttribute) as Bool?) == true }
        )

        if minimizedWindows.isEmpty {
            DWLog("No minimized AX windows for pid \(processIdentifier)")
            return
        }

        var syntheticIndex: UInt32 = 0
        for axWindow in minimizedWindows {
            // AXMinimizedWindows is already the authoritative minimized list for
            // many apps. Keep the flag permissive because some apps do not return
            // AXMinimized reliably on those elements.
            let isMinimized = (attribute(axWindow, kAXMinimizedAttribute) as Bool?) ?? true
            guard isMinimized else {
                continue
            }

            if let role = attribute(axWindow, kAXRoleAttribute) as String?,
               role != kAXWindowRole {
                continue
            }

            let title = ((attribute(axWindow, kAXTitleAttribute) as String?) ?? fallbackOwnerName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? fallbackOwnerName : title
            let bounds = frame(of: axWindow) ?? CGRect(x: 0, y: 0, width: 900, height: 560)
            let fallbackBounds = bounds.width >= 40 && bounds.height >= 40 ? bounds : CGRect(x: 0, y: 0, width: 900, height: 560)
            let cgCandidate = bestCGCandidate(forTitle: displayTitle, bounds: fallbackBounds, in: offscreenCandidates)

            if let candidateWindowID = cgCandidate?.windowID,
               results.contains(where: { existing in
                   existing.ownerPID == processIdentifier && existing.windowID == candidateWindowID
               }) {
                continue
            }

            syntheticIndex += 1
            results.append(WindowInfo(
                windowID: cgCandidate?.windowID ?? syntheticWindowID(
                    processIdentifier: processIdentifier,
                    title: displayTitle,
                    bounds: fallbackBounds,
                    index: syntheticIndex
                ),
                title: displayTitle,
                bounds: fallbackBounds,
                ownerPID: processIdentifier,
                ownerName: cgCandidate?.ownerName ?? fallbackOwnerName,
                isMinimized: true
            ))

            if let cgCandidate {
                DWLog("Matched minimized AX window '\(displayTitle)' to offscreen CG window \(cgCandidate.windowID)")
            }
        }

        DWLog("Collected \(syntheticIndex) minimized AX windows for pid \(processIdentifier)")
    }

    private func bestCGCandidate(forTitle title: String, bounds: CGRect, in candidates: [CGWindowCandidate]) -> CGWindowCandidate? {
        var best: (candidate: CGWindowCandidate, score: Int)?

        for candidate in candidates {
            var score = 0
            let normalizedCandidateTitle = normalize(candidate.title)
            let normalizedTitle = normalize(title)

            if !normalizedCandidateTitle.isEmpty, !normalizedTitle.isEmpty {
                if normalizedCandidateTitle == normalizedTitle {
                    score += 80
                } else if normalizedCandidateTitle.contains(normalizedTitle) || normalizedTitle.contains(normalizedCandidateTitle) {
                    score += 35
                }
            }

            if abs(candidate.bounds.width - bounds.width) < 16 {
                score += 12
            }
            if abs(candidate.bounds.height - bounds.height) < 16 {
                score += 12
            }

            if score > (best?.score ?? 0) {
                best = (candidate, score)
            }
        }

        guard let best, best.score >= 40 else { return nil }
        return best.candidate
    }

    private func isLikelyUserWindow(title: String?, ownerName: String, bounds: CGRect) -> Bool {
        let hasUsefulTitle = title?.isEmpty == false || !ownerName.isEmpty
        guard hasUsefulTitle else { return false }
        guard bounds.width >= 40, bounds.height >= 40 else { return false }
        return true
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

    private func syntheticWindowID(processIdentifier: pid_t, title: String, bounds: CGRect, index: UInt32) -> CGWindowID {
        var hash: UInt32 = 2166136261
        let string = "\(processIdentifier)|\(title)|\(Int(bounds.width))x\(Int(bounds.height))|\(index)"
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return 0x8000_0000 | (hash & 0x7fff_ffff)
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

    private func normalize(_ string: String) -> String {
        string
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
    }
}
