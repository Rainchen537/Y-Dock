import AppKit
import Foundation

final class MouseTracker {
    var onHoverResolved: ((DockItem, NSPoint) -> Void)?
    var onDockHoverCandidateChanged: ((DockItem, Bool) -> Void)?
    var onMouseLeftDockAndPreview: (() -> Void)?
    var onSecondaryClickInDock: (() -> Void)?
    var isPointInsidePreviewPanel: ((NSPoint) -> Bool)?

    private let dockInspector: DockInspector
    private let settings: AppSettings
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hoverWorkItem: DispatchWorkItem?
    private var leaveWorkItem: DispatchWorkItem?
    private var currentHoverIdentity: String?
    private var lastHandledAt: TimeInterval = 0
    private let throttleInterval: TimeInterval = 0.035
    private let leaveDelay: TimeInterval = 0.120

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
            .rightMouseDown
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
    }

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown:
            handleSecondaryMouseDown(at: NSEvent.mouseLocation)
        default:
            handleMouseMove(at: NSEvent.mouseLocation)
        }
    }

    private func handleSecondaryMouseDown(at point: NSPoint) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.handleSecondaryMouseDown(at: point)
            }
            return
        }

        guard let region = dockInspector.dockRegion(containing: point),
              region.frame.insetBy(dx: -6, dy: -6).contains(point)
        else {
            return
        }

        currentHoverIdentity = nil
        cancelPendingHover()
        cancelPendingLeave()
        onSecondaryClickInDock?()
    }

    private func handleMouseMove(at point: NSPoint) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.handleMouseMove(at: point)
            }
            return
        }

        let region = dockInspector.dockRegion(containing: point)
        let isInsideDockFrame = region?.frame.contains(point) == true
        let isInsidePreviewProtection = isPointInsidePreviewPanel?(point) == true

        if !isInsideDockFrame, isInsidePreviewProtection {
            cancelPendingLeave()
            return
        }

        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastHandledAt >= throttleInterval else { return }
        lastHandledAt = now

        guard let region, region.frame.insetBy(dx: -6, dy: -6).contains(point) else {
            if isInsidePreviewProtection {
                cancelPendingLeave()
                return
            }
            currentHoverIdentity = nil
            cancelPendingHover()
            scheduleLeave()
            return
        }

        guard let item = dockInspector.dockItem(at: point, in: region), item.runningApplication != nil else {
            if isInsidePreviewProtection {
                cancelPendingLeave()
                return
            }
            currentHoverIdentity = nil
            cancelPendingHover()
            scheduleLeave()
            return
        }

        cancelPendingLeave()
        guard currentHoverIdentity != item.identity else { return }
        let hadPreviousHoverIdentity = currentHoverIdentity != nil
        currentHoverIdentity = item.identity
        onDockHoverCandidateChanged?(item, hadPreviousHoverIdentity)
        scheduleHover(for: item, at: point)
    }

    private func scheduleHover(for item: DockItem, at point: NSPoint) {
        cancelPendingHover()

        let workItem = DispatchWorkItem { [weak self] in
            guard self?.currentHoverIdentity == item.identity else { return }
            self?.onHoverResolved?(item, point)
        }

        hoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.hoverDelay, execute: workItem)
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
