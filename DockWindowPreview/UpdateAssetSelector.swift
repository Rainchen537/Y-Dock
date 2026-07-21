import Foundation

enum UpdateReleaseArchitecture: String, CaseIterable {
    case arm64
    case x86_64

    static var current: UpdateReleaseArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        #error("Y-Dock updates are supported only on arm64 and x86_64")
        #endif
    }
}

struct UpdateReleaseAsset: Decodable, Equatable {
    let name: String
    let browserDownloadURL: URL?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

enum UpdateAssetSelector {
    static func expectedAssetName(
        releaseVersion: String,
        architecture: UpdateReleaseArchitecture = .current
    ) -> String {
        let trimmedVersion = releaseVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let version: Substring
        if trimmedVersion.first == "v" || trimmedVersion.first == "V" {
            version = trimmedVersion.dropFirst()
        } else {
            version = Substring(trimmedVersion)
        }
        return "Y-Dock-v\(version)-\(architecture.rawValue).dmg"
    }

    static func matchingAsset(
        in assets: [UpdateReleaseAsset],
        releaseVersion: String,
        architecture: UpdateReleaseArchitecture = .current
    ) -> UpdateReleaseAsset? {
        let expectedName = expectedAssetName(
            releaseVersion: releaseVersion,
            architecture: architecture
        )
        return assets.first { $0.name == expectedName }
    }
}

enum UpdateExecutableArchitectureValidator {
    static func isStrictlyThin(
        lipoArchitecturesOutput: String,
        architecture: UpdateReleaseArchitecture = .current
    ) -> Bool {
        let architectures = lipoArchitecturesOutput.split(whereSeparator: { $0.isWhitespace })
        return architectures.count == 1 && architectures[0] == architecture.rawValue
    }
}
