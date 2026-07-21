import AppKit
import Foundation

final class MouseTracker {
    var onHoverResolved: ((DockItem, NSPoint) -> Void)?
    var onDockHoverCandidateChanged: ((DockItem, Bool) -> Void)?
    var onMouseLeftDockAndPreview: (() -> Void)?
    var onDockContextMenuTrackingBegan: ((NSPoint) -> Void)?
    var onDockContextMenuInteractionEnded: (() -> Void)?
    var isPointInsidePreviewPanel: ((NSPoint) -> Bool)?

    private let dockInspector: DockInspector
    private let settings: AppSettings
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hoverWorkItem: DispatchWorkItem?
    private var leaveWorkItem: DispatchWorkItem?
    private var trailingMoveWorkItem: DispatchWorkItem?
    private var hitTestRetryWorkItem: DispatchWorkItem?
    private var currentHoverIdentity: String?
    private var currentHoverItem: DockItem?
    private var currentHoverPoint: NSPoint?
    private var lastObservedPoint: NSPoint?
    private var lastSuccessfulHitAt: TimeInterval = 0
    private var unresolvedHoverStartedAt: TimeInterval?
    private var hitTestRetryDeadline: TimeInterval?
    private var lastHandledAt: TimeInterval = 0
    private let throttleInterval: TimeInterval = 0.035
    private let leaveDelay: TimeInterval = 0.120
    private let transientHitTestMissGrace: TimeInterval = 0.160
    private let hitTestRetryInterval: TimeInterval = 0.045
    private let maximumHitTestRetryDuration: TimeInterval = 0.55

    init(dockInspector: DockInspector, settings: AppSettings = .shared) {
        self.dockInspector = dockInspector
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

        DWLog("MouseTracker started")
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        cancelPendingHover()
        cancelPendingLeave()
        cancelTrailingMove()
        cancelHitTestRetry()
        clearHoverCandidate(cancelRetry: false)
    }

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown:
            if !handleSecondaryMouseDown(at: NSEvent.mouseLocation) {
                onDockContextMenuInteractionEnded?()
            }
        case .leftMouseDown, .otherMouseDown, .keyDown:
            onDockContextMenuInteractionEnded?()
        default:
            handleMouseMove(at: NSEvent.mouseLocation)
        }
    }

    func refreshCurrentHover() {
        handleMouseMove(at: NSEvent.mouseLocation, forceHoverResolution: true)
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
        let region = dockInspector.dockRegion(containing: point)
        let isInsideDockFrame = region?.frame.contains(point) == true
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
