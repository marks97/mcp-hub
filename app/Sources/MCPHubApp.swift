import SwiftUI
import AppKit

/// Swizzles NSColor.controlAccentColor to return brand orange,
/// forcing the sidebar selection highlight to use it.
class ControlAccentOverride: NSObject {
    static var customColor: NSColor = .controlAccentColor
    private static var installed = false

    static func install(color: NSColor) {
        customColor = color
        guard !installed else { return }
        installed = true

        let original = class_getClassMethod(NSColor.self, #selector(getter: NSColor.controlAccentColor))!
        let replacement = class_getClassMethod(ControlAccentOverride.self, #selector(ControlAccentOverride.overrideAccentColor))!
        method_exchangeImplementations(original, replacement)
    }

    @objc dynamic static func overrideAccentColor() -> NSColor {
        return customColor
    }
}

/// Forces the sidebar selection highlight to use the brand orange
/// instead of the system-wide accent color.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ControlAccentOverride.install(
            color: NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1.0) // #D97757
        )
    }
}

/// Entry point for the Claude Hub application.
@main
struct ClaudeHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appState)
                .tint(Theme.orange)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
