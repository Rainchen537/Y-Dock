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
    private var hoverWorkItem: DispatchWorkItem?
    private var leaveWorkItem: DispatchWorkItem?
    private var trailingMoveWorkItem: DispatchWorkItem?
    private var hitTestRetryWorkItem: DispatchWorkItem?
    private var currentHoverIdentity: String?
    private var currentHoverItem: DockItem?
    private var currentHoverPoint: NSPoint?
    private var lastObservedPoint: NSPoint?
    private var frontmostApplicationPIDAtLastPointerMove: pid_t?
    private var topmostUserWindowOwnerPIDAtLastPointerMove: pid_t?
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

        currentFrontmostApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
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
        globalMonitor = nil
        localMonitor = nil
        workspaceActivationObserver = nil
        cancelPendingHover()
        cancelPendingLeave()
        cancelTrailingMove()
        cancelHitTestRetry()
        clearHoverCandidate(cancelRetry: false)
        frontmostApplicationPIDAtLastPointerMove = nil
        topmostUserWindowOwnerPIDAtLastPointerMove = nil
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
            handleMouseMove(at: NSEvent.mouseLocation)
        }
    }

    func refreshCurrentHover() {
        handleMouseMove(at: NSEvent.mouseLocation, forceHoverResolution: true)
    }

    private func recordFrontmostApplicationChange(to processIdentifier: pid_t) {
        guard processIdentifier != currentFrontmostApplicationPID else { return }
        previousFrontmostApplicationPID = currentFrontmostApplicationPID
        currentFrontmostApplicationPID = processIdentifier
        frontmostApplicationChangedAt = Date.timeIntervalSinceReferenceDate
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
        let targetWasFrontmost = DockClickMinimizePolicy.targetWasFrontmostBeforeClick(
            targetPID: targetPID,
            observedFrontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            trackedFrontmostPID: currentFrontmostApplicationPID,
            previousTrackedFrontmostPID: previousFrontmostApplicationPID,
            frontmostPIDAtLastPointerMove: frontmostApplicationPIDAtLastPointerMove,
            frontmostChangedAt: frontmostApplicationChangedAt,
            lastPointerMoveAt: lastPointerMoveAt
        )
        let targetOwnedTopmostUserWindow =
            DockClickMinimizePolicy.targetOwnedTopmostUserWindowBeforeClick(
                targetPID: targetPID,
                observedTopmostUserWindowOwnerPID:
                    windowCollector.topmostUserWindowOwnerPID(),
                topmostUserWindowOwnerPIDAtLastPointerMove:
                    topmostUserWindowOwnerPIDAtLastPointerMove
            )
        onDockPrimaryClick?(
            item,
            DockPrimaryClickContext(
                targetWasFrontmostBeforeClick: targetWasFrontmost,
                targetOwnedTopmostUserWindowBeforeClick:
                    targetOwnedTopmostUserWindow,
                point: point
            )
        )
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
        forceHoverResolution: Bool = false,
        bypassThrottle: Bool = false
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.handleMouseMove(
                    at: point,
                    forceHoverResolution: forceHoverResolution,
                    bypassThrottle: bypassThrottle
                )
            }
            return
        }

        lastObservedPoint = point
        let observedFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let observedFrontmostPID, observedFrontmostPID != currentFrontmostApplicationPID {
            recordFrontmostApplicationChange(to: observedFrontmostPID)
        }
        frontmostApplicationPIDAtLastPointerMove = currentFrontmostApplicationPID ?? observedFrontmostPID
        lastPointerMoveAt = Date.timeIntervalSinceReferenceDate
        let region = dockInspector.dockRegion(containing: point)
        let isInsideDockFrame = region?.frame.contains(point) == true
        let isInsideDockSnapshotRegion =
            region?.frame.insetBy(dx: -6, dy: -6).contains(point) == true
        if !isInsideDockSnapshotRegion || settings.dockClickMinimizeMode == .off {
            topmostUserWindowOwnerPIDAtLastPointerMove = nil
        }
        let isInsidePreviewProtection = isPointInsidePreviewPanel?(point) == true

        if !isInsideDockFrame, isInsidePreviewProtection {
            cancelPendingLeave()
            cancelTrailingMove()
            cancelHitTestRetry()
            return
        }

        let now = Date.timeIntervalSinceReferenceDate
        if !forceHoverResolution, !bypassThrottle, now - lastHandledAt < throttleInterval {
            scheduleTrailingMove(after: throttleInterval - (now - lastHandledAt))
            return
        }

        cancelTrailingMove()
        lastHandledAt = now
        if isInsideDockSnapshotRegion, settings.dockClickMinimizeMode != .off {
            topmostUserWindowOwnerPIDAtLastPointerMove =
                windowCollector.topmostUserWindowOwnerPID()
        }
        resolveMousePosition(
            point,
            region: region,
            isInsidePreviewProtection: isInsidePreviewProtection,
            forceHoverResolution: forceHoverResolution,
            now: now
        )
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
