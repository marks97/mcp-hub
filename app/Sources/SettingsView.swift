import SwiftUI

/// macOS Settings window (Cmd+,).
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var newRegistryURL = ""

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { appState.settings.projectIsolation },
                    set: { newValue in
                        appState.settings.projectIsolation = newValue
                        appState.saveSettings()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Project Isolation")
                            .font(.system(size: 13, weight: .medium))
                        Text("Each project runs its own Claude Desktop instance in an isolated data directory at ~/claude-{project-name}. Multiple projects can run Claude simultaneously.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Claude Desktop")
            }

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
                                .foregroundStyle(.red)
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
        .frame(width: 500, height: 340)
    }

    private func addRegistryURL() {
        let url = newRegistryURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !appState.settings.registryURLs.contains(url) else { return }
        appState.settings.registryURLs.append(url)
        appState.saveSettings()
        newRegistryURL = ""
    }
}
