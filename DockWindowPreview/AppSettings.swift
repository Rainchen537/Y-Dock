import AppKit
import Foundation

extension Notification.Name {
    static let appSettingsChanged = Notification.Name("DockWindowPreview.appSettingsChanged")
}

final class AppSettings {
    static let shared = AppSettings()

    private enum Keys {
        static let hoverDelay = "hoverDelay"
        static let thumbnailHeight = "thumbnailHeight"
        static let showWindowTitles = "showWindowTitles"
        static let launchAtLogin = "launchAtLogin"
        static let debugLoggingEnabled = "debugLoggingEnabled"
        static let defaultsRevision = "defaultsRevision"
    }

    private let currentDefaultsRevision = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    var hoverDelay: TimeInterval {
        get { clamped(defaults.double(forKey: Keys.hoverDelay), min: 0.05, max: 0.8) }
        set { set(newValue, forKey: Keys.hoverDelay) }
    }

    var thumbnailHeight: CGFloat {
        get { CGFloat(clamped(defaults.double(forKey: Keys.thumbnailHeight), min: 100, max: 260)) }
        set { set(Double(newValue), forKey: Keys.thumbnailHeight) }
    }

    var thumbnailSize: NSSize {
        NSSize(width: thumbnailHeight * 1.6, height: thumbnailHeight)
    }

    func thumbnailSize(for window: WindowInfo) -> NSSize {
        let height = thumbnailHeight
        let aspectRatio = window.bounds.height > 0 ? window.bounds.width / window.bounds.height : 1.6
        let width = clamped(Double(height * aspectRatio), min: 120, max: 460)
        return NSSize(width: CGFloat(width), height: height)
    }

    var showWindowTitles: Bool {
        get { defaults.bool(forKey: Keys.showWindowTitles) }
        set { set(newValue, forKey: Keys.showWindowTitles) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { set(newValue, forKey: Keys.launchAtLogin) }
    }

    var debugLoggingEnabled: Bool {
        get { defaults.bool(forKey: Keys.debugLoggingEnabled) }
        set { set(newValue, forKey: Keys.debugLoggingEnabled) }
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.hoverDelay: 0.10,
            Keys.thumbnailHeight: 165.0,
            Keys.showWindowTitles: true,
            Keys.launchAtLogin: false,
            Keys.debugLoggingEnabled: false,
            Keys.defaultsRevision: 0
        ])
        migrateDefaultsIfNeeded()
    }

    private func migrateDefaultsIfNeeded() {
        let revision = defaults.integer(forKey: Keys.defaultsRevision)
        guard revision < currentDefaultsRevision else { return }

        let currentHeight = defaults.double(forKey: Keys.thumbnailHeight)
        if abs(currentHeight - 150.0) < 0.5 {
            defaults.set(165.0, forKey: Keys.thumbnailHeight)
        }

        defaults.set(currentDefaultsRevision, forKey: Keys.defaultsRevision)
    }

    private func set(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .appSettingsChanged, object: self)
    }

    private func clamped(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }
}

func DWLog(_ message: @autoclosure () -> String) {
    guard AppSettings.shared.debugLoggingEnabled else { return }
    NSLog("[DockWindowPreview] %@", message())
}
