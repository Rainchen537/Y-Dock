import AppKit
import Foundation

public enum YMonitoringFrameworkVersion {
    public static let current = "1.0.0"
}

public protocol YMonitoringLifecycle: AnyObject {
    @discardableResult
    func start() -> Bool
    func stop()
}

public enum YLocalEventDisposition {
    case passThrough
    case consume
}

public struct YNSEventMonitorDiagnostics {
    public let isRunning: Bool
    public let globalSubscriptionCount: Int
    public let localSubscriptionCount: Int
    public let subscribedGlobalMask: NSEvent.EventTypeMask
    public let subscribedLocalMask: NSEvent.EventTypeMask
    public let nativeGlobalMask: NSEvent.EventTypeMask
    public let nativeLocalMask: NSEvent.EventTypeMask
    public let nativeGlobalMonitorInstalled: Bool
    public let nativeLocalMonitorInstalled: Bool
}

public protocol YNSEventMonitorBackend: AnyObject {
    func addGlobalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    ) -> Any?

    func addLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any?

    func removeMonitor(_ monitor: Any)
}

public final class YSystemNSEventMonitorBackend: YNSEventMonitorBackend {
    public static let shared = YSystemNSEventMonitorBackend()

    private init() {}

    public func addGlobalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    ) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    public func addLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    public func removeMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }
}

public final class YMonitoringSubscription {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    fileprivate init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        lock.lock()
        let action = cancellation
        cancellation = nil
        lock.unlock()

        guard let action else { return }
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    deinit {
        cancel()
    }
}

public final class YNSEventMonitorHub: YMonitoringLifecycle {
    public typealias GlobalHandler = (NSEvent) -> Void
    public typealias LocalObserver = (NSEvent) -> Void
    public typealias LocalInterceptor = (NSEvent) -> YLocalEventDisposition

    private struct GlobalEntry {
        let mask: NSEvent.EventTypeMask
        let priority: Int
        let sequence: UInt64
        let handler: GlobalHandler
    }

    private struct LocalEntry {
        let mask: NSEvent.EventTypeMask
        let priority: Int
        let sequence: UInt64
        let handler: LocalObserver
    }

    private struct LocalInterceptorEntry {
        let mask: NSEvent.EventTypeMask
        let priority: Int
        let sequence: UInt64
        let handler: LocalInterceptor
    }

    private let backend: YNSEventMonitorBackend
    private var globalEntries: [UUID: GlobalEntry] = [:]
    private var localEntries: [UUID: LocalEntry] = [:]
    private var localInterceptorEntries: [UUID: LocalInterceptorEntry] = [:]
    private var orderedGlobalEntries: [GlobalEntry] = []
    private var orderedLocalEntries: [LocalEntry] = []
    private var orderedLocalInterceptorEntries: [LocalInterceptorEntry] = []
    private var nextSequence: UInt64 = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var nativeGlobalMask: NSEvent.EventTypeMask = []
    private var nativeLocalMask: NSEvent.EventTypeMask = []
    private var isRunning = false

    public init(
        backend: YNSEventMonitorBackend = YSystemNSEventMonitorBackend.shared
    ) {
        self.backend = backend
    }

    @discardableResult
    public func observeGlobal(
        matching mask: NSEvent.EventTypeMask,
        priority: Int = 0,
        handler: @escaping GlobalHandler
    ) -> YMonitoringSubscription {
        requireMainThread()
        precondition(!mask.isEmpty, "Global NSEvent subscriptions require a non-empty mask.")

        let identifier = UUID()
        let entry = GlobalEntry(
            mask: mask,
            priority: priority,
            sequence: makeSequence(),
            handler: handler
        )
        globalEntries[identifier] = entry
        rebuildOrderedGlobalEntries()
        ensureGlobalMonitorCoverage()

        return YMonitoringSubscription { [weak self] in
            self?.removeGlobalSubscription(identifier)
        }
    }

    @discardableResult
    public func observeLocal(
        matching mask: NSEvent.EventTypeMask,
        priority: Int = 0,
        handler: @escaping LocalObserver
    ) -> YMonitoringSubscription {
        requireMainThread()
        precondition(!mask.isEmpty, "Local NSEvent subscriptions require a non-empty mask.")

        let identifier = UUID()
        let entry = LocalEntry(
            mask: mask,
            priority: priority,
            sequence: makeSequence(),
            handler: handler
        )
        localEntries[identifier] = entry
        rebuildOrderedLocalEntries()
        ensureLocalMonitorCoverage()

        return YMonitoringSubscription { [weak self] in
            self?.removeLocalSubscription(identifier)
        }
    }

    @discardableResult
    public func interceptLocal(
        matching mask: NSEvent.EventTypeMask,
        priority: Int = 0,
        handler: @escaping LocalInterceptor
    ) -> YMonitoringSubscription {
        requireMainThread()
        precondition(!mask.isEmpty, "Local NSEvent interceptors require a non-empty mask.")

        let identifier = UUID()
        let entry = LocalInterceptorEntry(
            mask: mask,
            priority: priority,
            sequence: makeSequence(),
            handler: handler
        )
        localInterceptorEntries[identifier] = entry
        rebuildOrderedLocalInterceptorEntries()
        ensureLocalMonitorCoverage()

        return YMonitoringSubscription { [weak self] in
            self?.removeLocalInterceptor(identifier)
        }
    }

    @discardableResult
    public func start() -> Bool {
        requireMainThread()
        guard !isRunning else {
            return hasInstalledRequiredMonitors
        }

        isRunning = true
        ensureGlobalMonitorCoverage()
        ensureLocalMonitorCoverage()
        return hasInstalledRequiredMonitors
    }

    public func stop() {
        requireMainThread()
        guard isRunning || globalMonitor != nil || localMonitor != nil else {
            return
        }

        isRunning = false
        removeGlobalMonitor()
        removeLocalMonitor()
    }

    public var diagnostics: YNSEventMonitorDiagnostics {
        requireMainThread()
        return YNSEventMonitorDiagnostics(
            isRunning: isRunning,
            globalSubscriptionCount: globalEntries.count,
            localSubscriptionCount:
                localEntries.count + localInterceptorEntries.count,
            subscribedGlobalMask: subscribedGlobalMask,
            subscribedLocalMask: subscribedLocalMask,
            nativeGlobalMask: nativeGlobalMask,
            nativeLocalMask: nativeLocalMask,
            nativeGlobalMonitorInstalled: globalMonitor != nil,
            nativeLocalMonitorInstalled: localMonitor != nil
        )
    }

    private var hasInstalledRequiredMonitors: Bool {
        (subscribedGlobalMask.isEmpty || globalMonitor != nil)
            && (subscribedLocalMask.isEmpty || localMonitor != nil)
    }

    private var subscribedGlobalMask: NSEvent.EventTypeMask {
        globalEntries.values.reduce(into: NSEvent.EventTypeMask()) {
            $0.formUnion($1.mask)
        }
    }

    private var subscribedLocalMask: NSEvent.EventTypeMask {
        let observerMask = localEntries.values.reduce(
            into: NSEvent.EventTypeMask()
        ) {
            $0.formUnion($1.mask)
        }
        return localInterceptorEntries.values.reduce(into: observerMask) {
            $0.formUnion($1.mask)
        }
    }

    private func makeSequence() -> UInt64 {
        defer { nextSequence &+= 1 }
        return nextSequence
    }

    private func rebuildOrderedGlobalEntries() {
        orderedGlobalEntries = globalEntries.values.sorted(by: Self.isEarlier)
    }

    private func rebuildOrderedLocalEntries() {
        orderedLocalEntries = localEntries.values.sorted(by: Self.isEarlier)
    }

    private func rebuildOrderedLocalInterceptorEntries() {
        orderedLocalInterceptorEntries =
            localInterceptorEntries.values.sorted(by: Self.isEarlier)
    }

    private static func isEarlier(_ lhs: GlobalEntry, _ rhs: GlobalEntry) -> Bool {
        lhs.priority == rhs.priority
            ? lhs.sequence < rhs.sequence
            : lhs.priority < rhs.priority
    }

    private static func isEarlier(_ lhs: LocalEntry, _ rhs: LocalEntry) -> Bool {
        lhs.priority == rhs.priority
            ? lhs.sequence < rhs.sequence
            : lhs.priority < rhs.priority
    }

    private static func isEarlier(
        _ lhs: LocalInterceptorEntry,
        _ rhs: LocalInterceptorEntry
    ) -> Bool {
        lhs.priority == rhs.priority
            ? lhs.sequence < rhs.sequence
            : lhs.priority < rhs.priority
    }

    private func removeGlobalSubscription(_ identifier: UUID) {
        requireMainThread()
        guard globalEntries.removeValue(forKey: identifier) != nil else {
            return
        }
        rebuildOrderedGlobalEntries()
        if globalEntries.isEmpty {
            removeGlobalMonitor()
        }
    }

    private func removeLocalSubscription(_ identifier: UUID) {
        requireMainThread()
        guard localEntries.removeValue(forKey: identifier) != nil else {
            return
        }
        rebuildOrderedLocalEntries()
        if localEntries.isEmpty, localInterceptorEntries.isEmpty {
            removeLocalMonitor()
        }
    }

    private func removeLocalInterceptor(_ identifier: UUID) {
        requireMainThread()
        guard localInterceptorEntries.removeValue(forKey: identifier) != nil else {
            return
        }
        rebuildOrderedLocalInterceptorEntries()
        if localEntries.isEmpty, localInterceptorEntries.isEmpty {
            removeLocalMonitor()
        }
    }

    private func ensureGlobalMonitorCoverage() {
        guard isRunning else { return }
        let requestedMask = subscribedGlobalMask
        guard !requestedMask.isEmpty else {
            removeGlobalMonitor()
            return
        }
        guard globalMonitor == nil || !Self.contains(nativeGlobalMask, requestedMask) else {
            return
        }

        let previousMask = nativeGlobalMask
        let expandedMask = previousMask.union(requestedMask)
        removeGlobalMonitor()
        globalMonitor = backend.addGlobalMonitor(
            matching: expandedMask
        ) { [weak self] event in
            self?.dispatchGlobal(event)
        }

        if globalMonitor != nil {
            nativeGlobalMask = expandedMask
        } else if !previousMask.isEmpty {
            globalMonitor = backend.addGlobalMonitor(
                matching: previousMask
            ) { [weak self] event in
                self?.dispatchGlobal(event)
            }
            nativeGlobalMask = globalMonitor == nil ? [] : previousMask
        }
    }

    private func ensureLocalMonitorCoverage() {
        guard isRunning else { return }
        let requestedMask = subscribedLocalMask
        guard !requestedMask.isEmpty else {
            removeLocalMonitor()
            return
        }
        guard localMonitor == nil || !Self.contains(nativeLocalMask, requestedMask) else {
            return
        }

        let previousMask = nativeLocalMask
        let expandedMask = previousMask.union(requestedMask)
        removeLocalMonitor()
        localMonitor = backend.addLocalMonitor(
            matching: expandedMask
        ) { [weak self] event in
            guard let self else { return event }
            return self.dispatchLocal(event)
        }

        if localMonitor != nil {
            nativeLocalMask = expandedMask
        } else if !previousMask.isEmpty {
            localMonitor = backend.addLocalMonitor(
                matching: previousMask
            ) { [weak self] event in
                guard let self else { return event }
                return self.dispatchLocal(event)
            }
            nativeLocalMask = localMonitor == nil ? [] : previousMask
        }
    }

    private func removeGlobalMonitor() {
        if let globalMonitor {
            backend.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        nativeGlobalMask = []
    }

    private func removeLocalMonitor() {
        if let localMonitor {
            backend.removeMonitor(localMonitor)
        }
        localMonitor = nil
        nativeLocalMask = []
    }

    private func dispatchGlobal(_ event: NSEvent) {
        let eventMask = Self.mask(for: event.type)
        let snapshot = orderedGlobalEntries
        for entry in snapshot where !entry.mask.intersection(eventMask).isEmpty {
            entry.handler(event)
        }
    }

    private func dispatchLocal(_ event: NSEvent) -> NSEvent? {
        let eventMask = Self.mask(for: event.type)
        let observerSnapshot = orderedLocalEntries
        for entry in observerSnapshot
            where !entry.mask.intersection(eventMask).isEmpty {
            entry.handler(event)
        }

        let interceptorSnapshot = orderedLocalInterceptorEntries
        for entry in interceptorSnapshot
            where !entry.mask.intersection(eventMask).isEmpty {
            if entry.handler(event) == .consume {
                return nil
            }
        }
        return event
    }

    private static func mask(for type: NSEvent.EventType) -> NSEvent.EventTypeMask {
        let rawValue = UInt64(type.rawValue)
        guard rawValue < UInt64.bitWidth else { return [] }
        return NSEvent.EventTypeMask(rawValue: UInt64(1) << rawValue)
    }

    private static func contains(
        _ available: NSEvent.EventTypeMask,
        _ requested: NSEvent.EventTypeMask
    ) -> Bool {
        available.intersection(requested) == requested
    }

    private func requireMainThread() {
        precondition(
            Thread.isMainThread,
            "YNSEventMonitorHub lifecycle and subscription changes must run on the main thread."
        )
    }
}
