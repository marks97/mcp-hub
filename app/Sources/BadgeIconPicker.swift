import SwiftUI
import AppKit

/// Popover for selecting a badge icon overlay for a project's Dock icon.
struct BadgeIconPicker: View {
    @EnvironmentObject var appState: AppState
    let project: Project
    @Binding var isPresented: Bool

    @State private var selectedTab = 0 // 0=None, 1=SF Symbol, 2=Image
    @State private var sfSymbolName = ""
    @State private var customImage: NSImage?
    @State private var customFilename: String?

    private let suggestedSymbols = [
        "globe", "hammer", "wrench", "desktopcomputer", "iphone",
        "cloud", "bolt", "leaf", "flame", "star",
        "heart", "shield", "lock", "key", "doc",
        "folder", "tray", "archivebox", "book", "pencil",
        "paintbrush", "wand.and.stars", "ant", "ladybug", "terminal",
        "chevron.left.forwardslash.chevron.right", "curlybraces",
        "number", "chart.bar", "cart",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text("Badge Icon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Preview
            iconPreview
                .padding(.bottom, 12)

            Picker("", selection: $selectedTab) {
                Text("None").tag(0)
                Text("SF Symbol").tag(1)
                Text("Image").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            Divider().padding(.top, 12)

            Group {
                switch selectedTab {
                case 1: sfSymbolTab
                case 2: customImageTab
                default: noneTab
                }
            }
            .frame(height: 180)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { applyBadge() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 320)
        .onAppear { loadExisting() }
    }

    // MARK: - Preview

    private var iconPreview: some View {
        let badge = currentBadge
        let preview = IconCompositor.previewIcon(
            badge: badge,
            size: 64,
            loader: { filename in
                if let img = customImage, filename == customFilename { return img }
                return appState.loadBadgeImage(filename: filename)
            }
        )
        return Image(nsImage: preview)
            .resizable()
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }

    private var currentBadge: BadgeIcon {
        switch selectedTab {
        case 1:
            if !sfSymbolName.isEmpty,
               NSImage(systemSymbolName: sfSymbolName, accessibilityDescription: nil) != nil {
                return .sfSymbol(sfSymbolName)
            }
            return .none
        case 2:
            if let filename = customFilename {
                return .customImage(filename)
            }
            return .none
        default:
            return .none
        }
    }

    // MARK: - Tabs

    private var noneTab: some View {
        VStack {
            Spacer()
            Image(systemName: "app")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text("No badge — uses the default Claude icon")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    private var sfSymbolTab: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textTertiary)
                TextField("SF Symbol name (e.g. globe)", text: $sfSymbolName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !sfSymbolName.isEmpty {
                    if NSImage(systemSymbolName: sfSymbolName, accessibilityDescription: nil) != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.green)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.red)
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pampas))
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 4), count: 7), spacing: 4) {
                    ForEach(suggestedSymbols, id: \.self) { name in
                        Button {
                            sfSymbolName = name
                        } label: {
                            Image(systemName: name)
                                .font(.system(size: 14))
                                .frame(width: 32, height: 32)
                                .foregroundStyle(sfSymbolName == name ? Theme.orange : Theme.textSecondary)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(sfSymbolName == name ? Theme.orange.opacity(0.12) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private var customImageTab: some View {
        VStack(spacing: 12) {
            Spacer()
            if let img = customImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.textTertiary)
            }
            Button("Choose Image...") { chooseImage() }
                .font(.system(size: 12))
            Spacer()
        }
        .padding()
    }

    // MARK: - Actions

    private func loadExisting() {
        switch project.badgeIcon {
        case .none:
            selectedTab = 0
        case .sfSymbol(let name):
            selectedTab = 1
            sfSymbolName = name
        case .customImage(let filename):
            selectedTab = 2
            customFilename = filename
            customImage = appState.loadBadgeImage(filename: filename)
        }
    }

    private func chooseImage() {
        // Capture references before the popover closes
        let appState = appState
        let project = project

        let panel = NSOpenPanel()
        panel.title = "Choose a badge image"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let image = NSImage(contentsOf: url) else { return }
            // Apply immediately — popover will have closed when panel took focus
            if let filename = appState.saveBadgeImage(image) {
                DispatchQueue.main.async {
                    appState.updateBadgeIcon(for: project, badge: .customImage(filename))
                }
            }
        }
    }

    private func applyBadge() {
        let badge: BadgeIcon
        switch selectedTab {
        case 1:
            if !sfSymbolName.isEmpty,
               NSImage(systemSymbolName: sfSymbolName, accessibilityDescription: nil) != nil {
                badge = .sfSymbol(sfSymbolName)
            } else {
                badge = .none
            }
        case 2:
            if let filename = customFilename {
                badge = .customImage(filename)
            } else {
                badge = .none
            }
        default:
            badge = .none
        }

        appState.updateBadgeIcon(for: project, badge: badge)
        isPresented = false
    }
}
