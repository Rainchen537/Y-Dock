import AppKit
import Foundation

private final class FakeMonitorToken {}

private final class FakeNSEventMonitorBackend: YNSEventMonitorBackend {
    private(set) var globalInstallMasks: [NSEvent.EventTypeMask] = []
    private(set) var localInstallMasks: [NSEvent.EventTypeMask] = []
    private(set) var removalCount = 0
    private(set) var globalHandler: ((NSEvent) -> Void)?
    private(set) var localHandler: ((NSEvent) -> NSEvent?)?

    func addGlobalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    ) -> Any? {
        globalInstallMasks.append(mask)
        globalHandler = handler
        return FakeMonitorToken()
    }

    func addLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        localInstallMasks.append(mask)
        localHandler = handler
        return FakeMonitorToken()
    }

    func removeMonitor(_ monitor: Any) {
        removalCount += 1
    }
}

@main
private enum YMonitoringFrameworkTests {
    static func main() {
        expect(
            YMonitoringFrameworkVersion.current == "1.0.0",
            "Unexpected monitoring framework version."
        )
        testSingleNativeMonitorAndFiltering()
        testLocalObserversRunBeforeConsumption()
        testCancellationUsesDispatchSnapshot()
        testStopAndRestart()
        print("YMonitoringFrameworkTests passed")
    }

    private static func testSingleNativeMonitorAndFiltering() {
        let backend = FakeNSEventMonitorBackend()
        let hub = YNSEventMonitorHub(backend: backend)
        var received: [String] = []

        let mouseToken = hub.observeGlobal(matching: .mouseMoved) { _ in
            received.append("mouse")
        }
        let keyToken = hub.observeGlobal(matching: .keyUp) { _ in
            received.append("key")
        }
        let localToken = hub.observeLocal(matching: .leftMouseDown) { _ in
            received.append("local")
        }

        expect(backend.globalInstallMasks.isEmpty, "Hub must not install before start().")
        expect(backend.localInstallMasks.isEmpty, "Hub must not install before start().")
        expect(hub.start(), "Hub should start with the fake backend.")
        expect(backend.globalInstallMasks.count == 1, "Global subscriptions must share one monitor.")
        expect(backend.localInstallMasks.count == 1, "Local subscriptions must share one monitor.")
        expect(
            backend.globalInstallMasks[0] == [.mouseMoved, .keyUp],
            "Global native mask must be the subscription union."
        )

        backend.globalHandler?(makeKeyEvent(type: .keyUp))
        expect(received == ["key"], "Global dispatch must filter by each subscription mask.")

        withExtendedLifetime([mouseToken, keyToken, localToken]) {}
    }

    private static func testLocalObserversRunBeforeConsumption() {
        let backend = FakeNSEventMonitorBackend()
        let hub = YNSEventMonitorHub(backend: backend)
        var order: [String] = []

        let lateObserver = hub.observeLocal(
            matching: .leftMouseDown,
            priority: 300
        ) { _ in
            order.append("observer-300")
        }
        let earlyObserver = hub.observeLocal(
            matching: .leftMouseDown,
            priority: 100
        ) { _ in
            order.append("observer-100")
        }
        let interceptor = hub.interceptLocal(
            matching: .leftMouseDown,
            priority: 200
        ) { _ in
            order.append("interceptor")
            return .consume
        }

        expect(hub.start(), "Hub should start with local subscriptions.")
        guard let localHandler = backend.localHandler else {
            fatalError("Local backend handler was not installed.")
        }
        let result = localHandler(makeMouseEvent(type: .leftMouseDown))
        expect(result == nil, "A consuming interceptor must return nil to AppKit.")
        expect(
            order == ["observer-100", "observer-300", "interceptor"],
            "All observers must run in stable order before interception."
        )

        withExtendedLifetime([lateObserver, earlyObserver, interceptor]) {}
    }

    private static func testCancellationUsesDispatchSnapshot() {
        let backend = FakeNSEventMonitorBackend()
        let hub = YNSEventMonitorHub(backend: backend)
        var order: [String] = []
        var secondToken: YMonitoringSubscription?

        let firstToken = hub.observeLocal(
            matching: .rightMouseDown,
            priority: 100
        ) { _ in
            order.append("first")
            secondToken?.cancel()
        }
        secondToken = hub.observeLocal(
            matching: .rightMouseDown,
            priority: 200
        ) { _ in
            order.append("second")
        }

        expect(hub.start(), "Hub should start for cancellation testing.")
        _ = backend.localHandler?(makeMouseEvent(type: .rightMouseDown))
        expect(
            order == ["first", "second"],
            "The current event must use a stable subscription snapshot."
        )

        order.removeAll()
        _ = backend.localHandler?(makeMouseEvent(type: .rightMouseDown))
        expect(order == ["first"], "A cancelled subscription must not receive later events.")

        withExtendedLifetime(firstToken) {}
    }

    private static func testStopAndRestart() {
        let backend = FakeNSEventMonitorBackend()
        let hub = YNSEventMonitorHub(backend: backend)
        let globalToken = hub.observeGlobal(matching: .flagsChanged) { _ in }
        let localToken = hub.observeLocal(matching: .flagsChanged) { _ in }

        expect(hub.start(), "Initial start should succeed.")
        expect(hub.start(), "Repeated start should be idempotent.")
        expect(backend.globalInstallMasks.count == 1, "Repeated start must not duplicate global monitors.")
        expect(backend.localInstallMasks.count == 1, "Repeated start must not duplicate local monitors.")

        hub.stop()
        expect(backend.removalCount == 2, "Stop must remove the global and local monitors.")
        expect(hub.start(), "Restart should reinstall retained subscriptions.")
        expect(backend.globalInstallMasks.count == 2, "Restart must reinstall one global monitor.")
        expect(backend.localInstallMasks.count == 2, "Restart must reinstall one local monitor.")

        globalToken.cancel()
        globalToken.cancel()
        localToken.cancel()
        expect(
            backend.removalCount == 4,
            "Removing the final subscriptions must remove both native monitors exactly once."
        )
    }

    private static func makeMouseEvent(type: NSEvent.EventType) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else {
            fatalError("Unable to create mouse event.")
        }
        return event
    }

    private static func makeKeyEvent(type: NSEvent.EventType) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 48
        ) else {
            fatalError("Unable to create key event.")
        }
        return event
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() {
            fatalError(message)
        }
    }
}
