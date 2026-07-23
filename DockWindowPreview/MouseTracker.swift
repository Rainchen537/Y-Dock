import AppKit
import Foundation

struct DockPrimaryClickContext {
    let targetWasFrontmostBeforeClick: Bool
    let targetOwnedTopmostUserWindowBeforeClick: Bool
    let point: NSPoint
}

final class MouseTracker {
    var onHoverResolved: ((DockItem, NSPoint) -> Void)?
    var onDockHoverCandidateChanged: ((DockItem, Bool) -> Void)?
    var onMouseLeftDockAndPreview: (() -> Void)?
    var onDockContextMenuTrackingBegan: ((NSPoint) -> Void)?
    var onDockContextMenuInteractionEnded: (() -> Void)?
    var onDockPrimaryClick: ((DockItem, DockPrimaryClickContext) -> Void)?
    var isPointInsidePreviewPanel: ((NSPoint) -> Bool)?

    private let dockInspector: DockInspector
    private let windowCollector: WindowCollector
    private let settings: AppSettings
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var topmostSnapshotRefreshWorkItem: DispatchWorkItem?
    private var preClickTopmostSnapshots: [DockClickTopmostSnapshot] = []
    private var hoverWorkItem: DispatchWorkItem?
    private var leaveWorkItem: DispatchWorkItem?
    private var trailingMoveWorkItem: DispatchWorkItem?
    private var hitTestRetryWorkItem: DispatchWorkItem?
    private var currentHoverIdentity: String?
    private var currentHoverItem: DockItem?
    private var currentHoverPoint: NSPoint?
    private var lastObservedPoint: NSPoint?
    private var frontmostApplicationPIDAtLastPointerMove: pid_t?
    private var lastTopmostUserWindowSnapshotAt: TimeInterval = 0
    private var isInsideDockSnapshotRegionForTopmostSnapshot = false
    private var lastPointerMoveAt: TimeInterval = 0
    private var currentFrontmostApplicationPID: pid_t?
    private var previousFrontmostApplicationPID: pid_t?
    private var frontmostApplicationChangedAt: TimeInterval = 0
    private var lastSuccessfulHitAt: TimeInterval = 0
    private var unresolvedHoverStartedAt: TimeInterval?
    private var hitTestRetryDeadline: TimeInterval?
    private var lastDockPrimaryClickEventNumber: Int?
    private var lastDockPrimaryClickTimestamp: TimeInterval = -1
    private var lastDockPrimaryClickPoint = NSPoint(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude)
    private var lastHandledAt: TimeInterval = 0
    private let throttleInterval: TimeInterval = 0.035
    private let leaveDelay: TimeInterval = 0.120
    private let transientHitTestMissGrace: TimeInterval = 0.160
    private let hitTestRetryInterval: TimeInterval = 0.045
    private let maximumHitTestRetryDuration: TimeInterval = 0.55
    private let topmostSnapshotRefreshInterval: TimeInterval = 0.08

    init(
        dockInspector: DockInspector,
        windowCollector: WindowCollector,
        settings: AppSettings = .shared
    ) {
        self.dockInspector = dockInspector
        self.windowCollector = windowCollector
        self.settings = settings
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .rightMouseDown,
            .leftMouseDown,
            .otherMouseDown,
            .keyDown
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }

        currentFrontmostApplicationPID =
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        frontmostApplicationChangedAt = Date.timeIntervalSinceReferenceDate
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }
            self.recordFrontmostApplicationChange(to: app.processIdentifier)
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .appSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.primeDockClickEvidenceAtCurrentLocation()
        }
        primeDockClickEvidenceAtCurrentLocation()

        DWLog("MouseTracker started")
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        globalMonitor = nil
        localMonitor = nil
        workspaceActivationObserver = nil
        settingsObserver = nil
        resetPreClickTopmostSnapshots()
        cancelPendingHover()
        cancelPendingLeave()
        cancelTrailingMove()
        cancelHitTestRetry()
        clearHoverCandidate(cancelRetry: false)
        frontmostApplicationPIDAtLastPointerMove = nil
        lastTopmostUserWindowSnapshotAt = 0
        isInsideDockSnapshotRegionForTopmostSnapshot = false
        lastPointerMoveAt = 0
        currentFrontmostApplicationPID = nil
        previousFrontmostApplicationPID = nil
        frontmostApplicationChangedAt = 0
    }

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown:
            if !handleSecondaryMouseDown(at: NSEvent.mouseLocation) {
                onDockContextMenuInteractionEnded?()
            }
        case .leftMouseDown:
            onDockContextMenuInteractionEnded?()
            handlePrimaryMouseDown(event)
        case .otherMouseDown, .keyDown:
            onDockContextMenuInteractionEnded?()
        default:
            handleMouseMove(
                at: NSEvent.mouseLocation,
                eventTimestamp: event.timestamp
            )
        }
    }

    func refreshCurrentHover() {
        handleMouseMove(at: NSEvent.mouseLocation, forceHoverResolution: true)
    }

    private func primeDockClickEvidenceAtCurrentLocation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.primeDockClickEvidenceAtCurrentLocation()
            }
            return
        }

        guard settings.dockClickMinimizeMode != .off else {
            resetPreClickTopmostSnapshots()
            return
        }

        let now = Date.timeIntervalSinceReferenceDate
        if let observedFrontmostPID =
            NSWorkspace.shared.frontmostApplication?.processIdentifier,
           observedFrontmostPID != currentFrontmostApplicationPID {
            recordFrontmostApplicationChange(
                to: observedFrontmostPID,
                at: now
            )
        }

        let point = NSEvent.mouseLocation
        refreshTopmostSnapshotIfNeeded(
            point: point,
            region: dockInspector.dockRegion(containing: point),
            now: now
        )
    }

    private func recordFrontmostApplicationChange(
        to processIdentifier: pid_t,
        at changedAt: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard processIdentifier != currentFrontmostApplicationPID else {
            return
        }
        previousFrontmostApplicationPID = currentFrontmostApplicationPID
        currentFrontmostApplicationPID = processIdentifier
        frontmostApplicationChangedAt = changedAt
        resetPreClickTopmostSnapshots()
        scheduleTopmostSnapshotRefresh(
            for: processIdentifier,
            after:
                DockClickMinimizePolicy.minimumStableFrontmostActivationDuration
        )
    }

    private func handlePrimaryMouseDown(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let modifierFlags = event.modifierFlags
        let eventNumber = event.eventNumber
        let timestamp = event.timestamp

        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.handlePrimaryMouseDown(
                    at: point,
                    modifierFlags: modifierFlags,
                    eventNumber: eventNumber,
                    timestamp: timestamp
                )
            }
            return
        }

        handlePrimaryMouseDown(
            at: point,
            modifierFlags: modifierFlags,
            eventNumber: eventNumber,
            timestamp: timestamp
        )
    }

    private func handlePrimaryMouseDown(
        at point: NSPoint,
        modifierFlags: NSEvent.ModifierFlags,
        eventNumber: Int,
        timestamp: TimeInterval
    ) {
        let disallowedModifiers: NSEvent.ModifierFlags = [.control, .command, .option, .shift]
        guard modifierFlags.intersection(disallowedModifiers).isEmpty else { return }

        if eventNumber != 0, eventNumber == lastDockPrimaryClickEventNumber {
            return
        }
        if abs(timestamp - lastDockPrimaryClickTimestamp) < 0.01,
           hypot(point.x - lastDockPrimaryClickPoint.x, point.y - lastDockPrimaryClickPoint.y) < 0.5 {
            return
        }

        lastDockPrimaryClickEventNumber = eventNumber
        lastDockPrimaryClickTimestamp = timestamp
        lastDockPrimaryClickPoint = point

        guard
            let region = dockInspector.dockRegion(containing: point),
            region.frame.insetBy(dx: -6, dy: -6).contains(point),
            let item = dockInspector.applicationDockItem(at: point, in: region),
            let app = item.runningApplication,
            settings.dockClickMinimizeMode != .off
        else {
            return
        }

        let targetPID = app.processIdentifier
        let clickAt = eventReferenceTime(forEventTimestamp: timestamp)
        let frontmostDecision = DockClickMinimizePolicy.frontmostDecision(
            targetPID: targetPID,
            observedFrontmostPID:
                NSWorkspace.shared.frontmostApplication?.processIdentifier,
            trackedFrontmostPID: currentFrontmostApplicationPID,
            previousTrackedFrontmostPID: previousFrontmostApplicationPID,
            frontmostPIDAtLastPointerMove:
                frontmostApplicationPIDAtLastPointerMove,
            frontmostChangedAt: frontmostApplicationChangedAt,
            lastPointerMoveAt: lastPointerMoveAt,
            clickAt: clickAt
        )
        let preClickTopmostUserWindowOwnerPID: pid_t?
        if frontmostDecision.acceptedStableActivationAfterPointerMove {
            preClickTopmostUserWindowOwnerPID =
                DockClickMinimizePolicy.stableTopmostSnapshotOwnerPID(
                    targetPID: targetPID,
                    snapshots: preClickTopmostSnapshots,
                    frontmostChangedAt: frontmostApplicationChangedAt,
                    clickAt: clickAt
                )
        } else {
            preClickTopmostUserWindowOwnerPID =
                DockClickMinimizePolicy.recentTopmostSnapshotOwnerPID(
                    targetPID: targetPID,
                    snapshots: preClickTopmostSnapshots,
                    clickAt: clickAt
                )
        }
        let targetOwnedTopmostUserWindow =
            DockClickMinimizePolicy.targetOwnedTopmostUserWindowBeforeClick(
                targetPID: targetPID,
                observedTopmostUserWindowOwnerPID:
                    windowCollector.topmostUserWindowOwnerPID(),
                preClickTopmostUserWindowOwnerPID:
                    preClickTopmostUserWindowOwnerPID
            )
        onDockPrimaryClick?(
            item,
            DockPrimaryClickContext(
                targetWasFrontmostBeforeClick: frontmostDecision.isAccepted,
                targetOwnedTopmostUserWindowBeforeClick:
                    targetOwnedTopmostUserWindow,
                point: point
            )
        )
    }

    private func eventReferenceTime(
        forEventTimestamp timestamp: TimeInterval
    ) -> TimeInterval {
        let now = Date.timeIntervalSinceReferenceDate
        guard timestamp.isFinite, timestamp > 0 else { return now }

        let eventAge = ProcessInfo.processInfo.systemUptime - timestamp
        guard eventAge.isFinite, eventAge >= 0 else { return now }
        return now - eventAge
    }

    private func scheduleTopmostSnapshotRefresh(
        for processIdentifier: pid_t,
        after delay: TimeInterval
    ) {
        topmostSnapshotRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.topmostSnapshotRefreshWorkItem = nil
            self.capturePeriodicTopmostSnapshot(
                for: processIdentifier
            )
        }
        topmostSnapshotRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: workItem
        )
    }

    private func capturePeriodicTopmostSnapshot(
        for processIdentifier: pid_t
    ) {
        let now = Date.timeIntervalSinceReferenceDate
        guard
            settings.dockClickMinimizeMode != .off,
            currentFrontmostApplicationPID == processIdentifier,
            NSWorkspace.shared.frontmostApplication?.processIdentifier ==
                processIdentifier
        else {
            resetPreClickTopmostSnapshots()
            return
        }

        let stableDuration = now - frontmostApplicationChangedAt
        let remainingStableDuration =
            DockClickMinimizePolicy.minimumStableFrontmostActivationDuration
            - stableDuration
        if remainingStableDuration > 0 {
            scheduleTopmostSnapshotRefresh(
                for: processIdentifier,
                after: remainingStableDuration
            )
            return
        }

        let point = NSEvent.mouseLocation
        guard
            let region = dockInspector.dockRegion(containing: point),
            region.frame.insetBy(dx: -6, dy: -6).contains(point)
        else {
            resetPreClickTopmostSnapshots()
            return
        }

        captureTopmostSnapshot(at: now)
        scheduleTopmostSnapshotRefresh(
            for: processIdentifier,
            after: topmostSnapshotRefreshInterval
        )
    }

    private func captureTopmostSnapshot(at capturedAt: TimeInterval) {
        preClickTopmostSnapshots.append(
            DockClickTopmostSnapshot(
                ownerPID: windowCollector.topmostUserWindowOwnerPID(),
                capturedAt: capturedAt
            )
        )
        let oldestAllowedCapture = capturedAt
            - DockClickMinimizePolicy.maximumPreClickTopmostSnapshotAge
        preClickTopmostSnapshots.removeAll {
            $0.capturedAt < oldestAllowedCapture
        }
    }

    private func resetPreClickTopmostSnapshots() {
        topmostSnapshotRefreshWorkItem?.cancel()
        topmostSnapshotRefreshWorkItem = nil
        preClickTopmostSnapshots.removeAll(keepingCapacity: true)
        lastTopmostUserWindowSnapshotAt = 0
        isInsideDockSnapshotRegionForTopmostSnapshot = false
    }

    @discardableResult
    private func handleSecondaryMouseDown(at point: NSPoint) -> Bool {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.handleSecondaryMouseDown(at: point)
            }
            return true
        }

        guard let region = dockInspector.dockRegion(containing: point),
              region.frame.insetBy(dx: -6, dy: -6).contains(point)
        else {
            return false
        }

        cancelPendingLeave()
        onDockContextMenuTrackingBegan?(point)
        return true
    }

    private func handleMouseMove(
        at point: NSPoint,
        eventTimestamp: TimeInterval? = nil,
        forceHoverResolution: Bool = false,
        bypassThrottle: Bool = false
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.handleMouseMove(
                    at: point,
                    eventTimestamp: eventTimestamp,
                    forceHoverResolution: forceHoverResolution,
                    bypassThrottle: bypassThrottle
                )
            }
            return
        }

        lastObservedPoint = point
        let now = Date.timeIntervalSinceReferenceDate
        if let eventTimestamp {
            let pointerMoveAt = eventReferenceTime(
                forEventTimestamp: eventTimestamp
            )
            let observedFrontmostPID =
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            if let observedFrontmostPID,
               observedFrontmostPID != currentFrontmostApplicationPID {
                recordFrontmostApplicationChange(
                    to: observedFrontmostPID,
                    at: now
                )
            }
            frontmostApplicationPIDAtLastPointerMove =
                currentFrontmostApplicationPID ?? observedFrontmostPID
            lastPointerMoveAt = pointerMoveAt
        }
        let region = dockInspector.dockRegion(containing: point)
        let isInsideDockFrame = region?.frame.contains(point) == true
        refreshTopmostSnapshotIfNeeded(
            point: point,
            region: region,
            now: now
        )
        let isInsidePreviewProtection =
            isPointInsidePreviewPanel?(point) == true

        if !isInsideDockFrame, isInsidePreviewProtection {
            cancelPendingLeave()
            cancelTrailingMove()
            cancelHitTestRetry()
            return
        }

        if !forceHoverResolution,
           !bypassThrottle,
           now - lastHandledAt < throttleInterval {
            scheduleTrailingMove(
                after: throttleInterval - (now - lastHandledAt)
            )
            return
        }

        cancelTrailingMove()
        lastHandledAt = now
        resolveMousePosition(
            point,
            region: region,
            isInsidePreviewProtection: isInsidePreviewProtection,
            forceHoverResolution: forceHoverResolution,
            now: now
        )
    }

    private func refreshTopmostSnapshotIfNeeded(
        point: NSPoint,
        region: DockRegion?,
        now: TimeInterval
    ) {
        let isEnabled = settings.dockClickMinimizeMode != .off
        let isInsideSnapshotRegion =
            region?.frame.insetBy(dx: -6, dy: -6).contains(point) == true
        let shouldRefresh =
            DockClickMinimizePolicy.shouldRefreshTopmostSnapshot(
                isEnabled: isEnabled,
                isInsideSnapshotRegion: isInsideSnapshotRegion,
                wasInsideSnapshotRegion:
                    isInsideDockSnapshotRegionForTopmostSnapshot,
                now: now,
                lastSnapshotAt: lastTopmostUserWindowSnapshotAt,
                minimumInterval: throttleInterval
            )

        guard isEnabled, isInsideSnapshotRegion else {
            resetPreClickTopmostSnapshots()
            return
        }

        isInsideDockSnapshotRegionForTopmostSnapshot = true
        guard shouldRefresh else { return }

        captureTopmostSnapshot(at: now)
        lastTopmostUserWindowSnapshotAt = now
        if let processIdentifier = currentFrontmostApplicationPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier {
            scheduleTopmostSnapshotRefresh(
                for: processIdentifier,
                after: topmostSnapshotRefreshInterval
            )
        }
    }

    private func resolveMousePosition(
        _ point: NSPoint,
        region: DockRegion?,
        isInsidePreviewProtection: Bool,
        forceHoverResolution: Bool,
        now: TimeInterval
    ) {
        guard let region, region.frame.insetBy(dx: -6, dy: -6).contains(point) else {
            if isInsidePreviewProtection {
                cancelPendingLeave()
                return
            }
            clearHoverCandidate()
            scheduleLeave()
            return
        }

        guard let item = dockInspector.dockItem(at: point, in: region), item.runningApplication != nil else {
            if isInsidePreviewProtection {
                cancelPendingLeave()
                return
            }

            let wasWaitingForInitialHit = currentHoverIdentity == nil
            if wasWaitingForInitialHit, unresolvedHoverStartedAt == nil {
                unresolvedHoverStartedAt = now
            }
            let unresolvedStartedAt = unresolvedHoverStartedAt
            scheduleHitTestRetry()
            if currentHoverIdentity != nil,
               now - lastSuccessfulHitAt <= transientHitTestMissGrace {
                cancelPendingLeave()
                return
            }

            clearHoverCandidate(cancelRetry: false)
            if wasWaitingForInitialHit {
                unresolvedHoverStartedAt = unresolvedStartedAt
            }
            scheduleLeave()
            return
        }

        let unresolvedStartedAt = unresolvedHoverStartedAt
        unresolvedHoverStartedAt = nil
        cancelHitTestRetry()
        cancelPendingLeave()
        lastSuccessfulHitAt = now
        currentHoverPoint = point
        currentHoverItem = item

        if currentHoverIdentity == item.identity {
            if forceHoverResolution {
                cancelPendingHover()
                onHoverResolved?(item, point)
            }
            return
        }

        let hadPreviousHoverIdentity = currentHoverIdentity != nil
        currentHoverIdentity = item.identity
        onDockHoverCandidateChanged?(item, hadPreviousHoverIdentity)
        let unresolvedDuration = unresolvedStartedAt.map { max(0, now - $0) } ?? 0
        scheduleHover(
            for: item.identity,
            after: max(0, settings.hoverDelay - unresolvedDuration)
        )
    }

    private func scheduleHover(for identity: String, after delay: TimeInterval) {
        cancelPendingHover()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWorkItem = nil
            guard
                self.currentHoverIdentity == identity,
                let item = self.currentHoverItem,
                let point = self.currentHoverPoint
            else {
                return
            }

            if self.hitTestRetryWorkItem != nil ||
                Date.timeIntervalSinceReferenceDate - self.lastSuccessfulHitAt > self.transientHitTestMissGrace {
                self.scheduleHover(for: identity, after: self.hitTestRetryInterval)
                return
            }

            self.onHoverResolved?(item, point)
        }

        hoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleTrailingMove(after delay: TimeInterval) {
        trailingMoveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let point = self.lastObservedPoint else { return }
            self.trailingMoveWorkItem = nil
            self.handleMouseMove(at: point, bypassThrottle: true)
        }
        trailingMoveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, delay), execute: workItem)
    }

    private func cancelTrailingMove() {
        trailingMoveWorkItem?.cancel()
        trailingMoveWorkItem = nil
    }

    private func scheduleHitTestRetry() {
        let now = Date.timeIntervalSinceReferenceDate
        if hitTestRetryDeadline == nil {
            hitTestRetryDeadline = now + maximumHitTestRetryDuration
        }

        guard let deadline = hitTestRetryDeadline, now < deadline else {
            hitTestRetryDeadline = nil
            return
        }
        guard hitTestRetryWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let point = self.lastObservedPoint else { return }
            self.hitTestRetryWorkItem = nil
            self.handleMouseMove(at: point, bypassThrottle: true)
        }
        hitTestRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hitTestRetryInterval, execute: workItem)
    }

    private func cancelHitTestRetry() {
        hitTestRetryWorkItem?.cancel()
        hitTestRetryWorkItem = nil
        hitTestRetryDeadline = nil
    }

    private func clearHoverCandidate(cancelRetry: Bool = true) {
        currentHoverIdentity = nil
        currentHoverItem = nil
        currentHoverPoint = nil
        lastSuccessfulHitAt = 0
        unresolvedHoverStartedAt = nil
        cancelPendingHover()
        if cancelRetry {
            cancelHitTestRetry()
        }
    }

    private func cancelPendingHover() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
    }

    private func scheduleLeave() {
        guard leaveWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.leaveWorkItem = nil
            self?.onMouseLeftDockAndPreview?()
        }

        leaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + leaveDelay, execute: workItem)
    }

    private func cancelPendingLeave() {
        leaveWorkItem?.cancel()
        leaveWorkItem = nil
    }
}
