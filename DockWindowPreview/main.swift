import AppKit
import Darwin

private enum UpdatePathSwapHelper {
    static let swapCommand = "--transactional-update-swap"
    static let exclusiveRenameCommand = "--transactional-update-rename-exclusive"

    static func runIfRequested(arguments: [String]) -> Int32? {
        guard let command = arguments.dropFirst().first,
              command == swapCommand || command == exclusiveRenameCommand else {
            return nil
        }
        guard arguments.count == 4 else {
            return 64
        }

        let firstURL = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        let secondURL = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
        guard firstURL.deletingLastPathComponent() == secondURL.deletingLastPathComponent() else {
            return 65
        }

        if command == swapCommand {
            guard
                isAllowedSwapPair(firstURL: firstURL, secondURL: secondURL),
                isRegularApplicationDirectory(firstURL),
                isRegularApplicationDirectory(secondURL)
            else {
                return 65
            }
            return rename(firstURL, secondURL, flags: UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY))
        }

        guard
            isAllowedExclusiveRenamePair(firstURL: firstURL, secondURL: secondURL),
            isRegularApplicationDirectory(firstURL),
            pathDoesNotExist(secondURL)
        else {
            return 65
        }
        return rename(firstURL, secondURL, flags: UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY))
    }

    private static func rename(_ firstURL: URL, _ secondURL: URL, flags: UInt32) -> Int32 {
        let result = firstURL.path.withCString { firstPath in
            secondURL.path.withCString { secondPath in
                renameatx_np(AT_FDCWD, firstPath, AT_FDCWD, secondPath, flags)
            }
        }
        return result == 0 ? 0 : 71
    }

    private static func isAllowedSwapPair(firstURL: URL, secondURL: URL) -> Bool {
        let names = Set([firstURL.lastPathComponent, secondURL.lastPathComponent])
        guard names.contains("Y-Dock.app") else {
            return false
        }
        return names.contains { name in
            name.hasPrefix(".Y-Dock-update-") || name.hasPrefix(".Y-Dock-backup-")
        }
    }

    private static func isAllowedExclusiveRenamePair(firstURL: URL, secondURL: URL) -> Bool {
        let names = [firstURL.lastPathComponent, secondURL.lastPathComponent]
        return names.contains { $0.hasPrefix(".Y-Dock-update-") }
            && names.contains { $0.hasPrefix(".Y-Dock-backup-") }
    }

    private static func isRegularApplicationDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func pathDoesNotExist(_ url: URL) -> Bool {
        var fileStatus = stat()
        let result = url.path.withCString { path in
            lstat(path, &fileStatus)
        }
        return result != 0 && errno == ENOENT
    }
}

if let exitStatus = UpdatePathSwapHelper.runIfRequested(arguments: CommandLine.arguments) {
    exit(exitStatus)
}

let application = NSApplication.shared
let delegate = DockWindowPreviewApp()
application.delegate = delegate
application.run()
