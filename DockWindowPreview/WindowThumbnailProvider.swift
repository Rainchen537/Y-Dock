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

    private struct PreviewThumbnailKey: Hashable {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let normalizedTitle: String
        let roundedWindowWidth: Int
        let roundedWindowHeight: Int
        let targetWidth: Int
        let targetHeight: Int
        let isMinimized: Bool
    }

    private struct CachedPreviewThumbnail {
        let image: NSImage
        let createdAt: TimeInterval
    }

    private var snapshotCache: [WindowSnapshotKey: NSImage] = [:]
    private var titleFallbackCache: [WindowTitleKey: NSImage] = [:]
    private var previewThumbnailCache: [PreviewThumbnailKey: CachedPreviewThumbnail] = [:]
    private var cacheOrder: [WindowSnapshotKey] = []
    private var previewCacheOrder: [PreviewThumbnailKey] = []
    private let cacheLock = NSLock()
    private let maximumCachedSnapshots = 80
    private let maximumCachedPreviewThumbnails = 180
    private let previewThumbnailCacheTTL: TimeInterval = 8.0

    func thumbnail(for window: WindowInfo, targetSize: NSSize) -> NSImage {
        let previewKey = previewThumbnailKey(for: window, targetSize: targetSize)
        if let cachedImage = cachedPreviewThumbnail(for: previewKey) {
            return cachedImage
        }

        let image: NSImage
        if window.isMinimized {
            if let capturedImage = captureWindowImage(for: window, targetSize: targetSize) {
                cache(capturedImage, for: window)
                image = minimizedOverlayImage(base: capturedImage, title: window.title, size: targetSize)
                cachePreviewThumbnail(image, for: previewKey)
                return image
            }

            if let cachedImage = cachedThumbnail(for: window, targetSize: targetSize) {
                image = minimizedOverlayImage(base: cachedImage, title: window.title, size: targetSize)
                cachePreviewThumbnail(image, for: previewKey)
                return image
            }

            image = placeholderImage(title: window.title, reason: "已最小化", size: targetSize)
            cachePreviewThumbnail(image, for: previewKey)
            return image
        }

        if let capturedImage = captureWindowImage(for: window, targetSize: targetSize) {
            cache(capturedImage, for: window)
            cachePreviewThumbnail(capturedImage, for: previewKey)
            return capturedImage
        }

        let reason = CGPreflightScreenCaptureAccess() ? "无法截图" : "需要屏幕录制权限"
        DWLog("Failed to capture thumbnail for window \(window.windowID), reason: \(reason)")
        image = placeholderImage(title: window.title, reason: reason, size: targetSize)
        cachePreviewThumbnail(image, for: previewKey)
        return image
    }

    func placeholderThumbnail(for window: WindowInfo, targetSize: NSSize, reason: String = "正在载入") -> NSImage {
        placeholderImage(title: window.title, reason: reason, size: targetSize)
    }

    func focusImage(for window: WindowInfo, targetSize: NSSize) -> NSImage? {
        if let capturedImage = captureWindowImage(for: window, targetSize: targetSize) {
            cache(capturedImage, for: window)
            return capturedImage
        }

        return cachedThumbnail(for: window, targetSize: targetSize)
    }

    func warmThumbnails(for windows: [WindowInfo], settings: AppSettings) {
        guard !windows.isEmpty else { return }

        autoreleasepool {
            for window in windows {
                let size = settings.thumbnailSize(for: window)
                _ = thumbnail(for: window, targetSize: size)
            }
        }
    }

    func invalidatePreviewCache(ownerPID: pid_t) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        previewThumbnailCache = previewThumbnailCache.filter { $0.key.ownerPID != ownerPID }
        previewCacheOrder.removeAll { $0.ownerPID == ownerPID }
    }

    private func captureWindowImage(for window: WindowInfo, targetSize _: NSSize) -> NSImage? {
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, window.windowID, options) else {
            return nil
        }

        guard cgImage.width >= 8, cgImage.height >= 8 else {
            return nil
        }

        let imageSize = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        return NSImage(cgImage: cgImage, size: imageSize)
    }

    private func cachedThumbnail(for window: WindowInfo, targetSize: NSSize) -> NSImage? {
        let exactKey = snapshotKey(for: window)
        let titleKey = WindowTitleKey(ownerPID: window.ownerPID, normalizedTitle: normalize(window.title))

        cacheLock.lock()
        let exactImage = snapshotCache[exactKey]
        let titleImage = titleFallbackCache[titleKey]
        cacheLock.unlock()

        if let image = exactImage {
            return image.resized(to: targetSize)
        }

        if let image = titleImage {
            DWLog("Using title fallback snapshot for minimized window '\(window.title)'")
            return image.resized(to: targetSize)
        }

        return nil
    }

    private func cache(_ image: NSImage, for window: WindowInfo) {
        let exactKey = snapshotKey(for: window)
        let titleKey = WindowTitleKey(ownerPID: window.ownerPID, normalizedTitle: normalize(window.title))

        cacheLock.lock()
        defer { cacheLock.unlock() }

        snapshotCache[exactKey] = image

        titleFallbackCache[titleKey] = image

        cacheOrder.removeAll { $0 == exactKey }
        cacheOrder.append(exactKey)

        while cacheOrder.count > maximumCachedSnapshots {
            let removedKey = cacheOrder.removeFirst()
            snapshotCache.removeValue(forKey: removedKey)
        }
    }

    private func cachedPreviewThumbnail(for key: PreviewThumbnailKey) -> NSImage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let cached = previewThumbnailCache[key] else { return nil }

        let age = Date.timeIntervalSinceReferenceDate - cached.createdAt
        guard age <= previewThumbnailCacheTTL else {
            previewThumbnailCache.removeValue(forKey: key)
            previewCacheOrder.removeAll { $0 == key }
            return nil
        }

        return cached.image
    }

    private func cachePreviewThumbnail(_ image: NSImage, for key: PreviewThumbnailKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        previewThumbnailCache[key] = CachedPreviewThumbnail(
            image: image,
            createdAt: Date.timeIntervalSinceReferenceDate
        )

        previewCacheOrder.removeAll { $0 == key }
        previewCacheOrder.append(key)

        while previewCacheOrder.count > maximumCachedPreviewThumbnails {
            let removedKey = previewCacheOrder.removeFirst()
            previewThumbnailCache.removeValue(forKey: removedKey)
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

    private func previewThumbnailKey(for window: WindowInfo, targetSize: NSSize) -> PreviewThumbnailKey {
        PreviewThumbnailKey(
            windowID: window.windowID,
            ownerPID: window.ownerPID,
            normalizedTitle: normalize(window.title),
            roundedWindowWidth: roundedDimension(window.bounds.width),
            roundedWindowHeight: roundedDimension(window.bounds.height),
            targetWidth: Int(max(1, targetSize.width).rounded()),
            targetHeight: Int(max(1, targetSize.height).rounded()),
            isMinimized: window.isMinimized
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
        let horizontalInset = min(12, max(2, size.width * 0.12))
        let textRect = NSRect(
            x: horizontalInset,
            y: (size.height - 44) / 2,
            width: max(1, size.width - horizontalInset * 2),
            height: 44
        )
        attributed.draw(in: textRect)

        image.unlockFocus()
        return image
    }

    private func minimizedOverlayImage(base: NSImage, title: String, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        NSGraphicsContext.current?.imageInterpolation = .high
        base.drawAspectFit(in: rect, operation: .copy, fraction: 1)

        NSColor(calibratedWhite: 0, alpha: 0.40).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()

        let pillInset = min(14, max(2, size.width * 0.12))
        let pillWidth = min(max(68, size.width * 0.56), max(1, size.width - pillInset * 2))
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

        let showsIcon = pillRect.width >= 82
        if showsIcon {
            let iconRect = NSRect(x: pillRect.minX + 14, y: pillRect.midY - 5, width: 14, height: 10)
            NSColor(calibratedWhite: 0.92, alpha: 0.95).setStroke()
            let line = NSBezierPath()
            line.lineWidth = 2.2
            line.lineCapStyle = .round
            line.move(to: NSPoint(x: iconRect.minX, y: iconRect.midY))
            line.line(to: NSPoint(x: iconRect.maxX, y: iconRect.midY))
            line.stroke()
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1),
            .paragraphStyle: paragraphStyle
        ]
        let textInset: CGFloat = showsIcon ? 30 : 8
        let trailingInset: CGFloat = showsIcon ? 12 : 8
        let textRect = NSRect(
            x: pillRect.minX + textInset,
            y: pillRect.minY + 8,
            width: max(1, pillRect.width - textInset - trailingInset),
            height: 18
        )
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
        drawAspectFit(in: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        image.unlockFocus()
        return image
    }

    func drawAspectFit(
        in rect: NSRect,
        operation: NSCompositingOperation,
        fraction: CGFloat
    ) {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else {
            draw(in: rect, from: .zero, operation: operation, fraction: fraction)
            return
        }

        let sourceAspect = size.width / size.height
        let targetAspect = rect.width / rect.height
        let drawSize: NSSize

        if sourceAspect > targetAspect {
            drawSize = NSSize(width: rect.width, height: rect.width / sourceAspect)
        } else {
            drawSize = NSSize(width: rect.height * sourceAspect, height: rect.height)
        }

        let drawRect = NSRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        draw(in: drawRect, from: .zero, operation: operation, fraction: fraction)
    }
}
