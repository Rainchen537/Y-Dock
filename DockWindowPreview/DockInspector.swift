import AppKit
import ApplicationServices
import Foundation

enum DockEdge: String {
    case bottom
    case left
    case right
}

struct DockRegion {
    let edge: DockEdge
    let frame: CGRect
    let screen: NSScreen
}

struct DockItem {
    let title: String
    let accessibilityDescription: String?
    let role: String?
    let frame: CGRect?
    let dockEdge: DockEdge
    let runningApplication: NSRunningApplication?

    var bundleIdentifier: String? {
        runningApplication?.bundleIdentifier
    }

    var identity: String {
        if let bundleIdentifier {
            return bundleIdentifier
        }
        if let pid = runningApplication?.processIdentifier {
            return "pid:\(pid)"
        }
        return "dock-item:\(title.lowercased())"
    }
}

final class DockInspector {
    func dockRegion(containing point: NSPoint) -> DockRegion? {
        guard let screen = screen(containing: point) ?? NSScreen.main else { return nil }

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let bottomInset = max(0, visibleFrame.minY - screenFrame.minY)
        let leftInset = max(0, visibleFrame.minX - screenFrame.minX)
        let rightInset = max(0, screenFrame.maxX - visibleFrame.maxX)

        // Best-effort: macOS has no public Dock geometry API. visibleFrame usually
        // reveals a non-hidden Dock; for auto-hide we fall back to Dock defaults.
        let detectedEdge: DockEdge
        let maxInset = max(bottomInset, leftInset, rightInset)
        if maxInset > 20 {
            if maxInset == leftInset {
                detectedEdge = .left
            } else if maxInset == rightInset {
                detectedEdge = .right
            } else {
                detectedEdge = .bottom
            }
        } else {
            detectedEdge = dockOrientationFromDefaults() ?? .bottom
        }

        let fallbackThickness: CGFloat = 96
        let margin: CGFloat = 10
        let regionFrame: CGRect

        switch detectedEdge {
        case .bottom:
            let height = max(bottomInset + margin, fallbackThickness)
            regionFrame = CGRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: height)
        case .left:
            let width = max(leftInset + margin, fallbackThickness)
            regionFrame = CGRect(x: screenFrame.minX, y: screenFrame.minY, width: width, height: screenFrame.height)
        case .right:
            let width = max(rightInset + margin, fallbackThickness)
            regionFrame = CGRect(x: screenFrame.maxX - width, y: screenFrame.minY, width: width, height: screenFrame.height)
        }

        return DockRegion(edge: detectedEdge, frame: regionFrame, screen: screen)
    }

    func dockItem(at point: NSPoint, in region: DockRegion) -> DockItem? {
        guard AXIsProcessTrusted() else {
            DWLog("Accessibility is not trusted; cannot inspect Dock item")
            return nil
        }

        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            DWLog("Dock.app is not present in NSWorkspace.runningApplications")
            return nil
        }

        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

        // Best-effort: there is no public Dock hover API. We ask Dock.app's AX tree
        // which element is under the mouse, then infer the App from AX labels.
        for lookupPoint in accessibilityLookupPoints(for: point, on: region.screen) {
            var element: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(dockElement, Float(lookupPoint.x), Float(lookupPoint.y), &element)
            guard error == .success, let element else {
                continue
            }

            if let item = bestDockItem(from: element, edge: region.edge) {
                return item
            }
        }

        DWLog("Dock AX hit-test failed at \(point). Active app fallback: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")")
        return nil
    }

    private func bestDockItem(from element: AXUIElement, edge: DockEdge) -> DockItem? {
        var candidates: [AXUIElement] = [element]
        if let parent = elementAttribute(element, attribute: kAXParentAttribute) as AXUIElement? {
            candidates.append(parent)
            if let grandParent = elementAttribute(parent, attribute: kAXParentAttribute) as AXUIElement? {
                candidates.append(grandParent)
            }
        }

        for candidate in candidates {
            let title = stringAttribute(candidate, attribute: kAXTitleAttribute)
            let description = stringAttribute(candidate, attribute: kAXDescriptionAttribute)
            let role = stringAttribute(candidate, attribute: kAXRoleAttribute)
            let identifier = stringAttribute(candidate, attribute: kAXIdentifierAttribute)

            let displayTitle = bestDisplayName(title: title, description: description, identifier: identifier)
            guard let displayTitle, !displayTitle.isEmpty, displayTitle.lowercased() != "dock" else {
                continue
            }

            // Best-effort: Dock AX elements do not expose a stable bundle id, so
            // we map the visible AX text back to NSWorkspace.runningApplications.
            let app = runningApplication(forDockTitle: displayTitle, description: description, identifier: identifier)
            if app == nil {
                DWLog("Dock item '\(displayTitle)' did not map to a running app. role=\(role ?? "nil") description=\(description ?? "nil")")
            }

            return DockItem(
                title: displayTitle,
                accessibilityDescription: description,
                role: role,
                frame: frame(of: candidate),
                dockEdge: edge,
                runningApplication: app
            )
        }

        return nil
    }

    private func runningApplication(forDockTitle title: String, description: String?, identifier: String?) -> NSRunningApplication? {
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular || app.bundleIdentifier == "com.apple.finder"
        }

        let titleTokens = candidateNames(from: title) + candidateNames(from: description) + candidateNames(from: identifier)
        guard !titleTokens.isEmpty else { return nil }

        var bestMatch: (app: NSRunningApplication, score: Int)?

        for app in runningApps {
            let appNames = [
                app.localizedName,
                app.bundleURL?.deletingPathExtension().lastPathComponent,
                app.bundleIdentifier
            ].compactMap { $0 }

            var score = 0
            for token in titleTokens {
                let normalizedToken = normalize(token)
                guard !normalizedToken.isEmpty else { continue }

                for appName in appNames {
                    let normalizedAppName = normalize(appName)
                    if normalizedToken == normalizedAppName {
                        score = max(score, 100)
                    } else if normalizedToken.contains(normalizedAppName), normalizedAppName.count >= 3 {
                        score = max(score, 75)
                    } else if normalizedAppName.contains(normalizedToken), normalizedToken.count >= 3 {
                        score = max(score, 65)
                    }
                }
            }

            if score > (bestMatch?.score ?? 0) {
                bestMatch = (app, score)
            }
        }

        guard let match = bestMatch, match.score >= 65 else { return nil }
        return match.app
    }

    private func candidateNames(from value: String?) -> [String] {
        guard let value else { return [] }
        let separators = CharacterSet(charactersIn: "\n,，-–—|")
        return value
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func bestDisplayName(title: String?, description: String?, identifier: String?) -> String? {
        for value in [title, description, identifier] {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                continue
            }
            return candidateNames(from: trimmed).first ?? trimmed
        }
        return nil
    }

    private func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: ".app", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func accessibilityLookupPoints(for point: NSPoint, on screen: NSScreen) -> [NSPoint] {
        let localY = point.y - screen.frame.minY
        let flippedY = screen.frame.maxY - localY
        let flipped = NSPoint(x: point.x, y: flippedY)
        if abs(flipped.y - point.y) < 0.5 {
            return [point]
        }
        return [point, flipped]
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func dockOrientationFromDefaults() -> DockEdge? {
        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation")
        switch orientation {
        case "left":
            return .left
        case "right":
            return .right
        case "bottom":
            return .bottom
        default:
            return nil
        }
    }

    private func stringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        elementAttribute(element, attribute: attribute) as String?
    }

    private func elementAttribute<T>(_ element: AXUIElement, attribute: String) -> T? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? T
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = elementAttribute(element, attribute: kAXPositionAttribute) as AXValue?,
            let sizeValue = elementAttribute(element, attribute: kAXSizeAttribute) as AXValue?
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
