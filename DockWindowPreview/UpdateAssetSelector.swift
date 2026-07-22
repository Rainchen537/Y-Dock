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

enum UpdateVersionValidator {
    static func normalizedVersionString(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard
            let candidateComponents = versionComponents(normalizedVersionString(candidate)),
            let currentComponents = versionComponents(normalizedVersionString(current))
        else {
            return false
        }

        let count = max(candidateComponents.count, currentComponents.count)
        for index in 0..<count {
            let candidateValue = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentValue = index < currentComponents.count ? currentComponents[index] : 0
            if candidateValue != currentValue {
                return candidateValue > currentValue
            }
        }
        return false
    }

    static func isExpectedApplicationVersion(
        actualVersion: String,
        expectedVersion: String
    ) -> Bool {
        !expectedVersion.isEmpty && actualVersion == expectedVersion
    }

    private static func versionComponents(_ version: String) -> [Int]? {
        let components = version.components(separatedBy: ".")
        guard !components.isEmpty else {
            return nil
        }

        var values: [Int] = []
        values.reserveCapacity(components.count)
        for component in components {
            guard
                !component.isEmpty,
                component.allSatisfy(\.isNumber),
                let value = Int(component),
                value >= 0
            else {
                return nil
            }
            values.append(value)
        }
        return values
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
