import AppKit
import CryptoKit
import Darwin
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
        case invalidUpdateVersion(String)
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
            case .invalidUpdateVersion(let expectedVersion):
                return "下载 App 的内部版本与 GitHub Release \(expectedVersion) 不一致，或该版本不高于当前版本。现有 App 未被替换。"
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
                    version: UpdateVersionValidator.normalizedVersionString(release.tagName),
                    tagName: release.tagName,
                    name: release.name ?? release.tagName,
                    htmlURL: htmlURL,
                    downloadURL: matchingAsset?.browserDownloadURL,
                    expectedAssetName: expectedAssetName
                )

                if UpdateVersionValidator.isVersion(latest.version, newerThan: currentVersion) {
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
        guard UpdateVersionValidator.isVersion(release.version, newerThan: currentVersion) else {
            completion(.failure(UpdateError.invalidUpdateVersion(release.version)))
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
                let installerContents = installerScript()
                let installerDigest = installerScriptDigest(installerContents)
                try installerContents.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

                let destinationURL = try installationDestinationURL()
                let sourceURL = try prepareMountedUpdateApplication(
                    dmgURL: dmgURL,
                    mountURL: mountURL,
                    expectedVersion: release.version
                )
                updateIsMounted = true
                try launchInstaller(
                    scriptURL: scriptURL,
                    dmgURL: dmgURL,
                    sourceURL: sourceURL,
                    mountURL: mountURL,
                    destinationURL: destinationURL,
                    expectedVersion: release.version,
                    installedVersion: currentVersion,
                    trustedInstallerDigest: installerDigest
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

    private func prepareMountedUpdateApplication(
        dmgURL: URL,
        mountURL: URL,
        expectedVersion: String
    ) throws -> URL {
        guard UpdateVersionValidator.isVersion(expectedVersion, newerThan: currentVersion) else {
            throw UpdateError.invalidUpdateVersion(expectedVersion)
        }

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

            try validateApplicationVersion(in: sourceURL, expectedVersion: expectedVersion)
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

    private func validateApplicationVersion(
        in applicationURL: URL,
        expectedVersion: String
    ) throws {
        let infoPlistURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard
            let infoDictionary = NSDictionary(contentsOf: infoPlistURL),
            let actualVersion = infoDictionary["CFBundleShortVersionString"] as? String,
            UpdateVersionValidator.isExpectedApplicationVersion(
                actualVersion: actualVersion,
                expectedVersion: expectedVersion
            )
        else {
            throw UpdateError.invalidUpdateVersion(expectedVersion)
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
        destinationURL: URL,
        expectedVersion: String,
        installedVersion: String,
        trustedInstallerDigest: String
    ) throws {
        let process = Process()
        let baseArguments = [
            dmgURL.path,
            sourceURL.path,
            mountURL.path,
            destinationURL.path,
            UpdateReleaseArchitecture.current.rawValue,
            "\(ProcessInfo.processInfo.processIdentifier)",
            expectedVersion,
            installedVersion
        ]
        let destinationDirectoryURL = destinationURL.deletingLastPathComponent()
        var readinessPipe: Pipe?

        if FileManager.default.isWritableFile(atPath: destinationDirectoryURL.path) {
            let pipe = Pipe()
            let transactionHelperURL = scriptURL.deletingLastPathComponent()
                .appendingPathComponent("Y-Dock-transaction-helper-\(UUID().uuidString).app")
            readinessPipe = pipe
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", scriptURL.path] + baseArguments + [
                "user",
                transactionHelperURL.path
            ]
            process.standardOutput = pipe
        } else {
            let privilegedShell = #"set -euo pipefail; SOURCE_SCRIPT="$1"; EXPECTED_DIGEST="$2"; shift 2; ROOT_DIRECTORY=$(/usr/bin/mktemp -d /var/tmp/Y-Dock-update-installer.XXXXXX) || exit 1; cleanup() { /bin/rm -rf "$ROOT_DIRECTORY"; }; trap cleanup EXIT; ROOT_SCRIPT="$ROOT_DIRECTORY/install-update.zsh"; ROOT_HELPER="$ROOT_DIRECTORY/Y-Dock-transaction-helper.app"; /usr/bin/install -m 700 "$SOURCE_SCRIPT" "$ROOT_SCRIPT" || exit 1; ACTUAL_DIGEST=$(/usr/bin/shasum -a 256 "$ROOT_SCRIPT") || exit 1; ACTUAL_DIGEST="${ACTUAL_DIGEST%% *}"; [[ "$ACTUAL_DIGEST" == "$EXPECTED_DIGEST" ]] || exit 1; if /bin/zsh -f "$ROOT_SCRIPT" "$@" "$ROOT_HELPER"; then exit 0; else RESULT=$?; exit "$RESULT"; fi"#
            let privilegedArguments = [scriptURL.path, trustedInstallerDigest] + baseArguments + ["privileged"]
            let privilegedCommand = shellCommand(
                executable: "/bin/zsh",
                arguments: ["-f", "-c", privilegedShell, "--"] + privilegedArguments
            )
            let failureShell = #"""
            set -u
            APP_PID="$1"
            MOUNT="$2"
            WORK_DIRECTORY="$3"
            DEST="$4"
            EXPECTED_ARCH="$5"
            EXPECTED_VERSION="$6"
            INSTALLED_VERSION="$7"
            EXECUTABLE_NAME="Y-Dock"
            BUNDLE_ID="com.lixingchen.DockWindowPreview"
            TEAM_ID="A94225N8T5"

            validate_app() {
              local app="$1"
              local required_version="$2"
              local info_plist="$app/Contents/Info.plist"
              local executable_path="$app/Contents/MacOS/$EXECUTABLE_NAME"
              local bundle_id actual_version actual_archs signature_info

              [[ -d "$app" && ! -L "$app" ]] || return 1
              [[ -f "$info_plist" && ! -L "$info_plist" ]] || return 1
              [[ -f "$executable_path" && ! -L "$executable_path" ]] || return 1
              bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" || return 1
              [[ "$bundle_id" == "$BUNDLE_ID" ]] || return 1
              actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" || return 1
              [[ "$actual_version" == "$required_version" ]] || return 1
              actual_archs="$(/usr/bin/lipo -archs "$executable_path" | /usr/bin/xargs)" || return 1
              [[ "$actual_archs" == "$EXPECTED_ARCH" ]] || return 1
              /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >/dev/null || return 1
              signature_info="$(/usr/bin/codesign -dvvv "$app" 2>&1)" || return 1
              /usr/bin/grep -Fqx "Identifier=$BUNDLE_ID" <<< "$signature_info" || return 1
              /usr/bin/grep -Fqx "TeamIdentifier=$TEAM_ID" <<< "$signature_info" || return 1
              /usr/bin/grep -Fq "Authority=Developer ID Application:" <<< "$signature_info" || return 1
              /usr/bin/grep -Fq "($TEAM_ID)" <<< "$signature_info" || return 1
              /usr/bin/grep -q "flags=.*runtime" <<< "$signature_info" || return 1
              /usr/sbin/spctl -a -vvv -t exec "$app" >/dev/null || return 1
            }

            while /bin/kill -0 "$APP_PID" 2>/dev/null; do
              /bin/sleep 0.1
            done
            /usr/bin/hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || /usr/bin/hdiutil detach "$MOUNT" -force -quiet >/dev/null 2>&1 || true
            /bin/rm -rf "$WORK_DIRECTORY" || true
            if validate_app "$DEST" "$EXPECTED_VERSION" || validate_app "$DEST" "$INSTALLED_VERSION"; then
              /usr/bin/open "$DEST" >/dev/null 2>&1 || true
            fi
            """#
            let failureCommand = shellCommand(
                executable: "/bin/zsh",
                arguments: [
                    "-f",
                    "-c",
                    failureShell,
                    "--",
                    "\(ProcessInfo.processInfo.processIdentifier)",
                    mountURL.path,
                    dmgURL.deletingLastPathComponent().path,
                    destinationURL.path,
                    UpdateReleaseArchitecture.current.rawValue,
                    expectedVersion,
                    installedVersion
                ]
            )
            let appleScript = """
            try
                do shell script \(appleScriptStringLiteral(privilegedCommand)) with administrator privileges
            on error
                do shell script \(appleScriptStringLiteral(failureCommand))
            end try
            """
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
        }

        if readinessPipe == nil {
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.cannotStartInstaller
        }

        if let readinessPipe {
            try waitForInstallerReadiness(
                from: readinessPipe,
                process: process,
                timeout: 60
            )
        }
    }

    private func waitForInstallerReadiness(
        from pipe: Pipe,
        process: Process,
        timeout: TimeInterval
    ) throws {
        let expectedData = Data("READY\n".utf8)
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start > UInt64.max - timeoutNanoseconds
            ? UInt64.max
            : start + timeoutNanoseconds
        let fileDescriptor = pipe.fileHandleForReading.fileDescriptor
        var receivedData = Data()

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                stopInstallerProcess(process)
                throw UpdateError.cannotStartInstaller
            }

            let remainingNanoseconds = deadline - now
            let remainingMilliseconds = min(
                UInt64(Int32.max),
                (remainingNanoseconds + 999_999) / 1_000_000
            )
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                Int32(remainingMilliseconds)
            )
            if pollResult < 0 && errno == EINTR {
                continue
            }
            guard
                pollResult > 0,
                descriptor.revents & Int16(POLLNVAL | POLLERR) == 0,
                descriptor.revents & Int16(POLLIN | POLLHUP) != 0
            else {
                stopInstallerProcess(process)
                throw UpdateError.cannotStartInstaller
            }

            var buffer = [UInt8](
                repeating: 0,
                count: expectedData.count + 1 - receivedData.count
            )
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if bytesRead < 0 && errno == EINTR {
                continue
            }
            guard bytesRead >= 0 else {
                stopInstallerProcess(process)
                throw UpdateError.cannotStartInstaller
            }
            if bytesRead == 0 {
                break
            }
            receivedData.append(contentsOf: buffer.prefix(bytesRead))
            guard receivedData.count <= expectedData.count else {
                stopInstallerProcess(process)
                throw UpdateError.cannotStartInstaller
            }
        }

        guard receivedData == expectedData else {
            stopInstallerProcess(process)
            throw UpdateError.cannotStartInstaller
        }
    }

    private func stopInstallerProcess(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }

        process.terminate()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func installerScriptDigest(_ contents: String) -> String {
        SHA256.hash(data: Data(contents.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func shellCommand(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuoted).joined(separator: " ")
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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
        EXPECTED_VERSION="$7"
        INSTALLED_VERSION="$8"
        MODE="$9"
        TRANSACTION_HELPER="${10}"
        EXECUTABLE_NAME="Y-Dock"
        BUNDLE_ID="com.lixingchen.DockWindowPreview"
        TEAM_ID="A94225N8T5"
        parent_exit_authorized=0
        parent_wait_active=0
        lock_owned=0
        lock_directory=""
        transaction_helper_digest=""
        if [[ "$MODE" == "privileged" ]]; then
          parent_exit_authorized=1
        fi

        validate_identity() {
          local app="$1"
          local info_plist="$app/Contents/Info.plist"
          local bundle_id executable_name executable_path signature_info

          [[ -d "$app" && ! -L "$app" ]] || return 1
          [[ -f "$info_plist" && ! -L "$info_plist" ]] || return 1
          bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" || return 1
          [[ "$bundle_id" == "$BUNDLE_ID" ]] || return 1
          executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")" || return 1
          [[ "$executable_name" == "$EXECUTABLE_NAME" ]] || return 1
          executable_path="$app/Contents/MacOS/$executable_name"
          [[ -f "$executable_path" && ! -L "$executable_path" ]] || return 1
          /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >/dev/null || return 1
          signature_info="$(/usr/bin/codesign -dvvv "$app" 2>&1)" || return 1
          /usr/bin/grep -Fqx "Identifier=$BUNDLE_ID" <<< "$signature_info" || return 1
          /usr/bin/grep -Fqx "TeamIdentifier=$TEAM_ID" <<< "$signature_info" || return 1
          /usr/bin/grep -Fq "Authority=Developer ID Application:" <<< "$signature_info" || return 1
          /usr/bin/grep -Fq "($TEAM_ID)" <<< "$signature_info" || return 1
          /usr/bin/grep -q "flags=.*runtime" <<< "$signature_info" || return 1
          /usr/sbin/spctl -a -vvv -t exec "$app" >/dev/null || return 1
        }

        validate_app() {
          local app="$1"
          local required_version="$2"
          local executable_path="$app/Contents/MacOS/$EXECUTABLE_NAME"
          local actual_archs actual_version

          validate_identity "$app" || return 1
          actual_archs="$(/usr/bin/lipo -archs "$executable_path" | /usr/bin/xargs)" || return 1
          [[ "$actual_archs" == "$EXPECTED_ARCH" ]] || return 1
          actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" || return 1
          [[ "$actual_version" == "$required_version" ]] || return 1
        }

        handle_termination() {
          if (( parent_wait_active == 1 )); then
            parent_exit_authorized=0
            parent_wait_active=0
          fi
          exit 143
        }

        cleanup() {
          local exit_status=$?
          trap - EXIT TERM INT HUP
          if (( exit_status != 0 && parent_exit_authorized == 1 )); then
            while /bin/kill -0 "$APP_PID" 2>/dev/null; do
              /bin/sleep 0.1
            done
            if validate_app "$DEST" "$EXPECTED_VERSION" || validate_app "$DEST" "$INSTALLED_VERSION"; then
              /usr/bin/open "$DEST" >/dev/null 2>&1 || true
            fi
          fi
          /usr/bin/hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || /usr/bin/hdiutil detach "$MOUNT" -force -quiet >/dev/null 2>&1 || true
          /bin/rm -rf "$(/usr/bin/dirname "$DMG")" || true
          if (( lock_owned == 1 )); then
            /bin/rmdir "$lock_directory" >/dev/null 2>&1 || true
            lock_owned=0
          fi
          exit "$exit_status"
        }
        trap cleanup EXIT
        trap handle_termination TERM INT HUP

        acquire_transaction_lock() {
          local destination_directory

          destination_directory="$(/usr/bin/dirname "$DEST")" || return 1
          lock_directory="$destination_directory/.Y-Dock-update.lock"
          [[ ! -e "$lock_directory" && ! -L "$lock_directory" ]] || return 1
          /bin/mkdir -m 700 "$lock_directory" || return 1
          lock_owned=1
        }

        digest_file() {
          local file="$1"
          local digest

          digest="$(/usr/bin/shasum -a 256 "$file")" || return 1
          digest="${digest%% *}"
          [[ ${#digest} -eq 64 ]] || return 1
          /usr/bin/printf '%s' "$digest"
        }

        prepare_transaction_helper() {
          local candidate="$1"
          local source_executable="$candidate/Contents/MacOS/$EXECUTABLE_NAME"
          local copied_executable="$TRANSACTION_HELPER/Contents/MacOS/$EXECUTABLE_NAME"
          local source_digest copied_digest

          [[ -n "$TRANSACTION_HELPER" ]] || return 1
          [[ -f "$source_executable" && ! -L "$source_executable" ]] || return 1
          [[ ! -e "$TRANSACTION_HELPER" && ! -L "$TRANSACTION_HELPER" ]] || return 1
          source_digest="$(digest_file "$source_executable")" || return 1
          if ! /usr/bin/ditto "$candidate" "$TRANSACTION_HELPER"; then
            /bin/rm -rf "$TRANSACTION_HELPER" || true
            return 1
          fi
          if ! validate_app "$TRANSACTION_HELPER" "$EXPECTED_VERSION"; then
            /bin/rm -rf "$TRANSACTION_HELPER" || true
            return 1
          fi
          copied_digest="$(digest_file "$copied_executable")" || return 1
          [[ "$copied_digest" == "$source_digest" ]] || return 1
          transaction_helper_digest="$source_digest"
        }

        validate_transaction_helper() {
          local helper_executable="$TRANSACTION_HELPER/Contents/MacOS/$EXECUTABLE_NAME"
          local actual_digest

          [[ -n "$transaction_helper_digest" ]] || return 1
          validate_app "$TRANSACTION_HELPER" "$EXPECTED_VERSION" || return 1
          actual_digest="$(digest_file "$helper_executable")" || return 1
          [[ "$actual_digest" == "$transaction_helper_digest" ]] || return 1
        }

        atomic_swap() {
          local first="$1"
          local second="$2"
          local helper_executable="$TRANSACTION_HELPER/Contents/MacOS/$EXECUTABLE_NAME"

          validate_transaction_helper || return 1
          "$helper_executable" --transactional-update-swap "$first" "$second" || return 1
        }

        exclusive_rename() {
          local source="$1"
          local destination="$2"
          local helper_executable="$TRANSACTION_HELPER/Contents/MacOS/$EXECUTABLE_NAME"

          validate_transaction_helper || return 1
          "$helper_executable" --transactional-update-rename-exclusive "$source" "$destination" || return 1
        }

        restore_backup() {
          local backup="$1"

          atomic_swap "$backup" "$DEST" || return 1
          validate_app "$DEST" "$INSTALLED_VERSION" || return 1
          /bin/rm -rf "$backup" || true
        }

        perform_transactional_install() {
          local destination_directory uuid candidate backup
          destination_directory="$(/usr/bin/dirname "$DEST")" || return 1
          uuid="$(/usr/bin/uuidgen)" || return 1
          candidate="$destination_directory/.Y-Dock-update-$uuid.app"
          backup="$destination_directory/.Y-Dock-backup-$uuid.app"

          validate_app "$DEST" "$INSTALLED_VERSION" || return 1
          [[ ! -e "$candidate" && ! -L "$candidate" ]] || return 1
          [[ ! -e "$backup" && ! -L "$backup" ]] || return 1

          if ! /usr/bin/ditto "$SRC" "$candidate"; then
            /bin/rm -rf "$candidate" || true
            return 1
          fi
          if ! validate_app "$candidate" "$EXPECTED_VERSION"; then
            /bin/rm -rf "$candidate" || true
            return 1
          fi
          if ! prepare_transaction_helper "$candidate"; then
            /bin/rm -rf "$candidate" || true
            return 1
          fi

          if ! atomic_swap "$candidate" "$DEST"; then
            /bin/rm -rf "$candidate" || true
            return 1
          fi
          if ! validate_app "$candidate" "$INSTALLED_VERSION"; then
            if atomic_swap "$candidate" "$DEST"; then
              /bin/rm -rf "$candidate" || true
            fi
            return 1
          fi
          if ! exclusive_rename "$candidate" "$backup"; then
            if atomic_swap "$candidate" "$DEST"; then
              /bin/rm -rf "$candidate" || true
            fi
            return 1
          fi

          if ! validate_app "$DEST" "$EXPECTED_VERSION"; then
            if ! restore_backup "$backup"; then
              echo "Y-Dock restore failed; backup preserved at $backup" >&2
            fi
            return 1
          fi

          /bin/rm -rf "$backup" || true
        }

        [[ "$MODE" == "user" || "$MODE" == "privileged" ]] || exit 1
        /usr/sbin/spctl -a -vvv -t open --context context:primary-signature "$DMG" || exit 1
        if [[ "$SRC" != "$MOUNT/Y-Dock.app" ]]; then
          echo "Y-Dock.app not found at the expected update mount path" >&2
          exit 1
        fi
        validate_app "$SRC" "$EXPECTED_VERSION" || exit 1
        validate_app "$DEST" "$INSTALLED_VERSION" || exit 1
        acquire_transaction_lock || exit 1
        if [[ "$MODE" == "user" ]]; then
          parent_wait_active=1
          parent_exit_authorized=1
          if ! /usr/bin/printf 'READY\n'; then
            parent_exit_authorized=0
            parent_wait_active=0
            exit 1
          fi
          if ! exec 1>&-; then
            parent_exit_authorized=0
            parent_wait_active=0
            exit 1
          fi
        fi

        while /bin/kill -0 "$APP_PID" 2>/dev/null; do
          /bin/sleep 0.1
        done
        parent_wait_active=0

        if ! perform_transactional_install; then
          exit 1
        fi
        if ! /usr/bin/open "$DEST"; then
          exit 1
        fi
        """
    }
}
