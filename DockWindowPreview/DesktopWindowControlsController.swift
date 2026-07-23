import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore

final class DesktopWindowControlsController {
    private enum RefreshTiming {
        static let timerInterval: TimeInterval = 0.45
        static let panelOcclusionInterval: TimeInterval = 1.0 / 30.0
        static let minimumRefreshInterval: CFTimeInterval = 0.16
        static let actionRefreshDelay: TimeInterval = 0.12
        static let nativeClickDownDelay: TimeInterval = 0.08
        static let nativeClickUpDelay: TimeInterval = 0.05
        static let nativeClickRefreshDelay: TimeInterval = 0.24
    }

    private enum OcclusionPolicy {
        // These accessory processes publish full-display bookkeeping windows
        // even when no visible surface covers the traffic-light point.
        static let systemBookkeepingBundleIdentifiers: Set<String> = [
            "com.apple.dock",
            "com.apple.notificationcenterui"
        ]
    }

    private struct OcclusionApplicationState {
        var participantPIDs = Set<pid_t>()
        var systemBookkeepingPIDs = Set<pid_t>()
    }

    private let settings: AppSettings
    private let descriptorRefreshQueue = DispatchQueue(
        label: "com.ydock.desktop-window-controls",
        qos: .userInitiated
    )
    private var isRunning = false
    private var refreshTimer: Timer?
    private var panelOcclusionTimer: Timer?
    private var pendingRefreshWorkItem: DispatchWorkItem?
    private var lastRefreshTimestamp: CFTimeInterval = 0
    private var lastPanelOcclusionTimestamp: CFTimeInterval = 0
    private var descriptorRefreshGeneration = 0
    private var isDescriptorRefreshInProgress = false
    private var shouldRefreshAfterCurrentDescriptorPass = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var panelsByWindowID: [CGWindowID: DesktopTrafficLightPanel] = [:]
    private var nativeClickSuppressedWindowIDs = Set<CGWindowID>()
    private var externalMouseButtonsDown = Set<Int>()

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
        descriptorRefreshGeneration += 1
        shouldRefreshAfterCurrentDescriptorPass = false

        pendingRefreshWorkItem?.cancel()
        pendingRefreshWorkItem = nil

        refreshTimer?.invalidate()
        refreshTimer = nil
        panelOcclusionTimer?.invalidate()
        panelOcclusionTimer = nil
        lastPanelOcclusionTimestamp = 0

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
        nativeClickSuppressedWindowIDs.removeAll()
        externalMouseButtonsDown.removeAll()
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
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
        updatePanels(at: screenLocation(for: event))

        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if isOverlayPanelEvent(event) {
                refreshPanelOcclusionStates(force: true)
            } else {
                beginExternalMouseInteraction(buttonNumber: event.buttonNumber)
            }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if !isOverlayPanelEvent(event) {
                beginExternalMouseInteraction(buttonNumber: event.buttonNumber)
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if !isOverlayPanelEvent(event) {
                removeAllPanels()
                externalMouseButtonsDown.remove(event.buttonNumber)
                if NSEvent.pressedMouseButtons == 0 {
                    externalMouseButtonsDown.removeAll()
                }
                if externalMouseButtonsDown.isEmpty {
                    scheduleRefresh(
                        immediate: true,
                        invalidatesCurrentPass: true
                    )
                }
            } else {
                scheduleRefresh(immediate: true)
            }
        case .mouseMoved:
            refreshPanelOcclusionStates()
        default:
            break
        }
    }

    private func isOverlayPanelEvent(_ event: NSEvent) -> Bool {
        event.window is DesktopTrafficLightButtonPanel
    }

    private func beginExternalMouseInteraction(buttonNumber: Int) {
        let wasInactive = externalMouseButtonsDown.isEmpty
        externalMouseButtonsDown.insert(buttonNumber)
        removeAllPanels()

        guard wasInactive else { return }
        descriptorRefreshGeneration += 1
        shouldRefreshAfterCurrentDescriptorPass = false
        pendingRefreshWorkItem?.cancel()
        pendingRefreshWorkItem = nil
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
            guard let self else { return }
            self.removeAllPanels()
            self.scheduleRefresh(immediate: true)
        })

        notificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.removeAllPanels()
            self.scheduleRefresh(
                immediate: false,
                invalidatesCurrentPass: true
            )
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

        let occlusionTimer = Timer(
            timeInterval: RefreshTiming.panelOcclusionInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshPanelOcclusionStates()
        }
        RunLoop.main.add(occlusionTimer, forMode: .common)
        panelOcclusionTimer = occlusionTimer
    }

    private func scheduleRefresh(
        immediate: Bool,
        invalidatesCurrentPass: Bool = false
    ) {
        guard isRunning else { return }
        guard externalMouseButtonsDown.isEmpty else { return }

        if isDescriptorRefreshInProgress,
            immediate || invalidatesCurrentPass {
            descriptorRefreshGeneration += 1
            shouldRefreshAfterCurrentDescriptorPass = true
        }

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
        guard externalMouseButtonsDown.isEmpty else {
            removeAllPanels()
            return
        }

        guard settings.requiresDesktopTrafficLightOverlay, AXIsProcessTrusted() else {
            descriptorRefreshGeneration += 1
            shouldRefreshAfterCurrentDescriptorPass = false
            removeAllPanels()
            return
        }

        guard !isDescriptorRefreshInProgress else {
            shouldRefreshAfterCurrentDescriptorPass = true
            return
        }

        let coordinateMapper = DesktopScreenCoordinateMapper()
        let candidates = collectVisibleCGWindowCandidates(
            coordinateMapper: coordinateMapper
        )
        let generation = descriptorRefreshGeneration
        isDescriptorRefreshInProgress = true

        descriptorRefreshQueue.async { [weak self] in
            guard let self else { return }
            let descriptors = self.collectOverlayDescriptors(
                candidates: candidates,
                coordinateMapper: coordinateMapper
            )
            DispatchQueue.main.async { [weak self] in
                self?.finishDescriptorRefresh(
                    descriptors,
                    generation: generation
                )
            }
        }
    }

    private func finishDescriptorRefresh(
        _ descriptors: [DesktopOverlayDescriptor],
        generation: Int
    ) {
        isDescriptorRefreshInProgress = false

        guard isRunning else {
            shouldRefreshAfterCurrentDescriptorPass = false
            return
        }

        guard externalMouseButtonsDown.isEmpty else {
            shouldRefreshAfterCurrentDescriptorPass = false
            return
        }

        guard generation == descriptorRefreshGeneration else {
            let shouldRefresh = shouldRefreshAfterCurrentDescriptorPass
                && settings.requiresDesktopTrafficLightOverlay
                && AXIsProcessTrusted()
            shouldRefreshAfterCurrentDescriptorPass = false
            if shouldRefresh {
                scheduleRefresh(immediate: true)
            }
            return
        }

        let currentWindowGeometries =
            currentVisibleCGWindowGeometries() ?? [:]
        let activeDescriptors = descriptors.filter { descriptor in
            guard
                !nativeClickSuppressedWindowIDs.contains(
                    descriptor.windowID
                ),
                let geometry = currentWindowGeometries[
                    descriptor.windowID
                ],
                geometry.ownerPID == descriptor.ownerPID
            else {
                return false
            }
            return rect(
                geometry.topLeftBounds,
                isWithin: 1.5,
                of: descriptor.windowTopLeftBounds
            )
        }
        let visibleWindowIDs = Set(activeDescriptors.map(\.windowID))

        for windowID in Array(panelsByWindowID.keys)
            where !visibleWindowIDs.contains(windowID) {
            panelsByWindowID[windowID]?.closePanel()
            panelsByWindowID.removeValue(forKey: windowID)
        }

        for descriptor in activeDescriptors {
            let panel = panelsByWindowID[descriptor.windowID]
                ?? makePanel(for: descriptor.windowID)
            panel.configure(
                descriptor: descriptor,
                targetDiameter: targetButtonDiameter,
                revealOnHover: settings.desktopTrafficLightsRevealOnHover,
                hoverEnlargementEnabled:
                    settings.desktopTrafficLightHoverEnlargementEnabled
            )
            panel.order(.above, relativeTo: Int(descriptor.windowID))
            panelsByWindowID[descriptor.windowID] = panel
        }

        // `configure` resets the active buttons before the next timer tick.
        // Re-evaluate WindowServer order in the same run-loop pass so a
        // newly configured back-window panel never flashes above its cover.
        refreshPanelOcclusionStates(force: true)

        if shouldRefreshAfterCurrentDescriptorPass {
            shouldRefreshAfterCurrentDescriptorPass = false
            scheduleRefresh(immediate: true)
        }
    }

    private func makePanel(for windowID: CGWindowID) -> DesktopTrafficLightPanel {
        let panel = DesktopTrafficLightPanel()
        panel.onButtonPressed = { [weak self] kind, targetWindowID, screenPoint in
            self?.performAction(
                kind,
                forWindowID: targetWindowID,
                atScreenPoint: screenPoint
            )
        }
        panelsByWindowID[windowID] = panel
        return panel
    }

    private func currentVisibleCGWindowGeometries()
        -> [CGWindowID: DesktopCGWindowGeometry]? {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        guard let rawWindows = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        var geometries: [CGWindowID: DesktopCGWindowGeometry] = [:]
        for dictionary in rawWindows {
            guard
                let ownerPID = dictionary[kCGWindowOwnerPID as String]
                    as? pid_t,
                let windowID = dictionary[kCGWindowNumber as String]
                    as? CGWindowID,
                let layer = dictionary[kCGWindowLayer as String] as? Int,
                layer == 0,
                (dictionary[kCGWindowIsOnscreen as String] as? Bool) == true,
                ((dictionary[kCGWindowAlpha as String] as? Double) ?? 1)
                    > 0.01,
                let boundsDictionary = dictionary[
                    kCGWindowBounds as String
                ] as? NSDictionary,
                let topLeftBounds = CGRect(
                    dictionaryRepresentation:
                        boundsDictionary as CFDictionary
                )
            else {
                continue
            }
            geometries[windowID] = DesktopCGWindowGeometry(
                ownerPID: ownerPID,
                topLeftBounds: topLeftBounds
            )
        }
        return geometries
    }

    private func removeAllPanels() {
        panelsByWindowID.values.forEach { $0.closePanel() }
        panelsByWindowID.removeAll()
    }

    private func updatePanelsForCurrentMouseLocation() {
        updatePanels(at: NSEvent.mouseLocation)
    }

    private func updatePanels(at mouseLocation: NSPoint) {
        guard isRunning else { return }
        for panel in panelsByWindowID.values {
            panel.updateMouseLocation(
                mouseLocation,
                targetDiameter: targetButtonDiameter,
                revealOnHover: settings.desktopTrafficLightsRevealOnHover,
                hoverEnlargementEnabled: settings.desktopTrafficLightHoverEnlargementEnabled
            )
        }
    }

    private func currentOcclusionApplicationState()
        -> OcclusionApplicationState {
        var state = OcclusionApplicationState()
        for application in NSWorkspace.shared.runningApplications
            where applicationParticipatesInOcclusion(application) {
            state.participantPIDs.insert(application.processIdentifier)
            if
                let bundleIdentifier = application.bundleIdentifier,
                OcclusionPolicy.systemBookkeepingBundleIdentifiers.contains(
                    bundleIdentifier
                )
            {
                state.systemBookkeepingPIDs.insert(
                    application.processIdentifier
                )
            }
        }
        return state
    }

    private func applicationParticipatesInOcclusion(
        _ application: NSRunningApplication?
    ) -> Bool {
        guard let application, !application.isTerminated else {
            return false
        }
        guard application.activationPolicy == .regular
            || application.activationPolicy == .accessory else {
            return false
        }
        return true
    }

    private func windowParticipatesInOcclusion(
        ownerPID: pid_t,
        layer: Int,
        topLeftBounds: CGRect,
        currentPID: pid_t,
        applicationState: OcclusionApplicationState,
        coordinateMapper: DesktopScreenCoordinateMapper
    ) -> Bool {
        let participates = layer == 0
            || applicationState.participantPIDs.contains(ownerPID)
            || ownerPID == currentPID
        guard participates else { return false }

        let isFullDisplaySystemBookkeepingWindow = layer != 0
            && applicationState.systemBookkeepingPIDs.contains(ownerPID)
            && coordinateMapper.nearlyCoversTopLeftScreen(topLeftBounds)
        return !isFullDisplaySystemBookkeepingWindow
    }

    private func refreshPanelOcclusionStates(force: Bool = false) {
        guard isRunning, !panelsByWindowID.isEmpty else { return }

        let now = CACurrentMediaTime()
        let hasVisibleEnhancement = panelsByWindowID.values.contains {
            $0.hasVisibleButtons
        }
        let requiredInterval = hasVisibleEnhancement
            ? RefreshTiming.panelOcclusionInterval
            : RefreshTiming.timerInterval
        guard force
            || now - lastPanelOcclusionTimestamp
                >= requiredInterval else {
            return
        }
        lastPanelOcclusionTimestamp = now

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let overlayWindowIDs = Set(
            panelsByWindowID.values.flatMap(\.windowIDs)
        )
        let applicationState = currentOcclusionApplicationState()
        let coordinateMapper = DesktopScreenCoordinateMapper()
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        guard let rawWindows = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            panelsByWindowID.values.forEach {
                $0.setUnoccludedKinds([])
            }
            updatePanelsForCurrentMouseLocation()
            return
        }

        var coveringTopLeftFrames: [CGRect] = []
        var unoccludedKindsByWindowID:
            [CGWindowID: Set<DesktopTrafficLightKind>] = [:]

        for dictionary in rawWindows {
            guard
                let ownerPID = dictionary[kCGWindowOwnerPID as String]
                    as? pid_t,
                let windowID = dictionary[kCGWindowNumber as String]
                    as? CGWindowID,
                let layer = dictionary[kCGWindowLayer as String] as? Int,
                (dictionary[kCGWindowIsOnscreen as String] as? Bool) == true,
                ((dictionary[kCGWindowAlpha as String] as? Double) ?? 1)
                    > 0.01,
                let boundsDictionary = dictionary[kCGWindowBounds as String]
                    as? NSDictionary,
                let topLeftBounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                ),
                topLeftBounds.width > 0,
                topLeftBounds.height > 0
            else {
                continue
            }

            if ownerPID == currentPID,
                overlayWindowIDs.contains(windowID) {
                continue
            }

            guard windowParticipatesInOcclusion(
                ownerPID: ownerPID,
                layer: layer,
                topLeftBounds: topLeftBounds,
                currentPID: currentPID,
                applicationState: applicationState,
                coordinateMapper: coordinateMapper
            ) else {
                continue
            }

            if let descriptor = panelsByWindowID[windowID]?.descriptor {
                let geometryIsCurrent = rect(
                    topLeftBounds,
                    isWithin: 1.5,
                    of: descriptor.windowTopLeftBounds
                )
                let kinds: [DesktopTrafficLightKind] = descriptor.buttons
                    .compactMap { button -> DesktopTrafficLightKind? in
                        guard geometryIsCurrent else { return nil }
                        return coveringTopLeftFrames.contains(where: {
                            $0.intersects(button.topLeftHitRect)
                        }) ? nil : button.kind
                    }
                unoccludedKindsByWindowID[windowID] = Set(kinds)
            }

            coveringTopLeftFrames.append(topLeftBounds)
        }

        for (windowID, panel) in panelsByWindowID {
            panel.setUnoccludedKinds(
                unoccludedKindsByWindowID[windowID] ?? []
            )
        }
        updatePanelsForCurrentMouseLocation()
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        guard let topLeftPoint = event.cgEvent?.location else {
            return NSEvent.mouseLocation
        }
        return DesktopScreenCoordinateMapper()
            .appKitPoint(fromTopLeftPoint: topLeftPoint)
            ?? NSEvent.mouseLocation
    }

    private var targetButtonDiameter: CGFloat {
        DesktopTrafficLightLayout.clampButtonDiameter(CGFloat(settings.desktopTrafficLightHoverTargetSize))
    }

    private func collectOverlayDescriptors(
        candidates: [DesktopCGWindowCandidate],
        coordinateMapper: DesktopScreenCoordinateMapper
    ) -> [DesktopOverlayDescriptor] {
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
                let loaded = loadAXWindowSnapshots(
                    ownerPID: candidate.ownerPID,
                    fallbackTitle: candidate.ownerName,
                    coordinateMapper: coordinateMapper
                )
                snapshotsByPID[candidate.ownerPID] = loaded
                snapshots = loaded
            }

            guard !snapshots.isEmpty else { continue }

            let usedAXWindows = usedAXWindowsByPID[candidate.ownerPID] ?? []
            guard let matchedSnapshot = bestAXWindowMatch(for: candidate, in: snapshots, excluding: usedAXWindows) else {
                continue
            }

            guard !isLikelyFullScreen(
                candidate: candidate,
                coordinateMapper: coordinateMapper
            ) else {
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
        let overlayWindowIDs = Set(
            panelsByWindowID.values.flatMap(\.windowIDs)
        )
        let runningApps = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        let occlusionApplicationState =
            currentOcclusionApplicationState()
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]

        if rawWindows == nil {
            DWLog("CGWindowListCopyWindowInfo returned no desktop window list")
        }

        var candidates: [DesktopCGWindowCandidate] = []
        var seenWindowIDs = Set<CGWindowID>()
        var coveringTopLeftFrames: [CGRect] = []

        for dictionary in rawWindows ?? [] {
            guard
                let ownerPID = dictionary[kCGWindowOwnerPID as String] as? pid_t,
                let windowID = dictionary[kCGWindowNumber as String] as? CGWindowID,
                !seenWindowIDs.contains(windowID),
                let layer = dictionary[kCGWindowLayer as String] as? Int,
                (dictionary[kCGWindowIsOnscreen as String] as? Bool) == true
            else {
                continue
            }

            let alpha = (dictionary[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0.01 else { continue }

            guard
                let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
                let topLeftBounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                ),
                topLeftBounds.width > 0,
                topLeftBounds.height > 0
            else {
                continue
            }

            seenWindowIDs.insert(windowID)
            if ownerPID == currentPID, overlayWindowIDs.contains(windowID) {
                continue
            }

            let app = runningApps[ownerPID]
            let framesAboveWindow = coveringTopLeftFrames
            if windowParticipatesInOcclusion(
                ownerPID: ownerPID,
                layer: layer,
                topLeftBounds: topLeftBounds,
                currentPID: currentPID,
                applicationState: occlusionApplicationState,
                coordinateMapper: coordinateMapper
            ) {
                coveringTopLeftFrames.append(topLeftBounds)
            }

            guard
                ownerPID != currentPID,
                layer == 0,
                let app,
                app.activationPolicy == .regular,
                !app.isTerminated,
                app.bundleIdentifier != currentBundleIdentifier,
                topLeftBounds.width >= 80,
                topLeftBounds.height >= 60,
                let appKitBounds = coordinateMapper.appKitRect(
                    fromTopLeftRect: topLeftBounds
                ),
                coordinateMapper.visibleArea(of: appKitBounds) >= 1600
            else {
                continue
            }

            let rawTitle = (dictionary[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ownerName = (dictionary[kCGWindowOwnerName as String] as? String)
                ?? app.localizedName
                ?? "Unknown App"
            let displayTitle = rawTitle?.isEmpty == false ? rawTitle! : ownerName

            candidates.append(DesktopCGWindowCandidate(
                windowID: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                title: displayTitle,
                topLeftBounds: topLeftBounds,
                appKitBounds: appKitBounds,
                bundleIdentifier: app.bundleIdentifier,
                coveringTopLeftFrames: framesAboveWindow
            ))
        }

        return candidates
    }

    private func loadAXWindowSnapshots(
        ownerPID: pid_t,
        fallbackTitle: String,
        coordinateMapper: DesktopScreenCoordinateMapper
    ) -> [DesktopAXWindowSnapshot] {
        let appElement = AXUIElementCreateApplication(ownerPID)
        AXUIElementSetMessagingTimeout(
            appElement,
            DesktopAXMessaging.requestTimeout
        )
        let axWindows = attribute(appElement, kAXWindowsAttribute)
            as [AXUIElement]? ?? []
        let uniqueWindows = uniqueAXWindows(axWindows)
        var snapshots: [DesktopAXWindowSnapshot] = []

        for axWindow in uniqueWindows {
            AXUIElementSetMessagingTimeout(
                axWindow,
                DesktopAXMessaging.requestTimeout
            )
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

            guard coordinateMapper.visibleArea(of: appKitFrame) >= 1600 else { continue }
            guard let controls = standardControls(for: axWindow, coordinateMapper: coordinateMapper) else { continue }

            let title = ((attribute(axWindow, kAXTitleAttribute) as String?) ?? fallbackTitle)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            snapshots.append(DesktopAXWindowSnapshot(
                element: axWindow,
                title: title,
                topLeftFrame: topLeftFrame,
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
            attributeName: kAXZoomButtonAttribute,
            coordinateMapper: coordinateMapper
        ) ?? buttonSnapshot(
            kind: .fullScreen,
            window: axWindow,
            attributeName: kAXFullScreenButtonAttribute,
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
        guard let element = attribute(window, attributeName) as AXUIElement? else {
            return nil
        }
        AXUIElementSetMessagingTimeout(
            element,
            DesktopAXMessaging.requestTimeout
        )
        guard
            (attribute(element, kAXHiddenAttribute) as Bool?)
                != true
        else {
            return nil
        }

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
        let visibleControls = axWindow.controls.filter { button in
            let nativeDiameter = max(
                button.topLeftFrame.width,
                button.topLeftFrame.height
            )
            let hitDiameter = max(
                fixedHitDiameter,
                nativeDiameter + DesktopTrafficLightLayout.hitPadding * 2
            )
            let hitFrame = CGRect(
                x: button.topLeftFrame.midX - hitDiameter / 2,
                y: button.topLeftFrame.midY - hitDiameter / 2,
                width: hitDiameter,
                height: hitDiameter
            )
            return !candidate.coveringTopLeftFrames.contains {
                $0.intersects(hitFrame)
            }
        }
        guard !visibleControls.isEmpty else { return nil }

        let buttons = visibleControls.map { button -> DesktopOverlayButton in
            let center = button.appKitFrame.center
            let nativeDiameter = max(
                button.appKitFrame.width,
                button.appKitFrame.height
            )
            let hitDiameter = max(
                fixedHitDiameter,
                nativeDiameter + DesktopTrafficLightLayout.hitPadding * 2
            )
            let topLeftHitRect = CGRect(
                x: button.topLeftFrame.midX - hitDiameter / 2,
                y: button.topLeftFrame.midY - hitDiameter / 2,
                width: hitDiameter,
                height: hitDiameter
            )
            return DesktopOverlayButton(
                kind: button.kind,
                actionElement: button.element,
                topLeftHitRect: topLeftHitRect,
                screenCenter: center,
                hitDiameter: hitDiameter
            )
        }

        return DesktopOverlayDescriptor(
            windowID: candidate.windowID,
            ownerPID: candidate.ownerPID,
            bundleIdentifier: candidate.bundleIdentifier,
            windowTopLeftBounds: candidate.topLeftBounds,
            axWindow: axWindow.element,
            buttons: buttons
        )
    }

    private func performAction(
        _ kind: DesktopTrafficLightKind,
        forWindowID windowID: CGWindowID,
        atScreenPoint screenPoint: NSPoint
    ) {
        guard let descriptor = freshDescriptorForAction(
            kind,
            windowID: windowID,
            screenPoint: screenPoint
        ) else {
            return
        }

        let didPerform: Bool
        switch kind {
        case .close:
            didPerform = performCloseAction(for: descriptor)
        case .minimize:
            didPerform = pressButton(kind: .minimize, in: descriptor)
        case .fullScreen:
            didPerform = clickNativeFullScreenButton(in: descriptor)
        }

        if didPerform {
            descriptorRefreshGeneration += 1
            if isDescriptorRefreshInProgress {
                shouldRefreshAfterCurrentDescriptorPass = true
            }
            panelsByWindowID[windowID]?.closePanel()
            panelsByWindowID.removeValue(forKey: windowID)
            DispatchQueue.main.asyncAfter(deadline: .now() + RefreshTiming.actionRefreshDelay) { [weak self] in
                self?.scheduleRefresh(immediate: true)
            }
        } else {
            NSSound.beep()
        }
    }

    private func freshDescriptorForAction(
        _ kind: DesktopTrafficLightKind,
        windowID: CGWindowID,
        screenPoint: NSPoint
    ) -> DesktopOverlayDescriptor? {
        guard
            let panel = panelsByWindowID[windowID],
            let previousDescriptor = panel.descriptor
        else {
            NSSound.beep()
            return nil
        }

        let coordinateMapper = DesktopScreenCoordinateMapper()
        let targetCandidates = collectVisibleCGWindowCandidates(
            coordinateMapper: coordinateMapper
        ).filter {
            $0.windowID == windowID
                && $0.ownerPID == previousDescriptor.ownerPID
        }
        guard
            let freshDescriptor = collectOverlayDescriptors(
                candidates: targetCandidates,
                coordinateMapper: coordinateMapper
            ).first
        else {
            panel.closePanel()
            panelsByWindowID.removeValue(forKey: windowID)
            scheduleRefresh(immediate: true)
            DWLog("Cancelled desktop traffic-light action because window \(windowID) is no longer available")
            return nil
        }

        guard
            buttonKind(
                atScreenPoint: screenPoint,
                in: freshDescriptor
            ) == kind,
            descriptorsAreAlignedForAction(
                previousDescriptor,
                freshDescriptor,
                panel: panel
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
            refreshPanelOcclusionStates(force: true)
            DWLog("Cancelled stale desktop traffic-light action for moved window \(windowID)")
            return nil
        }

        return freshDescriptor
    }

    private func descriptorsAreAlignedForAction(
        _ previous: DesktopOverlayDescriptor,
        _ fresh: DesktopOverlayDescriptor,
        panel: DesktopTrafficLightPanel
    ) -> Bool {
        let tolerance: CGFloat = 1.5
        guard
            previous.windowID == fresh.windowID,
            previous.ownerPID == fresh.ownerPID,
            rect(
                previous.windowTopLeftBounds,
                isWithin: tolerance,
                of: fresh.windowTopLeftBounds
            ),
            CFEqual(previous.axWindow, fresh.axWindow),
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
            guard let previousButton, let freshButton else {
                guard panel.frame(for: kind) == nil else { return false }
                continue
            }

            guard
                CFEqual(previousButton.actionElement, freshButton.actionElement),
                let displayedFrame = panel.frame(for: kind),
                rect(
                    displayedFrame,
                    isWithin: tolerance,
                    of: previousButton.screenHitRect.integral
                ),
                rect(
                    displayedFrame,
                    isWithin: tolerance,
                    of: freshButton.screenHitRect.integral
                )
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

    private func clickNativeFullScreenButton(
        in descriptor: DesktopOverlayDescriptor
    ) -> Bool {
        guard
            !nativeClickSuppressedWindowIDs.contains(descriptor.windowID),
            let button = descriptor.buttons.first(where: {
                $0.kind == .fullScreen
            }),
            let topLeftPoint = DesktopScreenCoordinateMapper()
                .topLeftPoint(fromAppKitPoint: button.screenCenter),
            let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: topLeftPoint,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: topLeftPoint,
                mouseButton: .left
            )
        else {
            return false
        }

        let windowID = descriptor.windowID
        nativeClickSuppressedWindowIDs.insert(windowID)
        DWLog(
            "Forwarding desktop green button click for window \(windowID) at \(topLeftPoint)"
        )
        DispatchQueue.main.asyncAfter(
            deadline: .now() + RefreshTiming.nativeClickDownDelay
        ) { [weak self] in
            guard let self else { return }
            guard self.canForwardNativeButtonClick(
                windowID: windowID,
                buttonElement: button.actionElement,
                atTopLeftPoint: topLeftPoint
            ) else {
                DWLog(
                    "Cancelled desktop green button forwarding because window \(windowID) moved or became covered"
                )
                self.finishNativeButtonForwarding(windowID: windowID)
                return
            }

            mouseDown.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + RefreshTiming.nativeClickUpDelay
            ) { [weak self] in
                mouseUp.post(tap: .cghidEventTap)
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + RefreshTiming.nativeClickRefreshDelay
                ) {
                    self?.finishNativeButtonForwarding(windowID: windowID)
                }
            }
        }
        return true
    }

    private func canForwardNativeButtonClick(
        windowID: CGWindowID,
        buttonElement: AXUIElement,
        atTopLeftPoint point: CGPoint
    ) -> Bool {
        let tolerance: CGFloat = 1.5
        guard
            isRunning,
            nativeClickSuppressedWindowIDs.contains(windowID),
            let currentButtonFrame = frame(of: buttonElement)
        else {
            return false
        }
        let currentCenter = CGPoint(
            x: currentButtonFrame.midX,
            y: currentButtonFrame.midY
        )
        guard hypot(
            currentCenter.x - point.x,
            currentCenter.y - point.y
        ) <= tolerance else {
            return false
        }

        guard topmostEligibleWindowID(atTopLeftPoint: point) == windowID else {
            return false
        }
        return accessibilityHitTestMatchesButton(
            buttonElement,
            atTopLeftPoint: point
        )
    }

    private func accessibilityHitTestMatchesButton(
        _ buttonElement: AXUIElement,
        atTopLeftPoint point: CGPoint
    ) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        )
        guard error == .success, let hitElement else {
            return false
        }

        var currentElement = hitElement
        for _ in 0..<6 {
            if CFEqual(currentElement, buttonElement) {
                return true
            }
            guard
                let parent = attribute(
                    currentElement,
                    kAXParentAttribute
                ) as AXUIElement?,
                !CFEqual(parent, currentElement)
            else {
                return false
            }
            currentElement = parent
        }
        return false
    }

    private func topmostEligibleWindowID(
        atTopLeftPoint point: CGPoint
    ) -> CGWindowID? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let overlayWindowIDs = Set(
            panelsByWindowID.values.flatMap(\.windowIDs)
        )
        let applicationState = currentOcclusionApplicationState()
        let coordinateMapper = DesktopScreenCoordinateMapper()
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        let rawWindows = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for dictionary in rawWindows {
            guard
                let ownerPID = dictionary[kCGWindowOwnerPID as String]
                    as? pid_t,
                let candidateWindowID = dictionary[
                    kCGWindowNumber as String
                ] as? CGWindowID,
                let layer = dictionary[kCGWindowLayer as String] as? Int,
                (dictionary[kCGWindowIsOnscreen as String] as? Bool) == true,
                ((dictionary[kCGWindowAlpha as String] as? Double) ?? 1)
                    > 0.01,
                let boundsDictionary = dictionary[
                    kCGWindowBounds as String
                ] as? NSDictionary,
                let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                ),
                bounds.contains(point)
            else {
                continue
            }

            if ownerPID == currentPID,
                overlayWindowIDs.contains(candidateWindowID) {
                continue
            }
            guard windowParticipatesInOcclusion(
                ownerPID: ownerPID,
                layer: layer,
                topLeftBounds: bounds,
                currentPID: currentPID,
                applicationState: applicationState,
                coordinateMapper: coordinateMapper
            ) else {
                continue
            }
            return candidateWindowID
        }

        return nil
    }

    private func finishNativeButtonForwarding(windowID: CGWindowID) {
        nativeClickSuppressedWindowIDs.remove(windowID)
        scheduleRefresh(immediate: true)
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
        guard (attribute(axWindow, kAXHiddenAttribute) as Bool?) != true else { return false }

        if let role = attribute(axWindow, kAXRoleAttribute) as String?, role != kAXWindowRole {
            return false
        }

        if let subrole = attribute(axWindow, kAXSubroleAttribute) as String?, subrole != kAXStandardWindowSubrole {
            return false
        }

        return true
    }

    private func isLikelyFullScreen(
        candidate: DesktopCGWindowCandidate,
        coordinateMapper: DesktopScreenCoordinateMapper
    ) -> Bool {
        for screenFrame in coordinateMapper.appKitScreenFrames {
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

private enum DesktopAXMessaging {
    static let requestTimeout: Float = 0.12
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
    let bundleIdentifier: String?
    let coveringTopLeftFrames: [CGRect]
}

private struct DesktopCGWindowGeometry {
    let ownerPID: pid_t
    let topLeftBounds: CGRect
}

private struct DesktopAXWindowSnapshot {
    let element: AXUIElement
    let title: String
    let topLeftFrame: CGRect
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
    let windowTopLeftBounds: CGRect
    let axWindow: AXUIElement
    let buttons: [DesktopOverlayButton]
}

private struct DesktopOverlayButton {
    let kind: DesktopTrafficLightKind
    let actionElement: AXUIElement
    let topLeftHitRect: CGRect
    let screenCenter: NSPoint
    let hitDiameter: CGFloat

    var screenHitRect: NSRect {
        NSRect(
            x: screenCenter.x - hitDiameter / 2,
            y: screenCenter.y - hitDiameter / 2,
            width: hitDiameter,
            height: hitDiameter
        )
    }
}

private final class DesktopTrafficLightPanel {
    var onButtonPressed: ((DesktopTrafficLightKind, CGWindowID, NSPoint) -> Void)?
    private(set) var descriptor: DesktopOverlayDescriptor?

    private var panelsByKind: [DesktopTrafficLightKind: DesktopTrafficLightButtonPanel] = [:]
    private var unoccludedKinds = Set<DesktopTrafficLightKind>()
    private var relativeWindowNumber: Int?

    var windowIDs: [CGWindowID] {
        panelsByKind.values.compactMap { panel in
            guard panel.windowNumber > 0 else { return nil }
            return CGWindowID(panel.windowNumber)
        }
    }

    var hasVisibleButtons: Bool {
        panelsByKind.values.contains { $0.isIntendedVisible }
    }

    func frame(for kind: DesktopTrafficLightKind) -> NSRect? {
        panelsByKind[kind]?.frame
    }

    func setUnoccludedKinds(_ kinds: Set<DesktopTrafficLightKind>) {
        let activeKinds = Set(descriptor?.buttons.map(\.kind) ?? [])
        unoccludedKinds = kinds.intersection(activeKinds)
    }

    func configure(
        descriptor: DesktopOverlayDescriptor,
        targetDiameter: CGFloat,
        revealOnHover: Bool,
        hoverEnlargementEnabled: Bool
    ) {
        self.descriptor = descriptor

        let activeKinds = Set(descriptor.buttons.map(\.kind))
        unoccludedKinds = activeKinds
        for kind in DesktopTrafficLightKind.allCases where !activeKinds.contains(kind) {
            panelsByKind.removeValue(forKey: kind)?.closePanel()
        }

        for button in descriptor.buttons {
            let panel = panelsByKind[button.kind]
                ?? DesktopTrafficLightButtonPanel(kind: button.kind)
            panel.configure(button: button) { [weak self] kind, screenPoint in
                guard let self, let windowID = self.descriptor?.windowID else {
                    return
                }
                self.onButtonPressed?(kind, windowID, screenPoint)
            }
            panelsByKind[button.kind] = panel
        }

        updateMouseLocation(
            NSEvent.mouseLocation,
            targetDiameter: targetDiameter,
            revealOnHover: revealOnHover,
            hoverEnlargementEnabled: hoverEnlargementEnabled,
            animated: false
        )
    }

    func order(
        _: NSWindow.OrderingMode,
        relativeTo otherWindowNumber: Int
    ) {
        relativeWindowNumber = otherWindowNumber
        panelsByKind.values.forEach {
            $0.refreshOrdering(relativeWindowNumber: otherWindowNumber)
        }
    }

    func updateMouseLocation(
        _ screenPoint: NSPoint,
        targetDiameter: CGFloat,
        revealOnHover: Bool,
        hoverEnlargementEnabled: Bool,
        animated: Bool = true
    ) {
        guard let descriptor else {
            panelsByKind.values.forEach { $0.closePanel() }
            return
        }

        let hoveredKind = buttonKind(
            atScreenPoint: screenPoint,
            in: descriptor
        )
        let shouldReveal = !revealOnHover
            || containsControlRegion(
                screenPoint: screenPoint,
                in: descriptor
            )
        let clampedTarget = DesktopTrafficLightLayout.clampButtonDiameter(
            targetDiameter
        )

        for (kind, panel) in panelsByKind {
            let isUnoccluded = unoccludedKinds.contains(kind)
            let isHovered = isUnoccluded && hoveredKind == kind
            let diameter = shouldReveal
                && hoverEnlargementEnabled
                && isHovered
                ? clampedTarget
                : DesktopTrafficLightLayout.baseButtonDiameter
            panel.update(
                revealed: shouldReveal && isUnoccluded,
                hovered: isHovered,
                diameter: diameter,
                animated: animated,
                relativeWindowNumber: relativeWindowNumber
            )
        }
    }

    func closePanel() {
        panelsByKind.values.forEach { $0.closePanel() }
        panelsByKind.removeAll()
        unoccludedKinds.removeAll()
        descriptor = nil
        relativeWindowNumber = nil
    }

    private func buttonKind(
        atScreenPoint point: NSPoint,
        in descriptor: DesktopOverlayDescriptor
    ) -> DesktopTrafficLightKind? {
        descriptor.buttons
            .filter { button in
                unoccludedKinds.contains(button.kind)
                    && button.screenHitRect.contains(point)
            }
            .min { left, right in
                hypot(
                    point.x - left.screenCenter.x,
                    point.y - left.screenCenter.y
                ) < hypot(
                    point.x - right.screenCenter.x,
                    point.y - right.screenCenter.y
                )
            }?
            .kind
    }

    private func containsControlRegion(
        screenPoint: NSPoint,
        in descriptor: DesktopOverlayDescriptor
    ) -> Bool {
        let region = descriptor.buttons
            .filter { unoccludedKinds.contains($0.kind) }
            .reduce(NSRect.null) { result, button in
            let hitRect = button.screenHitRect.insetBy(
                dx: -DesktopTrafficLightLayout.overlayPadding,
                dy: -DesktopTrafficLightLayout.overlayPadding
            )
            return result.isNull ? hitRect : result.union(hitRect)
        }
        return !region.isNull && region.contains(screenPoint)
    }
}

private final class DesktopTrafficLightButtonPanel: NSPanel {
    private let buttonView: DesktopTrafficLightButtonView
    private var shouldBeVisible = false

    var isIntendedVisible: Bool {
        shouldBeVisible
    }

    init(kind: DesktopTrafficLightKind) {
        buttonView = DesktopTrafficLightButtonView(kind: kind)
        super.init(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: DesktopTrafficLightLayout.fixedHitDiameter,
                height: DesktopTrafficLightLayout.fixedHitDiameter
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        contentView = buttonView
        buttonView.frame = contentView?.bounds ?? .zero
        buttonView.autoresizingMask = [.width, .height]
        level = .floating
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
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    func configure(
        button: DesktopOverlayButton,
        onPress: @escaping (DesktopTrafficLightKind, NSPoint) -> Void
    ) {
        setFrame(button.screenHitRect.integral, display: false)
        buttonView.onPress = { [weak self, weak buttonView] kind, localPoint in
            guard let self, let buttonView else { return }
            let windowPoint = buttonView.convert(localPoint, to: nil)
            let screenPoint = convertPoint(toScreen: windowPoint)
            onPress(kind, screenPoint)
        }
    }

    func update(
        revealed: Bool,
        hovered: Bool,
        diameter: CGFloat,
        animated: Bool,
        relativeWindowNumber: Int?
    ) {
        shouldBeVisible = revealed
        ignoresMouseEvents = !revealed || !hovered
        buttonView.update(
            revealed: revealed,
            hovered: hovered,
            diameter: diameter,
            animated: animated
        )
        refreshOrdering(relativeWindowNumber: relativeWindowNumber)
    }

    func closePanel() {
        buttonView.invalidateAnimations()
        shouldBeVisible = false
        ignoresMouseEvents = true
        orderOut(nil)
    }

    func refreshOrdering(relativeWindowNumber: Int?) {
        guard shouldBeVisible else {
            if isVisible {
                orderOut(nil)
            }
            return
        }

        if relativeWindowNumber != nil {
            orderFrontRegardless()
        }
    }
}

private final class DesktopTrafficLightButtonView: NSView {
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
    let appKitScreenFrames: [NSRect]

    init() {
        let pairs: [ScreenPair] = NSScreen.screens.compactMap {
            screen -> ScreenPair? in
            guard
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            return ScreenPair(
                appKitFrame: screen.frame,
                topLeftFrame: CGDisplayBounds(displayID)
            )
        }
        screenPairs = pairs
        appKitScreenFrames = pairs.map(\.appKitFrame)
    }

    func appKitRect(fromTopLeftRect rect: CGRect) -> NSRect? {
        guard let screen = screenPair(containing: rect) else { return nil }
        let x = screen.appKitFrame.minX + (rect.minX - screen.topLeftFrame.minX)
        let yFromTop = rect.minY - screen.topLeftFrame.minY
        let y = screen.appKitFrame.maxY - yFromTop - rect.height
        return NSRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    func appKitPoint(fromTopLeftPoint point: CGPoint) -> NSPoint? {
        guard let screen = screenPairs.first(where: {
            $0.topLeftFrame.contains(point)
        }) else {
            return nil
        }
        let x = screen.appKitFrame.minX + (point.x - screen.topLeftFrame.minX)
        let y = screen.appKitFrame.maxY - (point.y - screen.topLeftFrame.minY)
        return NSPoint(x: x, y: y)
    }

    func topLeftPoint(fromAppKitPoint point: NSPoint) -> CGPoint? {
        guard let screen = screenPairs.first(where: {
            $0.appKitFrame.contains(point)
        }) else {
            return nil
        }
        let x = screen.topLeftFrame.minX + (point.x - screen.appKitFrame.minX)
        let y = screen.topLeftFrame.minY + (screen.appKitFrame.maxY - point.y)
        return CGPoint(x: x, y: y)
    }

    func visibleArea(of rect: NSRect) -> CGFloat {
        appKitScreenFrames.reduce(CGFloat(0)) { area, screenFrame in
            let intersection = rect.intersection(screenFrame)
            guard !intersection.isNull, !intersection.isEmpty else {
                return area
            }
            return area + intersection.area
        }
    }

    func nearlyCoversTopLeftScreen(_ rect: CGRect) -> Bool {
        screenPairs.contains { pair in
            let intersection = pair.topLeftFrame.intersection(rect)
            guard !intersection.isNull, !intersection.isEmpty else {
                return false
            }
            return intersection.area / max(1, pair.topLeftFrame.area)
                >= 0.985
        }
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
