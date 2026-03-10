import SwiftUI

/// macOS Settings window (Cmd+,).
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var newRegistryURL = ""

    private var previewName: String {
        appState.settings.isolationDisplayName(for: "MyProject")
    }

    var body: some View {
        Form {
            // MARK: - Isolation Naming
            Section {
                HStack {
                    Text("Prefix")
                        .frame(width: 50, alignment: .leading)
                    TextField("e.g. Claude - ", text: $appState.settings.isolationPrefix)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: appState.settings.isolationPrefix) { _, _ in
                            appState.saveSettings()
                        }
                }

                HStack {
                    Text("Suffix")
                        .frame(width: 50, alignment: .leading)
                    TextField("e.g.  (Claude)", text: $appState.settings.isolationSuffix)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: appState.settings.isolationSuffix) { _, _ in
                            appState.saveSettings()
                        }
                }

                HStack(spacing: 4) {
                    Text("Dock name:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(previewName)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.orange)
                }
            } header: {
                Text("Isolated Instance Naming")
            } footer: {
                Text("Isolated Claude instances show as separate apps in the Dock. Configure how their names appear.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // MARK: - Marketplace Sources
            Section {
                ForEach(appState.settings.registryURLs, id: \.self) { url in
                    HStack {
                        Text(url)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            appState.settings.registryURLs.removeAll { $0 == url }
                            appState.saveSettings()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Theme.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.settings.registryURLs.count <= 1)
                    }
                }

                HStack {
                    TextField("https://registry.example.com/servers", text: $newRegistryURL)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addRegistryURL() }

                    Button("Add") { addRegistryURL() }
                        .disabled(newRegistryURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Marketplace Sources")
            } footer: {
                Text("Registry URLs used to browse and install MCP servers.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 360)
    }

    private func addRegistryURL() {
        let url = newRegistryURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !appState.settings.registryURLs.contains(url) else { return }
        appState.settings.registryURLs.append(url)
        appState.saveSettings()
        newRegistryURL = ""
    }
}
