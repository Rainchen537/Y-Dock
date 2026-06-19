import AppKit
import CoreGraphics
import Foundation

final class WindowThumbnailProvider {
    private struct WindowSnapshotKey: Hashable {
        let ownerPID: pid_t
        let normalizedTitle: String
        let roundedWidth: Int
        let roundedHeight: Int
    }

    private struct WindowTitleKey: Hashable {
        let ownerPID: pid_t
        let normalizedTitle: String
    }

    private var snapshotCache: [WindowSnapshotKey: NSImage] = [:]
    private var titleFallbackCache: [WindowTitleKey: NSImage] = [:]
    private var cacheOrder: [WindowSnapshotKey] = []
    private let maximumCachedSnapshots = 80

    func thumbnail(for window: WindowInfo, targetSize: NSSize) -> NSImage {
        if window.isMinimized {
            if let capturedImage = captureWindowImage(for: window, targetSize: targetSize) {
                cache(capturedImage, for: window)
                return minimizedOverlayImage(base: capturedImage, title: window.title, size: targetSize)
            }

            if let cachedImage = cachedThumbnail(for: window, targetSize: targetSize) {
                return minimizedOverlayImage(base: cachedImage, title: window.title, size: targetSize)
            }

            return placeholderImage(title: window.title, reason: "已最小化", size: targetSize)
        }

        if let capturedImage = captureWindowImage(for: window, targetSize: targetSize) {
            cache(capturedImage, for: window)
            return capturedImage
        }

        let reason = CGPreflightScreenCaptureAccess() ? "无法截图" : "需要屏幕录制权限"
        DWLog("Failed to capture thumbnail for window \(window.windowID), reason: \(reason)")
        return placeholderImage(title: window.title, reason: reason, size: targetSize)
    }

    func focusImage(for window: WindowInfo, targetSize: NSSize) -> NSImage? {
        if let capturedImage = captureWindowImage(for: window, targetSize: targetSize) {
            cache(capturedImage, for: window)
            return capturedImage
        }

        return cachedThumbnail(for: window, targetSize: targetSize)
    }

    private func captureWindowImage(for window: WindowInfo, targetSize: NSSize) -> NSImage? {
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, window.windowID, options) else {
            return nil
        }

        guard cgImage.width >= 8, cgImage.height >= 8 else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: targetSize)
    }

    private func cachedThumbnail(for window: WindowInfo, targetSize: NSSize) -> NSImage? {
        let exactKey = snapshotKey(for: window)
        if let image = snapshotCache[exactKey] {
            return image.resized(to: targetSize)
        }

        let titleKey = WindowTitleKey(ownerPID: window.ownerPID, normalizedTitle: normalize(window.title))
        if let image = titleFallbackCache[titleKey] {
            DWLog("Using title fallback snapshot for minimized window '\(window.title)'")
            return image.resized(to: targetSize)
        }

        return nil
    }

    private func cache(_ image: NSImage, for window: WindowInfo) {
        let exactKey = snapshotKey(for: window)
        snapshotCache[exactKey] = image

        let titleKey = WindowTitleKey(ownerPID: window.ownerPID, normalizedTitle: normalize(window.title))
        titleFallbackCache[titleKey] = image

        cacheOrder.removeAll { $0 == exactKey }
        cacheOrder.append(exactKey)

        while cacheOrder.count > maximumCachedSnapshots {
            let removedKey = cacheOrder.removeFirst()
            snapshotCache.removeValue(forKey: removedKey)
        }
    }

    private func snapshotKey(for window: WindowInfo) -> WindowSnapshotKey {
        WindowSnapshotKey(
            ownerPID: window.ownerPID,
            normalizedTitle: normalize(window.title),
            roundedWidth: roundedDimension(window.bounds.width),
            roundedHeight: roundedDimension(window.bounds.height)
        )
    }

    private func roundedDimension(_ value: CGFloat) -> Int {
        Int((max(1, value) / 8).rounded()) * 8
    }

    private func placeholderImage(title: String, reason: String, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()

        NSColor(calibratedWhite: 0.32, alpha: 1).setStroke()
        let insetRect = rect.insetBy(dx: 1, dy: 1)
        let border = NSBezierPath(roundedRect: insetRect, xRadius: 9, yRadius: 9)
        border.lineWidth = 1
        border.stroke()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.82, alpha: 1),
            .paragraphStyle: paragraphStyle
        ]
        let text = "\(reason)\n\(title)"
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textRect = NSRect(x: 12, y: (size.height - 44) / 2, width: size.width - 24, height: 44)
        attributed.draw(in: textRect)

        image.unlockFocus()
        return image
    }

    private func minimizedOverlayImage(base: NSImage, title: String, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        base.draw(in: rect, from: .zero, operation: .copy, fraction: 1)

        NSColor(calibratedWhite: 0, alpha: 0.40).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()

        let pillWidth = min(max(112, size.width * 0.44), size.width - 28)
        let pillRect = NSRect(
            x: (size.width - pillWidth) / 2,
            y: (size.height - 34) / 2,
            width: pillWidth,
            height: 34
        )

        NSColor(calibratedWhite: 0.05, alpha: 0.68).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 17, yRadius: 17).fill()

        NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
        let border = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 16.5, yRadius: 16.5)
        border.lineWidth = 1
        border.stroke()

        let iconRect = NSRect(x: pillRect.minX + 14, y: pillRect.midY - 5, width: 14, height: 10)
        NSColor(calibratedWhite: 0.92, alpha: 0.95).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 2.2
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: iconRect.minX, y: iconRect.midY))
        line.line(to: NSPoint(x: iconRect.maxX, y: iconRect.midY))
        line.stroke()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1),
            .paragraphStyle: paragraphStyle
        ]
        let textRect = NSRect(x: pillRect.minX + 30, y: pillRect.minY + 8, width: pillRect.width - 42, height: 18)
        NSAttributedString(string: "已最小化", attributes: attributes).draw(in: textRect)

        image.unlockFocus()
        return image
    }

    private func normalize(_ string: String) -> String {
        string
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
    }
}

private extension NSImage {
    func resized(to size: NSSize) -> NSImage {
        guard self.size != size else { return self }

        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        image.unlockFocus()
        return image
    }
}
