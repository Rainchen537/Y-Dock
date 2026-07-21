import AppKit
import Foundation

final class UpdateChecker {
    static let shared = UpdateChecker()

    struct ReleaseInfo {
        let version: String
        let tagName: String
        let name: String
        let htmlURL: URL
        let downloadURL: URL?
        let expectedAssetName: String

        var displayVersion: String {
            tagName.hasPrefix("v") ? tagName : "v\(version)"
        }
    }

    enum CheckResult {
        case updateAvailable(currentVersion: String, latest: ReleaseInfo)
        case upToDate(currentVersion: String, latest: ReleaseInfo)
        case failure(Error)
    }

    enum InstallStatus {
        case downloading
        case preparing
        case relaunching

        var displayText: String {
            switch self {
            case .downloading:
                return "下载中"
            case .preparing:
                return "准备安装"
            case .relaunching:
                return "正在重启"
            }
        }
    }

    private enum UpdateError: LocalizedError {
        case invalidResponse
        case invalidStatusCode(Int)
        case missingReleaseURL
        case missingDownloadURL(String)
        case invalidBundleLocation
        case invalidUpdateApplication
        case invalidUpdateArchitecture(String)
        case cannotMountUpdate
        case cannotPrepareInstaller
        case cannotStartInstaller

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "更新服务器返回了无法识别的数据。"
            case .invalidStatusCode(let statusCode):
                return "更新检查失败，HTTP 状态码：\(statusCode)。"
            case .missingReleaseURL:
                return "最新版本没有可打开的 Release 页面。"
            case .missingDownloadURL(let expectedAssetName):
                return "最新版本缺少当前架构所需的 \(expectedAssetName)。为避免安装错误架构，Y-Dock 不会改用其他 DMG；请打开 Release 页面手动确认。"
            case .invalidBundleLocation:
                return "自动更新只支持 /Applications/Y-Dock.app。请先安装正式发布版，避免权限记录绑定到开发副本。"
            case .invalidUpdateApplication:
                return "下载的更新未通过 Y-Dock 的应用身份、代码签名或 Gatekeeper 校验。"
            case .invalidUpdateArchitecture(let expectedArchitecture):
                return "下载的更新主可执行文件不是严格匹配当前编译架构的 thin \(expectedArchitecture) binary。为避免删除或替换现有 App，本次更新已安全停止。"
            case .cannotMountUpdate:
                return "无法挂载下载的 Y-Dock 更新。"
            case .cannotPrepareInstaller:
                return "无法准备自动安装脚本。"
            case .cannotStartInstaller:
                return "无法启动自动安装流程。"
            }
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: URL?
        let assets: [UpdateReleaseAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case assets
        }
    }

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/Rainchen537/Y-Dock/releases/latest")!
    private let installedApplicationPath = "/Applications/Y-Dock.app"
    private let expectedBundleIdentifier = "com.lixingchen.DockWindowPreview"
    private let expectedTeamIdentifier = "A94225N8T5"
    private let decoder = JSONDecoder()

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func checkForUpdates(completion: @escaping (CheckResult) -> Void) {
        var request = URLRequest(url: latestReleaseURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppBranding.displayName)/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(UpdateError.invalidResponse))
                return
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                completion(.failure(UpdateError.invalidStatusCode(httpResponse.statusCode)))
                return
            }

            guard let data else {
                completion(.failure(UpdateError.invalidResponse))
                return
            }

            do {
                let release = try decoder.decode(GitHubRelease.self, from: data)
                guard let htmlURL = release.htmlURL else {
                    completion(.failure(UpdateError.missingReleaseURL))
                    return
                }

                let expectedAssetName = UpdateAssetSelector.expectedAssetName(
                    releaseVersion: release.tagName
                )
                let matchingAsset = UpdateAssetSelector.matchingAsset(
                    in: release.assets,
                    releaseVersion: release.tagName
                )
                let latest = ReleaseInfo(
                    version: normalizedVersionString(release.tagName),
                    tagName: release.tagName,
                    name: release.name ?? release.tagName,
                    htmlURL: htmlURL,
                    downloadURL: matchingAsset?.browserDownloadURL,
                    expectedAssetName: expectedAssetName
                )

                if compareVersion(latest.version, to: currentVersion) == .orderedDescending {
                    completion(.updateAvailable(currentVersion: currentVersion, latest: latest))
                } else {
                    completion(.upToDate(currentVersion: currentVersion, latest: latest))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    func openReleasePage(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.htmlURL)
    }

    func openDownloadOrReleasePage(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.downloadURL ?? release.htmlURL)
    }

    func downloadAndInstall(
        _ release: ReleaseInfo,
        statusHandler: @escaping (InstallStatus) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let downloadURL = release.downloadURL else {
            completion(.failure(UpdateError.missingDownloadURL(release.expectedAssetName)))
            return
        }

        var request = URLRequest(url: downloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("\(AppBranding.displayName)/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        DispatchQueue.main.async {
            statusHandler(.downloading)
        }

        URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            guard let self else { return }

            if let error {
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                completion(.failure(UpdateError.invalidStatusCode(httpResponse.statusCode)))
                return
            }

            guard let temporaryURL else {
                completion(.failure(UpdateError.invalidResponse))
                return
            }

            do {
                DispatchQueue.main.async {
                    statusHandler(.preparing)
                }

                let workDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Y-Dock-update-\(UUID().uuidString)", isDirectory: true)
                let mountURL = workDirectory.appendingPathComponent("mount", isDirectory: true)
                var installerOwnsWorkDirectory = false
                var updateIsMounted = false
                defer {
                    if !installerOwnsWorkDirectory {
                        if updateIsMounted {
                            detachMountedVolume(at: mountURL)
                        }
                        try? FileManager.default.removeItem(at: workDirectory)
                    }
                }

                try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

                let dmgURL = workDirectory.appendingPathComponent("Y-Dock-\(release.displayVersion).dmg")
                try FileManager.default.moveItem(at: temporaryURL, to: dmgURL)

                let scriptURL = workDirectory.appendingPathComponent("install-update.zsh")
                try installerScript().write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

                let destinationURL = try installationDestinationURL()
                let sourceURL = try prepareMountedUpdateApplication(dmgURL: dmgURL, mountURL: mountURL)
                updateIsMounted = true
                try launchInstaller(
                    scriptURL: scriptURL,
                    dmgURL: dmgURL,
                    sourceURL: sourceURL,
                    mountURL: mountURL,
                    destinationURL: destinationURL
                )
                installerOwnsWorkDirectory = true

                DispatchQueue.main.async {
                    statusHandler(.relaunching)
                    completion(.success(()))
                    NSApp.terminate(nil)
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func normalizedVersionString(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private func compareVersion(_ lhs: String, to rhs: String) -> ComparisonResult {
        let lhsParts = numericParts(from: lhs)
        let rhsParts = numericParts(from: rhs)
        let count = max(lhsParts.count, rhsParts.count)

        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0

            if left > right { return .orderedDescending }
            if left < right { return .orderedAscending }
        }

        return .orderedSame
    }

    private func numericParts(from string: String) -> [Int] {
        let normalized = normalizedVersionString(string)
        let regex = try? NSRegularExpression(pattern: "\\d+")
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = regex?.matches(in: normalized, range: range) ?? []

        return matches.compactMap { match in
            guard let range = Range(match.range, in: normalized) else { return nil }
            return Int(normalized[range])
        }
    }

    private func installationDestinationURL() throws -> URL {
        let installedURL = URL(fileURLWithPath: installedApplicationPath, isDirectory: true)
            .standardizedFileURL
        let runningURL = Bundle.main.bundleURL.standardizedFileURL
        let resourceValues = try? installedURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard
            runningURL == installedURL,
            resourceValues?.isDirectory == true,
            resourceValues?.isSymbolicLink != true,
            YSettingRuntimeIdentity.isSignedInstalledCopy(
                expectedPath: installedURL.path,
                expectedTeamIdentifier: expectedTeamIdentifier,
                expectedBundleIdentifier: expectedBundleIdentifier
            )
        else {
            throw UpdateError.invalidBundleLocation
        }
        return installedURL
    }

    private func prepareMountedUpdateApplication(dmgURL: URL, mountURL: URL) throws -> URL {
        try runCheckedProcess(
            executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: ["-a", "-vvv", "-t", "open", "--context", "context:primary-signature", dmgURL.path],
            failure: .invalidUpdateApplication
        )
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)

        var isMounted = false
        do {
            try runCheckedProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["attach", dmgURL.path, "-mountpoint", mountURL.path, "-nobrowse", "-readonly", "-noautoopen", "-quiet"],
                failure: .cannotMountUpdate
            )
            isMounted = true

            let sourceURL = mountURL.appendingPathComponent("Y-Dock.app", isDirectory: true)
            let resourceValues = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard
                sourceURL.deletingLastPathComponent().standardizedFileURL == mountURL.standardizedFileURL,
                resourceValues?.isDirectory == true,
                resourceValues?.isSymbolicLink != true
            else {
                throw UpdateError.invalidUpdateApplication
            }

            try validateMainExecutableArchitecture(in: sourceURL)
            try runCheckedProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--deep", "--strict", "--verbose=2", sourceURL.path],
                failure: .invalidUpdateApplication
            )
            try runCheckedProcess(
                executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
                arguments: ["-a", "-vvv", "-t", "exec", sourceURL.path],
                failure: .invalidUpdateApplication
            )
            guard YSettingRuntimeIdentity.isValidSignedApplication(
                atPath: sourceURL.path,
                expectedBundleIdentifier: expectedBundleIdentifier,
                expectedTeamIdentifier: expectedTeamIdentifier
            ) else {
                throw UpdateError.invalidUpdateApplication
            }

            return sourceURL
        } catch {
            if isMounted {
                detachMountedVolume(at: mountURL)
            }
            throw error
        }
    }

    private func validateMainExecutableArchitecture(in applicationURL: URL) throws {
        let expectedArchitecture = UpdateReleaseArchitecture.current
        let executableURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Y-Dock", isDirectory: false)
            .standardizedFileURL
        let expectedExecutableDirectory = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .standardizedFileURL
        let resourceValues = try? executableURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard
            executableURL.deletingLastPathComponent() == expectedExecutableDirectory,
            resourceValues?.isRegularFile == true,
            resourceValues?.isSymbolicLink != true
        else {
            throw UpdateError.invalidUpdateArchitecture(expectedArchitecture.rawValue)
        }

        let architecturesOutput = try runCheckedProcessCapturingOutput(
            executableURL: URL(fileURLWithPath: "/usr/bin/lipo"),
            arguments: ["-archs", executableURL.path],
            failure: .invalidUpdateArchitecture(expectedArchitecture.rawValue)
        )
        guard UpdateExecutableArchitectureValidator.isStrictlyThin(
            lipoArchitecturesOutput: architecturesOutput,
            architecture: expectedArchitecture
        ) else {
            throw UpdateError.invalidUpdateArchitecture(expectedArchitecture.rawValue)
        }
    }

    private func runCheckedProcessCapturingOutput(
        executableURL: URL,
        arguments: [String],
        failure: UpdateError
    ) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw failure
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let outputString = String(data: output, encoding: .utf8) else {
            throw failure
        }
        return outputString
    }

    private func runCheckedProcess(
        executableURL: URL,
        arguments: [String],
        failure: UpdateError
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw failure
        }

        guard process.terminationStatus == 0 else {
            throw failure
        }
    }

    private func detachMountedVolume(at mountURL: URL) {
        if (try? runCheckedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["detach", mountURL.path, "-quiet"],
            failure: .cannotMountUpdate
        )) == nil {
            try? runCheckedProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", mountURL.path, "-force", "-quiet"],
                failure: .cannotMountUpdate
            )
        }
    }

    private func launchInstaller(
        scriptURL: URL,
        dmgURL: URL,
        sourceURL: URL,
        mountURL: URL,
        destinationURL: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            scriptURL.path,
            dmgURL.path,
            sourceURL.path,
            mountURL.path,
            destinationURL.path,
            UpdateReleaseArchitecture.current.rawValue,
            "\(ProcessInfo.processInfo.processIdentifier)"
        ]

        do {
            try process.run()
        } catch {
            throw UpdateError.cannotStartInstaller
        }
    }

    private func installerScript() -> String {
        """
        #!/bin/zsh
        set -euo pipefail

        DMG="$1"
        SRC="$2"
        MOUNT="$3"
        DEST="$4"
        EXPECTED_ARCH="$5"
        APP_PID="$6"

        cleanup() {
          /usr/bin/hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || \\
            /usr/bin/hdiutil detach "$MOUNT" -force -quiet >/dev/null 2>&1 || true
          /bin/rm -rf "$(/usr/bin/dirname "$DMG")"
        }
        trap cleanup EXIT

        while /bin/kill -0 "$APP_PID" 2>/dev/null; do
          /bin/sleep 0.1
        done

        /usr/sbin/spctl -a -vvv -t open --context context:primary-signature "$DMG"

        if [[ "$SRC" != "$MOUNT/Y-Dock.app" || ! -d "$SRC" || -L "$SRC" ]]; then
          echo "Y-Dock.app not found as a regular app bundle in update DMG" >&2
          exit 1
        fi

        EXECUTABLE="$SRC/Contents/MacOS/Y-Dock"
        if [[ ! -f "$EXECUTABLE" || -L "$EXECUTABLE" ]]; then
          echo "Y-Dock main executable is missing or is a symbolic link" >&2
          exit 1
        fi
        ACTUAL_ARCHS="$(/usr/bin/lipo -archs "$EXECUTABLE" | /usr/bin/xargs)"
        if [[ "$ACTUAL_ARCHS" != "$EXPECTED_ARCH" ]]; then
          echo "Y-Dock update architecture mismatch: expected thin $EXPECTED_ARCH, got $ACTUAL_ARCHS" >&2
          exit 1
        fi

        /usr/bin/codesign --verify --deep --strict --verbose=2 "$SRC"
        /usr/sbin/spctl -a -vvv -t exec "$SRC"

        install_app() {
          /bin/rm -rf "$DEST"
          /usr/bin/ditto "$SRC" "$DEST"
        }

        if ! install_app; then
          /usr/bin/osascript \\
            -e 'on run argv' \\
            -e 'set srcPath to item 1 of argv' \\
            -e 'set destPath to item 2 of argv' \\
            -e 'do shell script "/bin/rm -rf " & quoted form of destPath & " && /usr/bin/ditto " & quoted form of srcPath & " " & quoted form of destPath with administrator privileges' \\
            -e 'end run' \\
            "$SRC" "$DEST"
        fi

        /usr/bin/open "$DEST"
        """
    }
}
