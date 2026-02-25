import SwiftUI

/// Visual theme constants for the MCPHub menu bar interface.
enum Theme {
    static let light = Color(hex: "FAF9F5")
    static let orange = Color(hex: "D97757")
    static let green = Color(hex: "788C5D")

    static let panelBackground = Color(hex: "FAF9F5")
    static let cardBackground = Color.white
    static let cardBorder = Color(hex: "E8E6DC")
    static let textPrimary = Color(hex: "141413")
    static let textSecondary = Color(hex: "6B6961")
    static let textTertiary = Color(hex: "B0AEA5")

    static let toggleOn = orange
    static let toggleOff = Color(hex: "E8E6DC")

    static let cornerRadius: CGFloat = 8
    static let smallCornerRadius: CGFloat = 6
    static let panelWidth: CGFloat = 340
}

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)
        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double((rgbValue & 0x0000FF)) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
