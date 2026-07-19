import AppKit

enum AppIconFactory {
    static func appIcon(size: CGFloat = 128) -> NSImage {
        if let bundledIcon = bundledAppIcon(size: size) {
            return bundledIcon
        }

        return fallbackAppIcon(size: size)
    }

    private static func bundledAppIcon(size: CGFloat) -> NSImage? {
        let iconFromCatalog = NSImage(named: "AppIcon")
        let iconFromResource = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
        guard let image = iconFromCatalog ?? iconFromResource else {
            return nil
        }

        image.size = NSSize(width: size, height: size)
        return image
    }

    private static func fallbackAppIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let scale = size / 128
        func r(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
        }

        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        let backgroundShadow = NSShadow()
        backgroundShadow.shadowBlurRadius = 10 * scale
        backgroundShadow.shadowOffset = NSSize(width: 0, height: -2 * scale)
        backgroundShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.12)
        NSGraphicsContext.saveGraphicsState()
        backgroundShadow.set()

        let background = NSBezierPath(roundedRect: r(10, 10, 108, 108), xRadius: 28 * scale, yRadius: 28 * scale)
        NSGradient(colors: [
            NSColor(calibratedWhite: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.99, alpha: 1)
        ])?.draw(in: background, angle: 225)
        NSGraphicsContext.restoreGraphicsState()

        let subtleRing = NSBezierPath(roundedRect: r(10.75, 10.75, 106.5, 106.5), xRadius: 27 * scale, yRadius: 27 * scale)
        NSColor(calibratedWhite: 0, alpha: 0.06).setStroke()
        subtleRing.lineWidth = 1 * scale
        subtleRing.stroke()

        let accentStart = NSColor(calibratedRed: 0.50, green: 0.39, blue: 0.88, alpha: 1)
        let accentEnd = NSColor(calibratedRed: 1.00, green: 0.57, blue: 0.48, alpha: 1)
        let surface = NSBezierPath(roundedRect: r(32, 33, 64, 63), xRadius: 19 * scale, yRadius: 19 * scale)
        NSGradient(colors: [
            accentStart,
            accentEnd
        ])?.draw(in: surface, angle: 315)

        let surfaceHighlight = NSBezierPath(roundedRect: r(34, 35, 60, 59), xRadius: 17 * scale, yRadius: 17 * scale)
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        surfaceHighlight.lineWidth = 1.4 * scale
        surfaceHighlight.stroke()

        let backCard = NSBezierPath(roundedRect: r(47, 61, 39, 23), xRadius: 7 * scale, yRadius: 7 * scale)
        NSColor(calibratedWhite: 1, alpha: 0.34).setFill()
        backCard.fill()

        let cardShadow = NSShadow()
        cardShadow.shadowBlurRadius = 8 * scale
        cardShadow.shadowOffset = NSSize(width: 0, height: -2 * scale)
        cardShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.18)
        NSGraphicsContext.saveGraphicsState()
        cardShadow.set()
        let mainCard = NSBezierPath(roundedRect: r(40, 49, 50, 31), xRadius: 8 * scale, yRadius: 8 * scale)
        NSColor(calibratedWhite: 1, alpha: 0.94).setFill()
        mainCard.fill()
        NSGraphicsContext.restoreGraphicsState()

        let titleBar = NSBezierPath(roundedRect: r(45, 68, 40, 4), xRadius: 2 * scale, yRadius: 2 * scale)
        accentStart.withAlphaComponent(0.20).setFill()
        titleBar.fill()

        let contentLine = NSBezierPath(roundedRect: r(48, 59, 34, 5), xRadius: 2.5 * scale, yRadius: 2.5 * scale)
        NSColor(calibratedWhite: 0.72, alpha: 0.26).setFill()
        contentLine.fill()

        let dock = NSBezierPath(roundedRect: r(44, 38, 40, 7), xRadius: 3.5 * scale, yRadius: 3.5 * scale)
        NSColor(calibratedWhite: 1, alpha: 0.72).setFill()
        dock.fill()

        let activeIndicator = NSBezierPath(roundedRect: r(58, 33, 12, 3), xRadius: 1.5 * scale, yRadius: 1.5 * scale)
        NSColor(calibratedWhite: 1, alpha: 0.58).setFill()
        activeIndicator.fill()

        image.unlockFocus()
        return image
    }

    static func statusBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        defer { image.unlockFocus() }

        func window(_ rect: NSRect, radius: CGFloat, width: CGFloat, alpha: CGFloat) {
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = width
            path.lineJoinStyle = .round
            NSColor.black.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }

        window(NSRect(x: 2.0, y: 6.4, width: 11.8, height: 8.2), radius: 2.2, width: 1.3, alpha: 0.45)
        window(NSRect(x: 4.2, y: 7.5, width: 11.8, height: 8.2), radius: 2.2, width: 1.45, alpha: 1)

        let dock = NSBezierPath()
        dock.move(to: NSPoint(x: 2.6, y: 3.4))
        dock.line(to: NSPoint(x: 15.4, y: 3.4))
        dock.lineWidth = 1.7
        dock.lineCapStyle = .round
        NSColor.black.setStroke()
        dock.stroke()

        image.isTemplate = true
        image.accessibilityDescription = "Y-Dock 窗口预览"
        return image
    }
}
