import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum ScreenCapturePermissionState: Equatable {
    case missing
    case restartRequired
    case active
}

final class PermissionsManager {
    private struct ResetError: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private let defaults: UserDefaults
    private let initialGuidanceKey = "didShowInitialPermissionGuidance"
    private let screenCaptureRestartPendingKey = "screenCaptureRestartPending"
    private let installedApplicationPath = "/Applications/Y-Dock.app"
    private let bundleIdentifier = "com.lixingchen.DockWindowPreview"
    private let teamIdentifier = "A94225N8T5"
    private var screenCaptureMayNeedRestart: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        screenCaptureMayNeedRestart = ProcessInfo.processInfo.environment["Y_SETTINGS_PREVIEW_SCREEN_CAPTURE_RESTART"] == "1"

        if defaults.bool(forKey: screenCaptureRestartPendingKey) {
            defaults.removeObject(forKey: screenCaptureRestartPendingKey)
        }
    }

    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func screenCapturePermissionState() -> ScreenCapturePermissionState {
        if ProcessInfo.processInfo.environment["Y_SETTINGS_PREVIEW_SCREEN_CAPTURE_RESTART"] == "1" {
            return .restartRequired
        }
        if CGPreflightScreenCaptureAccess() {
            clearScreenCaptureRestartState()
            return .active
        }
        return screenCaptureMayNeedRestart ? .restartRequired : .missing
    }

    func isScreenCaptureTrusted() -> Bool {
        screenCapturePermissionState() == .active
    }

    @discardableResult
    func requestScreenCapturePermission() -> ScreenCapturePermissionState {
        let granted = CGRequestScreenCaptureAccess()
        if granted && !CGPreflightScreenCaptureAccess() {
            markScreenCaptureMayNeedRestart()
        }
        return screenCapturePermissionState()
    }

    @discardableResult
    func requestMissingPrivacyPermissions() -> Bool {
        if !isAccessibilityTrusted() {
            _ = requestAccessibilityPermission()
        }

        if screenCapturePermissionState() == .missing {
            _ = requestScreenCapturePermission()
        }

        return isAccessibilityTrusted() && screenCapturePermissionState() == .active
    }

    func showInitialPermissionGuidanceIfNeeded() {
        let hasAccessibility = isAccessibilityTrusted()
        let screenCaptureState = screenCapturePermissionState()
        guard !hasAccessibility || screenCaptureState != .active else { return }
        guard !defaults.bool(forKey: initialGuidanceKey) else { return }
        defaults.set(true, forKey: initialGuidanceKey)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "\(AppBranding.displayName) 需要权限"
            alert.informativeText = """
            请在 System Settings → Privacy & Security 中开启：

            • Accessibility：用于读取 Dock 和聚焦窗口
            • Screen & System Audio Recording：用于生成窗口缩略图

            屏幕录制授权后需要重启 Y-Dock 才会对当前进程生效。请始终从 /Applications 启动正式签名副本。
            """
            alert.addButton(withTitle: "打开辅助功能")
            alert.addButton(withTitle: "打开屏幕录制")
            alert.addButton(withTitle: "稍后")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                _ = self.requestAccessibilityPermission()
                self.openAccessibilitySettings()
            case .alertSecondButtonReturn:
                _ = self.requestScreenCapturePermission()
                self.openScreenCaptureSettings()
            default:
                break
            }
        }
    }

    func openAccessibilitySettings() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenCaptureSettings() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func relaunchInstalledApplication() {
        do {
            try YSettingRuntimeIdentity.relaunchInstalledApplication(
                atPath: installedApplicationPath,
                expectedBundleIdentifier: bundleIdentifier,
                expectedTeamIdentifier: teamIdentifier
            )
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法切换到正式安装版"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func isRunningInstalledCopy() -> Bool {
        YSettingRuntimeIdentity.isSignedInstalledCopy(
            expectedPath: installedApplicationPath,
            expectedTeamIdentifier: teamIdentifier,
            expectedBundleIdentifier: bundleIdentifier
        )
    }

    func hasValidInstalledApplication() -> Bool {
        YSettingRuntimeIdentity.isValidSignedApplication(
            atPath: installedApplicationPath,
            expectedBundleIdentifier: bundleIdentifier,
            expectedTeamIdentifier: teamIdentifier
        )
    }

    func resetPrivacyPermissions() throws {
        for service in ["Accessibility", "ScreenCapture"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleIdentifier]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            try waitForProcess(process, timeout: 10)

            guard process.terminationStatus == 0 else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ResetError(message: message?.isEmpty == false ? message! : "刷新 \(service) 权限记录失败。")
            }
        }
    }

    func didResetPrivacyPermissions() {
        clearScreenCaptureRestartState()
        defaults.set(false, forKey: initialGuidanceKey)
    }

    private func markScreenCaptureMayNeedRestart() {
        screenCaptureMayNeedRestart = true
        defaults.set(true, forKey: screenCaptureRestartPendingKey)
    }

    private func clearScreenCaptureRestartState() {
        screenCaptureMayNeedRestart = false
        defaults.removeObject(forKey: screenCaptureRestartPendingKey)
    }

    private func waitForProcess(_ process: Process, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !process.isRunning else {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw ResetError(message: "刷新权限记录超时。")
        }
    }

    private func openSystemSettings(path: String) {
        guard let url = URL(string: path), NSWorkspace.shared.open(url) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            return
        }
    }
}
