import Foundation

@main
private enum UpdateAssetSelectorTests {
    private static var failureCount = 0

    static func main() {
        testCompiledArchitecture()
        testExecutableArchitectureValidation()
        testReversedAssetOrder()
        testUnrelatedDMGsAreIgnored()
        testMissingArchitectureFailsSafely()
        testExpectedApplicationVersionMustMatchExactly()
        testUpdateVersionMustBeStrictlyNewer()

        guard failureCount == 0 else {
            fputs("\(failureCount) update asset selector test(s) failed.\n", stderr)
            exit(1)
        }
        print("All update asset selector tests passed.")
    }

    private static func testCompiledArchitecture() {
        #if arch(arm64)
        let expectedArchitecture = UpdateReleaseArchitecture.arm64
        #elseif arch(x86_64)
        let expectedArchitecture = UpdateReleaseArchitecture.x86_64
        #else
        #error("Unsupported test architecture")
        #endif

        expect(
            UpdateReleaseArchitecture.current == expectedArchitecture,
            "current update architecture must match the compiled architecture"
        )
    }

    private static func testExecutableArchitectureValidation() {
        expect(
            UpdateExecutableArchitectureValidator.isStrictlyThin(
                lipoArchitecturesOutput: "arm64\n",
                architecture: .arm64
            ),
            "a single matching arm64 architecture must pass"
        )
        expect(
            UpdateExecutableArchitectureValidator.isStrictlyThin(
                lipoArchitecturesOutput: "  x86_64  ",
                architecture: .x86_64
            ),
            "a single matching x86_64 architecture must pass"
        )
        expect(
            !UpdateExecutableArchitectureValidator.isStrictlyThin(
                lipoArchitecturesOutput: "x86_64",
                architecture: .arm64
            ),
            "a wrong thin architecture must fail"
        )
        expect(
            !UpdateExecutableArchitectureValidator.isStrictlyThin(
                lipoArchitecturesOutput: "arm64 x86_64",
                architecture: .arm64
            ),
            "a universal binary must fail"
        )
        expect(
            !UpdateExecutableArchitectureValidator.isStrictlyThin(
                lipoArchitecturesOutput: "arm64 arm64",
                architecture: .arm64
            ),
            "duplicate architecture output must fail"
        )
        expect(
            !UpdateExecutableArchitectureValidator.isStrictlyThin(
                lipoArchitecturesOutput: "",
                architecture: .arm64
            ),
            "missing architecture output must fail"
        )
    }

    private static func testReversedAssetOrder() {
        let arm64 = asset("Y-Dock-v1.1.19-arm64.dmg")
        let x86_64 = asset("Y-Dock-v1.1.19-x86_64.dmg")

        expect(
            UpdateAssetSelector.matchingAsset(
                in: [x86_64, arm64],
                releaseVersion: "v1.1.19",
                architecture: .arm64
            ) == arm64,
            "arm64 selection must not depend on asset order"
        )
        expect(
            UpdateAssetSelector.matchingAsset(
                in: [arm64, x86_64],
                releaseVersion: "1.1.19",
                architecture: .x86_64
            ) == x86_64,
            "x86_64 selection must not depend on asset order"
        )
    }

    private static func testUnrelatedDMGsAreIgnored() {
        let expected = asset("Y-Dock-v1.1.19-arm64.dmg")
        let assets = [
            asset("Y-Dock-v1.1.19.dmg"),
            asset("Y-Dock-v1.1.19-x86_64.dmg"),
            asset("Another-App-v1.1.19-arm64.dmg"),
            expected,
            asset("Y-Dock-v1.1.19-arm64-debug.dmg")
        ]

        expect(
            UpdateAssetSelector.matchingAsset(
                in: assets,
                releaseVersion: "v1.1.19",
                architecture: .arm64
            ) == expected,
            "selection must require the complete architecture-specific asset name"
        )
    }

    private static func testMissingArchitectureFailsSafely() {
        let assets = [
            asset("Y-Dock-v1.1.19-x86_64.dmg"),
            asset("Y-Dock-v1.1.19.dmg")
        ]

        expect(
            UpdateAssetSelector.matchingAsset(
                in: assets,
                releaseVersion: "v1.1.19",
                architecture: .arm64
            ) == nil,
            "missing arm64 asset must not fall back to another DMG"
        )
    }

    private static func testExpectedApplicationVersionMustMatchExactly() {
        expect(
            UpdateVersionValidator.isExpectedApplicationVersion(
                actualVersion: "1.1.20",
                expectedVersion: "1.1.20"
            ),
            "the downloaded app version must exactly match the release version"
        )
        expect(
            !UpdateVersionValidator.isExpectedApplicationVersion(
                actualVersion: "1.1.19",
                expectedVersion: "1.1.20"
            ),
            "an older app renamed as the new release must fail"
        )
        expect(
            !UpdateVersionValidator.isExpectedApplicationVersion(
                actualVersion: "1.1.20",
                expectedVersion: ""
            ),
            "an empty expected version must fail"
        )
    }

    private static func testUpdateVersionMustBeStrictlyNewer() {
        expect(
            UpdateVersionValidator.isVersion("v1.1.20", newerThan: "1.1.19"),
            "a newer patch version must pass"
        )
        expect(
            !UpdateVersionValidator.isVersion("1.1.19", newerThan: "1.1.19"),
            "the installed version must not be reinstalled"
        )
        expect(
            !UpdateVersionValidator.isVersion("1.1.18", newerThan: "1.1.19"),
            "a downgrade must fail"
        )
        expect(
            !UpdateVersionValidator.isVersion("1.x.20", newerThan: "1.1.19"),
            "a malformed release version must fail"
        )
        expect(
            !UpdateVersionValidator.isVersion("1..20", newerThan: "1.1.19"),
            "an empty version component must fail"
        )
    }

    private static func asset(_ name: String) -> UpdateReleaseAsset {
        UpdateReleaseAsset(
            name: name,
            browserDownloadURL: URL(string: "https://example.com/\(name)")
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failureCount += 1
            fputs("FAIL: \(message)\n", stderr)
        }
    }
}
