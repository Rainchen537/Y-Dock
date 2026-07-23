import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore

final class DesktopWindowControlsController {
    private enum RefreshTiming {
        static let timerInterval: TimeInterval = 0.45
        static let minimumRefreshInterval: CFTimeInterval = 0.16
        static let actionRefreshDelay: TimeInterval = 0.12
    }

    private let settings: AppSettings
    private var isRunning = false
    private var refreshTimer: Timer?
    private var pendingRefreshWorkItem: DispatchWorkItem?
    private var lastRefreshTimestamp: CFTimeInterval = 0
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var panelsByWindowID: [CGWindowID: DesktopTrafficLightPanel] = [:]

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    deinit {
        if Thread.isMainThread {
            stop()
        }
    }

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.start()
            }
            return
        }

        guard !isRunning else { return }
        isRunning = true
        installMouseMonitors()
        installObservers()
        installRefreshTimer()
        scheduleRefresh(immediate: true)
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.stop()
            }
            return
        }

        guard isRunning else { return }
        isRunning = false

        pendingRefreshWorkItem?.cancel()
        pendingRefreshWorkItem = nil

        refreshTimer?.invalidate()
        refreshTimer = nil

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }

        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }

        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        notificationObservers.removeAll()

        removeAllPanels()
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseUp,
            .rightMouseUp,
            .otherMouseUp
        ]

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mask
        ) { [weak self] event in
            self?.handleMouseEvent(event)
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mask
        ) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        updatePanelsForCurrentMouseLocation()

        switch event.type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            scheduleRefresh(immediate: false)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            scheduleRefresh(immediate: true)
        default:
            break
        }
    }

    private func installObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh(immediate: true)
        })

        notificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh(immediate: true)
        })

        notificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh(immediate: false)
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .appSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh(immediate: true)
        })
    }

    private func installRefreshTimer() {
        let timer = Timer(timeInterval: RefreshTiming.timerInterval, repeats: true) { [weak self] _ in
            self?.scheduleRefresh(immediate: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func scheduleRefresh(immediate: Bool) {
        guard isRunning else { return }

        let now = CACurrentMediaTime()
        let delay: TimeInterval
        if immediate {
            delay = 0
        } else {
            delay = TimeInterval(max(0, RefreshTiming.minimumRefreshInterval - (now - lastRefreshTimestamp)))
        }

        if pendingRefreshWorkItem != nil, !immediate {
            return
        }

        pendingRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshVisibleWindows()
        }
        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func refreshVisibleWindows() {
        guard isRunning else { return }
        pendingRefreshWorkItem = nil
        lastRefreshTimestamp = CACurrentMediaTime()

        guard settings.requiresDesktopTrafficLightOverlay, AXIsProcessTrusted() else {
            removeAllPanels()
            return
        }

        let descriptors = collectOverlayDescriptors()
        let visibleWindowIDs = Set(descriptors.map(\.windowID))

        for windowID in Array(panelsByWindowID.keys) where !visibleWindowIDs.contains(windowID) {
            panelsByWindowID[windowID]?.closePanel()
            panelsByWindowID.removeValue(forKey: windowID)
        }

        for descriptor in descriptors {
            let panel = panelsByWindowID[descriptor.windowID] ?? makePanel(for: descriptor.windowID)
            panel.configure(
                descriptor: descriptor,
                targetDiameter: targetButtonDiameter,
                revealOnHover: settings.desktopTrafficLightsRevealOnHover,
                hoverEnlargementEnabled: settings.desktopTrafficLightHoverEnlargementEnabled
            )
            panel.order(.above, relativeTo: Int(descriptor.windowID))
            panelsByWindowID[descriptor.windowID] = panel
        }

        updatePanelsForCurrentMouseLocation()
    }

    private func makePanel(for windowID: CGWindowID) -> DesktopTrafficLightPanel {
        let panel = DesktopTrafficLightPanel()
        panel.onButtonPressed = { [weak self] kind, targetWindowID in
            self?.performAction(kind, forWindowID: targetWindowID)
        }
        panelsByWindowID[windowID] = panel
        return panel
    }

    private func removeAllPanels() {
        panelsByWindowID.values.forEach { $0.closePanel() }
        panelsByWindowID.removeAll()
    }

    private func updatePanelsForCurrentMouseLocation() {
        guard isRunning else { return }
        let mouseLocation = NSEvent.mouseLocation
        for panel in panelsByWindowID.values {
            panel.updateMouseLocation(
                mouseLocation,
                targetDiameter: targetButtonDiameter,
                revealOnHover: settings.desktopTrafficLightsRevealOnHover,
                hoverEnlargementEnabled: settings.desktopTrafficLightHoverEnlargementEnabled
            )
        }
    }

    private var targetButtonDiameter: CGFloat {
        DesktopTrafficLightLayout.clampButtonDiameter(CGFloat(settings.desktopTrafficLightHoverTargetSize))
    }

    private func collectOverlayDescriptors() -> [DesktopOverlayDescriptor] {
        let coordinateMapper = DesktopScreenCoordinateMapper()
        let candidates = collectVisibleCGWindowCandidates(coordinateMapper: coordinateMapper)
        guard !candidates.isEmpty else { return [] }

        var snapshotsByPID: [pid_t: [DesktopAXWindowSnapshot]] = [:]
        var usedAXWindowsByPID: [pid_t: [AXUIElement]] = [:]
        var descriptors: [DesktopOverlayDescriptor] = []
        var usedWindowIDs = Set<CGWindowID>()

        for candidate in candidates {
            guard !usedWindowIDs.contains(candidate.windowID) else { continue }

            let snapshots: [DesktopAXWindowSnapshot]
            if let cached = snapshotsByPID[candidate.ownerPID] {
                snapshots = cached
            } else {
                let loaded = loadAXWindowSnapshots(for: candidate.runningApplication, coordinateMapper: coordinateMapper)
                snapshotsByPID[candidate.ownerPID] = loaded
                snapshots = loaded
            }

            guard !snapshots.isEmpty else { continue }

            let usedAXWindows = usedAXWindowsByPID[candidate.ownerPID] ?? []
            guard let matchedSnapshot = bestAXWindowMatch(for: candidate, in: snapshots, excluding: usedAXWindows) else {
                continue
            }

            guard !isLikelyFullScreen(candidate: candidate, axWindow: matchedSnapshot) else {
                continue
            }

            guard let descriptor = makeOverlayDescriptor(
                candidate: candidate,
                axWindow: matchedSnapshot
            ) else {
                continue
            }

            descriptors.append(descriptor)
            usedWindowIDs.insert(candidate.windowID)
            usedAXWindowsByPID[candidate.ownerPID, default: []].append(matchedSnapshot.element)
        }

        return descriptors
    }

    private func collectVisibleCGWindowCandidates(coordinateMapper: DesktopScreenCoordinateMapper) -> [DesktopCGWindowCandidate] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let runningApps = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]

        if rawWindows == nil {
            DWLog("CGWindowListCopyWindowInfo returned no desktop window list")
        }

        var candidates: [DesktopCGWindowCandidate] = []
        var seenWindowIDs = Set<CGWindowID>()

        for dictionary in rawWindows ?? [] {
            guard
                let ownerPID = dictionary[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID != currentPID,
                let app = runningApps[ownerPID],
                app.activationPolicy == .regular,
                !app.isTerminated,
                app.bundleIdentifier != currentBundleIdentifier,
                let windowID = dictionary[kCGWindowNumber as String] as? CGWindowID,
                !seenWindowIDs.contains(windowID),
                let layer = dictionary[kCGWindowLayer as String] as? Int,
                layer == 0,
                (dictionary[kCGWindowIsOnscreen as String] as? Bool) == true
            else {
                continue
            }

            let alpha = (dictionary[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0.01 else { continue }

            guard
                let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
                let topLeftBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                topLeftBounds.width >= 80,
                topLeftBounds.height >= 60,
                let appKitBounds = coordinateMapper.appKitRect(fromTopLeftRect: topLeftBounds),
                visibleArea(of: appKitBounds) >= 1600
            else {
                continue
            }

            let rawTitle = (dictionary[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let ownerName = (dictionary[kCGWindowOwnerName as String] as? String) ?? app.localizedName ?? "Unknown App"
            let displayTitle = rawTitle?.isEmpty == false ? rawTitle! : ownerName

            seenWindowIDs.insert(windowID)
            candidates.append(DesktopCGWindowCandidate(
                windowID: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                title: displayTitle,
                topLeftBounds: topLeftBounds,
                appKitBounds: appKitBounds,
                runningApplication: app
            ))
        }

        return candidates
    }

    private func loadAXWindowSnapshots(
        for app: NSRunningApplication,
        coordinateMapper: DesktopScreenCoordinateMapper
    ) -> [DesktopAXWindowSnapshot] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let axWindows = attribute(appElement, kAXWindowsAttribute) as [AXUIElement]? ?? []
        let uniqueWindows = uniqueAXWindows(axWindows)
        var snapshots: [DesktopAXWindowSnapshot] = []

        for axWindow in uniqueWindows {
            guard isStandardAXWindow(axWindow) else { continue }
            guard (attribute(axWindow, kAXMinimizedAttribute) as Bool?) != true else { continue }

            guard
                let topLeftFrame = frame(of: axWindow),
                topLeftFrame.width >= 80,
                topLeftFrame.height >= 60,
                let appKitFrame = coordinateMapper.appKitRect(fromTopLeftRect: topLeftFrame)
            else {
                continue
            }

            guard visibleArea(of: appKitFrame) >= 1600 else { continue }
            guard let controls = standardControls(for: axWindow, coordinateMapper: coordinateMapper) else { continue }

            let title = ((attribute(axWindow, kAXTitleAttribute) as String?) ?? app.localizedName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            snapshots.append(DesktopAXWindowSnapshot(
                element: axWindow,
                title: title,
                topLeftFrame: topLeftFrame,
                appKitFrame: appKitFrame,
                explicitWindowID: explicitCGWindowID(of: axWindow),
                isFullScreen: (attribute(axWindow, DesktopAXAttributeNames.fullScreen) as Bool?) == true,
                controls: controls
            ))
        }

        return snapshots
    }

    private func standardControls(
        for axWindow: AXUIElement,
        coordinateMapper: DesktopScreenCoordinateMapper
    ) -> [DesktopAXButtonSnapshot]? {
        guard
            let close = buttonSnapshot(
                kind: .close,
                window: axWindow,
                attributeName: kAXCloseButtonAttribute,
                coordinateMapper: coordinateMapper
            ),
            let minimize = buttonSnapshot(
                kind: .minimize,
                window: axWindow,
                attributeName: kAXMinimizeButtonAttribute,
                coordinateMapper: coordinateMapper
            )
        else {
            return nil
        }

        let fullScreen = buttonSnapshot(
            kind: .fullScreen,
            window: axWindow,
            attributeName: DesktopAXAttributeNames.fullScreenButton,
            coordinateMapper: coordinateMapper
        ) ?? buttonSnapshot(
            kind: .fullScreen,
            window: axWindow,
            attributeName: kAXZoomButtonAttribute,
            coordinateMapper: coordinateMapper
        )

        guard let fullScreen else { return nil }
        return [close, minimize, fullScreen]
    }

    private func buttonSnapshot(
        kind: DesktopTrafficLightKind,
        window: AXUIElement,
        attributeName: String,
        coordinateMapper: DesktopScreenCoordinateMapper
    ) -> DesktopAXButtonSnapshot? {
        guard let element = attribute(window, attributeName) as AXUIElement? else { return nil }
        guard (attribute(element, DesktopAXAttributeNames.hidden) as Bool?) != true else { return nil }

        guard
            let topLeftFrame = frame(of: element),
            topLeftFrame.width >= 8,
            topLeftFrame.height >= 8,
            topLeftFrame.width <= 64,
            topLeftFrame.height <= 64,
            let appKitFrame = coordinateMapper.appKitRect(fromTopLeftRect: topLeftFrame)
        else {
            return nil
        }

        return DesktopAXButtonSnapshot(
            kind: kind,
            element: element,
            topLeftFrame: topLeftFrame,
            appKitFrame: appKitFrame
        )
    }

    private func bestAXWindowMatch(
        for candidate: DesktopCGWindowCandidate,
        in snapshots: [DesktopAXWindowSnapshot],
        excluding usedAXWindows: [AXUIElement]
    ) -> DesktopAXWindowSnapshot? {
        var best: (snapshot: DesktopAXWindowSnapshot, score: Int)?
        var secondBestScore = 0

        for snapshot in snapshots {
            guard !usedAXWindows.containsAXElement(snapshot.element) else { continue }

            if let explicitWindowID = snapshot.explicitWindowID {
                if explicitWindowID == candidate.windowID {
                    return snapshot
                }
                continue
            }

            let score = windowMatchScore(candidate: candidate, axWindow: snapshot)
            if score > (best?.score ?? 0) {
                secondBestScore = best?.score ?? 0
                best = (snapshot, score)
            } else if score > secondBestScore {
                secondBestScore = score
            }
        }

        guard let best, best.score >= 96 else { return nil }
        if secondBestScore > 0, best.score - secondBestScore < 18 {
            DWLog("Skipping ambiguous desktop AX/CG match for window \(candidate.windowID)")
            return nil
        }

        return best.snapshot
    }

    private func windowMatchScore(candidate: DesktopCGWindowCandidate, axWindow: DesktopAXWindowSnapshot) -> Int {
        let geometryScore = geometryMatchScore(candidate.topLeftBounds, axWindow.topLeftFrame)
        let titleScore = titleMatchScore(
            candidateTitle: candidate.title,
            axTitle: axWindow.title,
            ownerName: candidate.ownerName
        )

        if geometryScore < 52, titleScore < 80 {
            return 0
        }

        return geometryScore + titleScore
    }

    private func geometryMatchScore(_ left: CGRect, _ right: CGRect) -> Int {
        var score = 0
        score += axisDistanceScore(abs(left.minX - right.minX), tight: 6, medium: 18, loose: 36, tightScore: 28, mediumScore: 18, looseScore: 8)
        score += axisDistanceScore(abs(left.minY - right.minY), tight: 6, medium: 18, loose: 36, tightScore: 28, mediumScore: 18, looseScore: 8)
        score += axisDistanceScore(abs(left.width - right.width), tight: 6, medium: 18, loose: 36, tightScore: 24, mediumScore: 16, looseScore: 7)
        score += axisDistanceScore(abs(left.height - right.height), tight: 6, medium: 18, loose: 36, tightScore: 24, mediumScore: 16, looseScore: 7)

        let intersection = left.intersection(right)
        if !intersection.isNull, !intersection.isEmpty {
            let unionArea = max(1, left.area + right.area - intersection.area)
            let ratio = intersection.area / unionArea
            if ratio >= 0.96 {
                score += 32
            } else if ratio >= 0.90 {
                score += 22
            } else if ratio >= 0.78 {
                score += 10
            }
        }

        return score
    }

    private func axisDistanceScore(
        _ distance: CGFloat,
        tight: CGFloat,
        medium: CGFloat,
        loose: CGFloat,
        tightScore: Int,
        mediumScore: Int,
        looseScore: Int
    ) -> Int {
        if distance <= tight { return tightScore }
        if distance <= medium { return mediumScore }
        if distance <= loose { return looseScore }
        return 0
    }

    private func titleMatchScore(candidateTitle: String, axTitle: String, ownerName: String) -> Int {
        let normalizedCandidate = normalizeTitle(candidateTitle)
        let normalizedAX = normalizeTitle(axTitle)
        let normalizedOwner = normalizeTitle(ownerName)

        guard !normalizedCandidate.isEmpty, !normalizedAX.isEmpty, normalizedCandidate != normalizedOwner else {
            return 0
        }

        if normalizedCandidate == normalizedAX {
            return 84
        }

        if normalizedCandidate.contains(normalizedAX) || normalizedAX.contains(normalizedCandidate) {
            return 42
        }

        if ellipsisTitleMatch(shortTitle: normalizedCandidate, fullTitle: normalizedAX)
            || ellipsisTitleMatch(shortTitle: normalizedAX, fullTitle: normalizedCandidate) {
            return 38
        }

        return fuzzyTitleScore(candidateTitle: candidateTitle, axTitle: axTitle)
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

    private func fuzzyTitleScore(candidateTitle: String, axTitle: String) -> Int {
        let candidateTokens = titleTokens(candidateTitle).filter { $0.count >= 3 }
        let axTokens = titleTokens(axTitle)
        guard !candidateTokens.isEmpty, !axTokens.isEmpty else { return 0 }

        let matchedCount = candidateTokens.reduce(0) { count, token in
            let matched = axTokens.contains { axToken in
                tokenMatches(token, axToken)
            }
            return count + (matched ? 1 : 0)
        }

        if candidateTokens.count == 1 {
            return matchedCount == 1 ? 28 : 0
        }

        let ratio = Double(matchedCount) / Double(candidateTokens.count)
        if matchedCount >= 4, ratio >= 0.50 { return 34 }
        if matchedCount >= 2, ratio >= 0.45 { return 24 }
        return 0
    }

    private func normalizeTitle(_ string: String) -> String {
        string
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
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
        if left == right { return true }
        if left.count >= 4, right.hasPrefix(left) { return true }
        if right.count >= 4, left.hasPrefix(right) { return true }
        if left.count >= 5, right.contains(left) { return true }
        if right.count >= 5, left.contains(right) { return true }
        return false
    }

    private func makeOverlayDescriptor(
        candidate: DesktopCGWindowCandidate,
        axWindow: DesktopAXWindowSnapshot
    ) -> DesktopOverlayDescriptor? {
        let fixedHitDiameter = DesktopTrafficLightLayout.fixedHitDiameter
        var overlayFrame: NSRect?

        let buttons = axWindow.controls.map { button -> DesktopOverlayButton in
            let center = button.appKitFrame.center
            let nativeDiameter = max(button.appKitFrame.width, button.appKitFrame.height)
            let hitDiameter = max(fixedHitDiameter, nativeDiameter + DesktopTrafficLightLayout.hitPadding * 2)
            let hitRect = NSRect(
                x: center.x - hitDiameter / 2,
                y: center.y - hitDiameter / 2,
                width: hitDiameter,
                height: hitDiameter
            )
            overlayFrame = overlayFrame.map { $0.union(hitRect) } ?? hitRect

            return DesktopOverlayButton(
                kind: button.kind,
                actionElement: button.element,
                nativeFrame: button.appKitFrame,
                screenCenter: center,
                hitDiameter: hitDiameter
            )
        }

        guard var frame = overlayFrame else { return nil }
        frame = frame.insetBy(dx: -DesktopTrafficLightLayout.overlayPadding, dy: -DesktopTrafficLightLayout.overlayPadding).integral
        guard frame.width > 0, frame.height > 0 else { return nil }

        return DesktopOverlayDescriptor(
            windowID: candidate.windowID,
            ownerPID: candidate.ownerPID,
            bundleIdentifier: candidate.runningApplication.bundleIdentifier,
            ownerName: candidate.ownerName,
            axWindow: axWindow.element,
            overlayFrame: frame,
            buttons: buttons
        )
    }

    private func performAction(_ kind: DesktopTrafficLightKind, forWindowID windowID: CGWindowID) {
        guard let descriptor = freshDescriptorForAction(kind, windowID: windowID) else {
            return
        }

        let didPerform: Bool
        switch kind {
        case .close:
            didPerform = performCloseAction(for: descriptor)
        case .minimize:
            didPerform = pressButton(kind: .minimize, in: descriptor)
        case .fullScreen:
            didPerform = pressButton(kind: .fullScreen, in: descriptor)
        }

        if didPerform {
            if kind != .fullScreen {
                panelsByWindowID[windowID]?.closePanel()
                panelsByWindowID.removeValue(forKey: windowID)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + RefreshTiming.actionRefreshDelay) { [weak self] in
                self?.scheduleRefresh(immediate: true)
            }
        } else {
            NSSound.beep()
        }
    }

    private func freshDescriptorForAction(
        _ kind: DesktopTrafficLightKind,
        windowID: CGWindowID
    ) -> DesktopOverlayDescriptor? {
        guard
            let panel = panelsByWindowID[windowID],
            let previousDescriptor = panel.descriptor
        else {
            NSSound.beep()
            return nil
        }

        guard
            let freshDescriptor = collectOverlayDescriptors().first(
                where: {
                    $0.windowID == windowID
                        && $0.ownerPID == previousDescriptor.ownerPID
                }
            )
        else {
            panel.closePanel()
            panelsByWindowID.removeValue(forKey: windowID)
            scheduleRefresh(immediate: true)
            DWLog("Cancelled desktop traffic-light action because window \(windowID) is no longer available")
            return nil
        }

        guard
            buttonKind(
                atScreenPoint: NSEvent.mouseLocation,
                in: freshDescriptor
            ) == kind,
            descriptorsAreAlignedForAction(
                previousDescriptor,
                freshDescriptor,
                panelFrame: panel.frame
            )
        else {
            panel.configure(
                descriptor: freshDescriptor,
                targetDiameter: targetButtonDiameter,
                revealOnHover: settings.desktopTrafficLightsRevealOnHover,
                hoverEnlargementEnabled: settings.desktopTrafficLightHoverEnlargementEnabled
            )
            panel.order(.above, relativeTo: Int(freshDescriptor.windowID))
            panelsByWindowID[windowID] = panel
            DWLog("Cancelled stale desktop traffic-light action for moved window \(windowID)")
            return nil
        }

        return freshDescriptor
    }

    private func descriptorsAreAlignedForAction(
        _ previous: DesktopOverlayDescriptor,
        _ fresh: DesktopOverlayDescriptor,
        panelFrame: NSRect
    ) -> Bool {
        let tolerance: CGFloat = 1.5
        guard
            previous.windowID == fresh.windowID,
            previous.ownerPID == fresh.ownerPID,
            rect(panelFrame, isWithin: tolerance, of: previous.overlayFrame),
            rect(panelFrame, isWithin: tolerance, of: fresh.overlayFrame),
            previous.buttons.count == fresh.buttons.count
        else {
            return false
        }

        for kind in DesktopTrafficLightKind.allCases {
            let previousButton = previous.buttons.first(where: { $0.kind == kind })
            let freshButton = fresh.buttons.first(where: { $0.kind == kind })
            guard (previousButton == nil) == (freshButton == nil) else {
                return false
            }
            guard let previousButton, let freshButton else { continue }

            let previousLocalCenter = previousButton.localCenter(
                in: previous.overlayFrame
            )
            let displayedCenter = NSPoint(
                x: panelFrame.minX + previousLocalCenter.x,
                y: panelFrame.minY + previousLocalCenter.y
            )
            guard
                hypot(
                    displayedCenter.x - freshButton.screenCenter.x,
                    displayedCenter.y - freshButton.screenCenter.y
                ) <= tolerance,
                abs(previousButton.hitDiameter - freshButton.hitDiameter)
                    <= tolerance
            else {
                return false
            }
        }

        return true
    }

    private func buttonKind(
        atScreenPoint point: NSPoint,
        in descriptor: DesktopOverlayDescriptor
    ) -> DesktopTrafficLightKind? {
        descriptor.buttons
            .filter { button in
                NSRect(
                    x: button.screenCenter.x - button.hitDiameter / 2,
                    y: button.screenCenter.y - button.hitDiameter / 2,
                    width: button.hitDiameter,
                    height: button.hitDiameter
                ).contains(point)
            }
            .min { left, right in
                let leftDistance = hypot(
                    point.x - left.screenCenter.x,
                    point.y - left.screenCenter.y
                )
                let rightDistance = hypot(
                    point.x - right.screenCenter.x,
                    point.y - right.screenCenter.y
                )
                return leftDistance < rightDistance
            }?
            .kind
    }

    private func rect(
        _ left: NSRect,
        isWithin tolerance: CGFloat,
        of right: NSRect
    ) -> Bool {
        abs(left.minX - right.minX) <= tolerance
            && abs(left.minY - right.minY) <= tolerance
            && abs(left.width - right.width) <= tolerance
            && abs(left.height - right.height) <= tolerance
    }

    private func performCloseAction(for descriptor: DesktopOverlayDescriptor) -> Bool {
        let runningApplication = NSRunningApplication(processIdentifier: descriptor.ownerPID)
        let action = settings.desktopCloseAction(
            bundleIdentifier: descriptor.bundleIdentifier,
            hasRunningApplication: runningApplication?.isTerminated == false
        )

        switch action {
        case .quitApplication:
            guard let runningApplication, !runningApplication.isTerminated else { return false }
            return runningApplication.terminate()
        case .closeWindow:
            return pressButton(kind: .close, in: descriptor)
        }
    }

    private func pressButton(kind: DesktopTrafficLightKind, in descriptor: DesktopOverlayDescriptor) -> Bool {
        guard let button = descriptor.buttons.first(where: { $0.kind == kind }) else { return false }
        let error = AXUIElementPerformAction(button.actionElement, kAXPressAction as CFString)
        if error != .success {
            DWLog("Desktop traffic light AX press failed for window \(descriptor.windowID): \(error.rawValue)")
            return false
        }
        return true
    }

    private func isStandardAXWindow(_ axWindow: AXUIElement) -> Bool {
        guard (attribute(axWindow, DesktopAXAttributeNames.hidden) as Bool?) != true else { return false }

        if let role = attribute(axWindow, kAXRoleAttribute) as String?, role != kAXWindowRole {
            return false
        }

        if let subrole = attribute(axWindow, kAXSubroleAttribute) as String?, subrole != kAXStandardWindowSubrole {
            return false
        }

        return true
    }

    private func isLikelyFullScreen(candidate: DesktopCGWindowCandidate, axWindow: DesktopAXWindowSnapshot) -> Bool {
        if axWindow.isFullScreen { return true }

        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            let intersection = candidate.appKitBounds.intersection(screenFrame)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let screenCoverage = intersection.area / max(1, screenFrame.area)
            let windowCoverage = intersection.area / max(1, candidate.appKitBounds.area)
            if screenCoverage >= 0.985, windowCoverage >= 0.985 {
                return true
            }
        }

        return false
    }

    private func visibleArea(of rect: NSRect) -> CGFloat {
        NSScreen.screens.reduce(CGFloat(0)) { area, screen in
            let intersection = rect.intersection(screen.frame)
            guard !intersection.isNull, !intersection.isEmpty else { return area }
            return area + intersection.area
        }
    }

    private func uniqueAXWindows(_ windows: [AXUIElement]) -> [AXUIElement] {
        var buckets: [CFHashCode: [AXUIElement]] = [:]
        var unique: [AXUIElement] = []

        for window in windows {
            let hash = CFHash(window)
            let bucket = buckets[hash] ?? []
            guard !bucket.containsAXElement(window) else { continue }
            buckets[hash, default: []].append(window)
            unique.append(window)
        }

        return unique
    }

    private func explicitCGWindowID(of axWindow: AXUIElement) -> CGWindowID? {
        for attributeName in DesktopAXAttributeNames.possibleWindowIDs {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(axWindow, attributeName as CFString, &value)
            guard error == .success, let value else { continue }

            if let number = value as? NSNumber {
                return CGWindowID(number.uint32Value)
            }

            if let string = value as? String, let number = UInt32(string) {
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

private enum DesktopAXAttributeNames {
    static let fullScreenButton = "AXFullScreenButton"
    static let fullScreen = "AXFullScreen"
    static let hidden = "AXHidden"
    static let possibleWindowIDs = ["AXWindowID", "AXWindowNumber"]
}

private enum DesktopTrafficLightLayout {
    static let baseButtonDiameter: CGFloat = 14
    static let minimumButtonDiameter: CGFloat = 14
    static let maximumButtonDiameter: CGFloat = 30
    static let fixedHitDiameter: CGFloat = 38
    static let hitPadding: CGFloat = 5
    static let overlayPadding: CGFloat = 3
    static let revealAnimationDuration: TimeInterval = 0.08
    static let diameterAnimationDuration: TimeInterval = 0.09

    static func clampButtonDiameter(_ value: CGFloat) -> CGFloat {
        max(minimumButtonDiameter, min(maximumButtonDiameter, value))
    }
}

private enum DesktopTrafficLightKind: CaseIterable {
    case close
    case minimize
    case fullScreen

    var fillColor: NSColor {
        switch self {
        case .close:
            return NSColor(calibratedRed: 1.00, green: 0.37, blue: 0.34, alpha: 1)
        case .minimize:
            return NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.26, alpha: 1)
        case .fullScreen:
            return NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)
        }
    }

    var glyphColor: NSColor {
        switch self {
        case .close:
            return NSColor(calibratedWhite: 0.18, alpha: 0.74)
        case .minimize:
            return NSColor(calibratedWhite: 0.18, alpha: 0.68)
        case .fullScreen:
            return NSColor(calibratedWhite: 0.15, alpha: 0.72)
        }
    }

    var toolTip: String {
        switch self {
        case .close:
            return "关闭窗口"
        case .minimize:
            return "最小化窗口"
        case .fullScreen:
            return "全屏或缩放窗口"
        }
    }
}

private struct DesktopCGWindowCandidate {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let topLeftBounds: CGRect
    let appKitBounds: NSRect
    let runningApplication: NSRunningApplication
}

private struct DesktopAXWindowSnapshot {
    let element: AXUIElement
    let title: String
    let topLeftFrame: CGRect
    let appKitFrame: NSRect
    let explicitWindowID: CGWindowID?
    let isFullScreen: Bool
    let controls: [DesktopAXButtonSnapshot]
}

private struct DesktopAXButtonSnapshot {
    let kind: DesktopTrafficLightKind
    let element: AXUIElement
    let topLeftFrame: CGRect
    let appKitFrame: NSRect
}

private struct DesktopOverlayDescriptor {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let bundleIdentifier: String?
    let ownerName: String
    let axWindow: AXUIElement
    let overlayFrame: NSRect
    let buttons: [DesktopOverlayButton]
}

private struct DesktopOverlayButton {
    let kind: DesktopTrafficLightKind
    let actionElement: AXUIElement
    let nativeFrame: NSRect
    let screenCenter: NSPoint
    let hitDiameter: CGFloat

    func hitRect(in overlayFrame: NSRect) -> NSRect {
        let center = localCenter(in: overlayFrame)
        return NSRect(
            x: center.x - hitDiameter / 2,
            y: center.y - hitDiameter / 2,
            width: hitDiameter,
            height: hitDiameter
        )
    }

    func localCenter(in overlayFrame: NSRect) -> NSPoint {
        NSPoint(x: screenCenter.x - overlayFrame.minX, y: screenCenter.y - overlayFrame.minY)
    }
}

private final class DesktopTrafficLightPanel: NSPanel {
    var onButtonPressed: ((DesktopTrafficLightKind, CGWindowID) -> Void)?
    private(set) var descriptor: DesktopOverlayDescriptor?

    private let effectView = NSVisualEffectView()
    private let overlayView = DesktopTrafficLightOverlayView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .normal
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .transient
        ]
        isExcludedFromWindowsMenu = true
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        setupContent()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configure(
        descriptor: DesktopOverlayDescriptor,
        targetDiameter: CGFloat,
        revealOnHover: Bool,
        hoverEnlargementEnabled: Bool
    ) {
        self.descriptor = descriptor
        setFrame(descriptor.overlayFrame, display: false)
        effectView.frame = NSRect(origin: .zero, size: descriptor.overlayFrame.size)
        overlayView.frame = effectView.bounds
        overlayView.configure(descriptor: descriptor) { [weak self] kind in
            guard let self, let windowID = self.descriptor?.windowID else { return }
            self.onButtonPressed?(kind, windowID)
        }
        updateMouseLocation(
            NSEvent.mouseLocation,
            targetDiameter: targetDiameter,
            revealOnHover: revealOnHover,
            hoverEnlargementEnabled: hoverEnlargementEnabled,
            animated: false
        )
    }

    func updateMouseLocation(
        _ screenPoint: NSPoint,
        targetDiameter: CGFloat,
        revealOnHover: Bool,
        hoverEnlargementEnabled: Bool,
        animated: Bool = true
    ) {
        guard descriptor != nil else {
            ignoresMouseEvents = true
            return
        }

        let hoveredKind = overlayView.buttonKind(atScreenPoint: screenPoint, in: self)
        let isInControlRegion = overlayView.containsControlRegion(screenPoint: screenPoint, in: self)
        let shouldReveal = !revealOnHover || isInControlRegion
        ignoresMouseEvents = hoveredKind == nil

        overlayView.updateButtonState(
            revealed: shouldReveal,
            hoveredKind: hoveredKind,
            targetDiameter: targetDiameter,
            hoverEnlargementEnabled: hoverEnlargementEnabled,
            animated: animated
        )
    }

    func closePanel() {
        overlayView.invalidateAnimations()
        descriptor = nil
        orderOut(nil)
    }

    private func setupContent() {
        effectView.material = .titlebar
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.alphaValue = 0.94
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 8
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]

        overlayView.autoresizingMask = [.width, .height]
        effectView.addSubview(overlayView)
        contentView = effectView
    }
}

private final class DesktopTrafficLightOverlayView: NSView {
    private var descriptor: DesktopOverlayDescriptor?
    private var buttonViews: [DesktopTrafficLightKind: DesktopTrafficLightButtonView] = [:]
    private var onPress: ((DesktopTrafficLightKind) -> Void)?

    override var isOpaque: Bool { false }

    func configure(descriptor: DesktopOverlayDescriptor, onPress: @escaping (DesktopTrafficLightKind) -> Void) {
        self.descriptor = descriptor
        self.onPress = onPress

        let activeKinds = Set(descriptor.buttons.map(\.kind))
        for kind in DesktopTrafficLightKind.allCases where !activeKinds.contains(kind) {
            buttonViews[kind]?.removeFromSuperview()
            buttonViews.removeValue(forKey: kind)
        }

        for button in descriptor.buttons {
            let buttonView = buttonViews[button.kind] ?? DesktopTrafficLightButtonView(kind: button.kind)
            if buttonView.superview == nil {
                addSubview(buttonView)
            }
            buttonView.onPress = { [weak self, weak buttonView] kind, point in
                guard
                    let self,
                    let buttonView,
                    self.button(
                        atLocalPoint: self.convert(point, from: buttonView)
                    )?.kind == kind
                else {
                    return
                }
                self.onPress?(kind)
            }
            buttonView.frame = button.hitRect(in: descriptor.overlayFrame)
            buttonView.toolTip = button.kind.toolTip
            buttonViews[button.kind] = buttonView
        }

        needsDisplay = true
    }

    func updateButtonState(
        revealed: Bool,
        hoveredKind: DesktopTrafficLightKind?,
        targetDiameter: CGFloat,
        hoverEnlargementEnabled: Bool,
        animated: Bool
    ) {
        let clampedTarget = DesktopTrafficLightLayout.clampButtonDiameter(targetDiameter)
        for (kind, buttonView) in buttonViews {
            let isHovered = hoveredKind == kind
            let diameter = revealed && hoverEnlargementEnabled && isHovered
                ? clampedTarget
                : DesktopTrafficLightLayout.baseButtonDiameter
            buttonView.update(
                revealed: revealed,
                hovered: isHovered,
                diameter: diameter,
                animated: animated
            )
        }
    }

    func buttonKind(
        atScreenPoint screenPoint: NSPoint,
        in panel: NSPanel
    ) -> DesktopTrafficLightKind? {
        guard descriptor != nil else { return nil }
        let localPoint = point(screenPoint: screenPoint, in: panel)
        return button(atLocalPoint: localPoint)?.kind
    }

    func containsControlRegion(screenPoint: NSPoint, in panel: NSPanel) -> Bool {
        guard let descriptor else { return false }
        let localPoint = point(screenPoint: screenPoint, in: panel)
        let region = descriptor.buttons.reduce(NSRect.null) { partialResult, button in
            let hitRect = button.hitRect(in: descriptor.overlayFrame)
                .insetBy(dx: -DesktopTrafficLightLayout.overlayPadding, dy: -DesktopTrafficLightLayout.overlayPadding)
            return partialResult.isNull ? hitRect : partialResult.union(hitRect)
        }
        return !region.isNull && region.contains(localPoint)
    }

    func invalidateAnimations() {
        buttonViews.values.forEach { $0.invalidateAnimations() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard
            let button = button(atLocalPoint: point),
            let buttonView = buttonViews[button.kind]
        else {
            return nil
        }
        return buttonView.hitTest(convert(point, to: buttonView))
    }

    private func button(atLocalPoint point: NSPoint) -> DesktopOverlayButton? {
        guard let descriptor else { return nil }

        return descriptor.buttons
            .filter { button in
                button.hitRect(in: descriptor.overlayFrame).contains(point)
            }
            .min { left, right in
                let leftCenter = left.localCenter(in: descriptor.overlayFrame)
                let rightCenter = right.localCenter(in: descriptor.overlayFrame)
                let leftDistance = hypot(
                    point.x - leftCenter.x,
                    point.y - leftCenter.y
                )
                let rightDistance = hypot(
                    point.x - rightCenter.x,
                    point.y - rightCenter.y
                )
                return leftDistance < rightDistance
            }
    }

    private func point(screenPoint: NSPoint, in panel: NSPanel) -> NSPoint {
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        return convert(windowPoint, from: nil)
    }
}

private final class DesktopTrafficLightButtonView: NSButton {
    var onPress: ((DesktopTrafficLightKind, NSPoint) -> Void)?

    private let kind: DesktopTrafficLightKind
    private var renderedDiameter = DesktopTrafficLightLayout.baseButtonDiameter
    private var targetDiameter = DesktopTrafficLightLayout.baseButtonDiameter
    private var isCircleHovered = false
    private var isPressed = false
    private var diameterTimer: Timer?

    init(kind: DesktopTrafficLightKind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: DesktopTrafficLightLayout.fixedHitDiameter, height: DesktopTrafficLightLayout.fixedHitDiameter))
        title = ""
        isBordered = false
        wantsLayer = true
        alphaValue = 1
        toolTip = kind.toolTip
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isCircleHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isCircleHovered = false
        isPressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        isPressed = bounds.contains(localPoint)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let shouldPress = isPressed && bounds.contains(localPoint)
        isPressed = false
        needsDisplay = true
        if shouldPress {
            onPress?(kind, localPoint)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func update(revealed: Bool, hovered: Bool, diameter: CGFloat, animated: Bool) {
        isCircleHovered = hovered
        targetDiameter = DesktopTrafficLightLayout.clampButtonDiameter(diameter)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DesktopTrafficLightLayout.revealAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().alphaValue = revealed ? 1 : 0
            }
        } else {
            alphaValue = revealed ? 1 : 0
        }

        animateDiameter(to: targetDiameter, animated: animated)
    }

    func invalidateAnimations() {
        diameterTimer?.invalidate()
        diameterTimer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let diameter = min(renderedDiameter, min(bounds.width, bounds.height))
        let circleRect = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )

        if diameter > 1 {
            NSColor(calibratedWhite: 0, alpha: isPressed ? 0.22 : 0.13).setFill()
            NSBezierPath(ovalIn: circleRect.offsetBy(dx: 0, dy: -0.5)).fill()

            kind.fillColor.setFill()
            NSBezierPath(ovalIn: circleRect).fill()

            if isCircleHovered {
                NSColor.white.withAlphaComponent(0.16).setFill()
                NSBezierPath(ovalIn: circleRect).fill()

                NSColor.white.withAlphaComponent(0.42).setStroke()
                let ring = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.55, dy: 0.55))
                ring.lineWidth = 1
                ring.stroke()
            }

            if isPressed {
                NSColor.black.withAlphaComponent(0.13).setFill()
                NSBezierPath(ovalIn: circleRect).fill()
            }

            drawGlyph(in: circleRect)
        }
    }

    private func animateDiameter(to newDiameter: CGFloat, animated: Bool) {
        diameterTimer?.invalidate()
        diameterTimer = nil

        guard animated else {
            renderedDiameter = newDiameter
            needsDisplay = true
            return
        }

        let startDiameter = renderedDiameter
        let distance = newDiameter - startDiameter
        guard abs(distance) > 0.1 else {
            renderedDiameter = newDiameter
            needsDisplay = true
            return
        }

        let startTime = CACurrentMediaTime()
        let duration = DesktopTrafficLightLayout.diameterAnimationDuration
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(1, elapsed / duration)
            let eased = 1 - pow(1 - progress, 3)
            self.renderedDiameter = startDiameter + distance * CGFloat(eased)
            self.needsDisplay = true

            if progress >= 1 {
                self.renderedDiameter = newDiameter
                self.needsDisplay = true
                timer.invalidate()
                self.diameterTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diameterTimer = timer
    }

    private func drawGlyph(in rect: NSRect) {
        kind.glyphColor.setStroke()

        switch kind {
        case .close:
            let path = NSBezierPath()
            let inset = rect.width * 0.32
            path.lineWidth = max(1.0, rect.width * 0.085)
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
            path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
            path.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
            path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
            path.stroke()
        case .minimize:
            let path = NSBezierPath()
            let inset = rect.width * 0.30
            path.lineWidth = max(1.1, rect.width * 0.095)
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: rect.minX + inset, y: rect.midY))
            path.line(to: NSPoint(x: rect.maxX - inset, y: rect.midY))
            path.stroke()
        case .fullScreen:
            drawFullScreenGlyph(in: rect)
        }
    }

    private func drawFullScreenGlyph(in rect: NSRect) {
        let inset = rect.width * 0.29
        let midInset = rect.width * 0.47
        let path = NSBezierPath()
        path.lineWidth = max(1.0, rect.width * 0.075)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        path.move(to: NSPoint(x: rect.midX + rect.width * 0.03, y: rect.midY + rect.height * 0.14))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - midInset))
        path.move(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.line(to: NSPoint(x: rect.maxX - midInset, y: rect.maxY - inset))

        path.move(to: NSPoint(x: rect.midX - rect.width * 0.03, y: rect.midY - rect.height * 0.14))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.minY + midInset))
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.minX + midInset, y: rect.minY + inset))
        path.stroke()
    }
}

private struct DesktopScreenCoordinateMapper {
    private struct ScreenPair {
        let appKitFrame: NSRect
        let topLeftFrame: CGRect
    }

    private let screenPairs: [ScreenPair]

    init() {
        screenPairs = NSScreen.screens.compactMap { screen in
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            return ScreenPair(
                appKitFrame: screen.frame,
                topLeftFrame: CGDisplayBounds(displayID)
            )
        }
    }

    func appKitRect(fromTopLeftRect rect: CGRect) -> NSRect? {
        guard let screen = screenPair(containing: rect) else { return nil }
        let x = screen.appKitFrame.minX + (rect.minX - screen.topLeftFrame.minX)
        let yFromTop = rect.minY - screen.topLeftFrame.minY
        let y = screen.appKitFrame.maxY - yFromTop - rect.height
        return NSRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private func screenPair(containing rect: CGRect) -> ScreenPair? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let containing = screenPairs.first(where: { $0.topLeftFrame.contains(center) }) {
            return containing
        }

        return screenPairs.max { left, right in
            let leftArea = left.topLeftFrame.intersection(rect).safeArea
            let rightArea = right.topLeftFrame.intersection(rect).safeArea
            return leftArea < rightArea
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }

    var safeArea: CGFloat {
        area
    }

    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}

private extension Array where Element == AXUIElement {
    func containsAXElement(_ element: AXUIElement) -> Bool {
        contains { candidate in
            CFHash(candidate) == CFHash(element) && CFEqual(candidate, element)
        }
    }
}
