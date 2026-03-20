import AppKit

/// Generates .icns files with optional badge overlays for wrapper app bundles.
enum IconCompositor {

    /// Standard .iconset entries: (filename, pixel size).
    private static let iconsetEntries: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    /// Generates an .icns file at `outputPath` by compositing the base Claude icon
    /// with an optional badge overlay.
    static func generateIcon(
        badge: BadgeIcon,
        outputPath: String,
        badgeImageLoader: (String) -> NSImage?
    ) throws {
        let fm = FileManager.default

        // No badge — just copy the original icon
        if case .none = badge {
            if let src = findClaudeIcnsPath() {
                try? fm.removeItem(atPath: outputPath)
                try fm.copyItem(atPath: src, toPath: outputPath)
            }
            return
        }

        // Resolve the badge image
        guard let badgeImage = resolveBadgeImage(badge, loader: badgeImageLoader) else {
            // Fallback: copy base icon without badge
            if let src = findClaudeIcnsPath() {
                try? fm.removeItem(atPath: outputPath)
                try fm.copyItem(atPath: src, toPath: outputPath)
            }
            return
        }

        let baseIcon = loadBaseClaudeIcon()

        // Create temporary .iconset directory
        let iconsetPath = NSTemporaryDirectory() + "ClaudeHubBadge.iconset"
        try? fm.removeItem(atPath: iconsetPath)
        try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

        // Generate each resolution
        for (filename, pixelSize) in iconsetEntries {
            let composited = compositeIcon(base: baseIcon, badge: badgeImage, size: CGFloat(pixelSize))
            if let png = pngData(from: composited) {
                try png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(filename)"))
            }
        }

        // Convert .iconset → .icns
        try? fm.removeItem(atPath: outputPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["--convert", "icns", "--output", outputPath, iconsetPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        // Cleanup
        try? fm.removeItem(atPath: iconsetPath)
    }

    /// Renders a small preview of the composited icon for inline UI display.
    static func previewIcon(badge: BadgeIcon, size: CGFloat, loader: (String) -> NSImage?) -> NSImage {
        let baseIcon = loadBaseClaudeIcon()
        guard let badgeImage = resolveBadgeImage(badge, loader: loader) else {
            return compositeIcon(base: baseIcon, badge: nil, size: size)
        }
        return compositeIcon(base: baseIcon, badge: badgeImage, size: size)
    }

    // MARK: - Private

    private static func findClaudeIcnsPath() -> String? {
        [
            "/Applications/Claude.app/Contents/Resources/AppIcon.icns",
            "/Applications/Claude.app/Contents/Resources/icon.icns",
            "/Applications/Claude.app/Contents/Resources/electron.icns",
        ].first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func loadBaseClaudeIcon() -> NSImage {
        if let path = findClaudeIcnsPath(), let img = NSImage(contentsOfFile: path) {
            return img
        }
        return NSWorkspace.shared.icon(forFile: "/Applications/Claude.app")
    }

    private static func resolveBadgeImage(_ badge: BadgeIcon, loader: (String) -> NSImage?) -> NSImage? {
        switch badge {
        case .none:
            return nil
        case .sfSymbol(let name):
            return renderSFSymbol(name: name)
        case .customImage(let filename):
            return loader(filename)
        }
    }

    private static func renderSFSymbol(name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }

        // Render to a fixed bitmap
        let canvasSize = NSSize(width: 128, height: 128)
        return NSImage(size: canvasSize, flipped: false) { rect in
            let symbolSize = symbol.size
            let origin = NSPoint(
                x: (rect.width - symbolSize.width) / 2,
                y: (rect.height - symbolSize.height) / 2
            )
            symbol.draw(in: NSRect(origin: origin, size: symbolSize))
            return true
        }
    }

    private static func compositeIcon(base: NSImage, badge: NSImage?, size: CGFloat) -> NSImage {
        let outputSize = NSSize(width: size, height: size)
        return NSImage(size: outputSize, flipped: false) { rect in
            // Draw base icon
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)

            // Draw badge if present and icon is large enough to show it
            if let badge, size >= 32 {
                let badgeDiameter = size * 0.35
                let padding = size * 0.02
                let badgeRect = NSRect(
                    x: size - badgeDiameter - padding,
                    y: padding,
                    width: badgeDiameter,
                    height: badgeDiameter
                )

                guard let context = NSGraphicsContext.current?.cgContext else { return true }

                // Drop shadow
                context.saveGState()
                context.setShadow(
                    offset: CGSize(width: 0, height: -1),
                    blur: size * 0.02,
                    color: NSColor.black.withAlphaComponent(0.3).cgColor
                )

                // White circle background
                NSColor.white.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
                context.restoreGState()

                // Badge image inset inside the circle
                let inset = badgeDiameter * 0.2
                let imageRect = badgeRect.insetBy(dx: inset, dy: inset)
                badge.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            return true
        }
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }
}
