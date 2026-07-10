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
        case missingDownloadURL
        case invalidBundleLocation
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
            case .missingDownloadURL:
                return "最新版本没有可直接安装的 DMG。"
            case .invalidBundleLocation:
                return "无法识别当前 App 的安装位置。"
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
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: URL?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/Rainchen537/Y-Dock/releases/latest")!
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

                let latest = ReleaseInfo(
                    version: normalizedVersionString(release.tagName),
                    tagName: release.tagName,
                    name: release.name ?? release.tagName,
                    htmlURL: htmlURL,
                    downloadURL: release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })?.browserDownloadURL
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
            completion(.failure(UpdateError.missingDownloadURL))
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
                try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

                let dmgURL = workDirectory.appendingPathComponent("Y-Dock-\(release.displayVersion).dmg")
                try FileManager.default.moveItem(at: temporaryURL, to: dmgURL)

                let scriptURL = workDirectory.appendingPathComponent("install-update.zsh")
                try installerScript().write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

                let destinationURL = try installationDestinationURL()
                try launchInstaller(
                    scriptURL: scriptURL,
                    dmgURL: dmgURL,
                    destinationURL: destinationURL
                )

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
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            throw UpdateError.invalidBundleLocation
        }
        return bundleURL.resolvingSymlinksInPath()
    }

    private func launchInstaller(scriptURL: URL, dmgURL: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            scriptURL.path,
            dmgURL.path,
            destinationURL.path,
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
        DEST="$2"
        APP_PID="$3"
        MOUNT="$(/usr/bin/mktemp -d /tmp/Y-Dock-update-mount.XXXXXX)"

        cleanup() {
          /usr/bin/hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
          /bin/rm -rf "$MOUNT"
          /bin/rm -rf "$(/usr/bin/dirname "$DMG")"
        }
        trap cleanup EXIT

        while /bin/kill -0 "$APP_PID" 2>/dev/null; do
          /bin/sleep 0.1
        done

        /usr/sbin/spctl -a -vvv -t open --context context:primary-signature "$DMG"
        /usr/bin/hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -readonly -quiet

        SRC="$MOUNT/Y-Dock.app"
        if [ ! -d "$SRC" ]; then
          echo "Y-Dock.app not found in update DMG" >&2
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
