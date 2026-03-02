import SwiftUI

/// Sheet for manually adding a new MCP server to a project.
struct AddServerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State var serverName = ""
    @State var command = ""
    @State var args = ""
    @State var envPairs: [EnvPair] = [EnvPair()]

    struct EnvPair: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add MCP Server")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fieldGroup(label: "Server Name") {
                        TextField("e.g. my-server", text: $serverName)
                            .textFieldStyle(.roundedBorder)
                    }

                    fieldGroup(label: "Command") {
                        TextField("e.g. npx, uvx, docker", text: $command)
                            .textFieldStyle(.roundedBorder)
                    }

                    fieldGroup(label: "Arguments") {
                        TextField("e.g. -y @modelcontextprotocol/server-name", text: $args)
                            .textFieldStyle(.roundedBorder)
                        Text("Space-separated arguments")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }

                    fieldGroup(label: "Environment Variables") {
                        VStack(spacing: 8) {
                            ForEach($envPairs) { $pair in
                                HStack(spacing: 8) {
                                    TextField("KEY", text: $pair.key)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 160)
                                    TextField("value", text: $pair.value)
                                        .textFieldStyle(.roundedBorder)
                                    Button {
                                        envPairs.removeAll { $0.id == pair.id }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(Theme.red)
                                    }
                                    .buttonStyle(.plain)
                                    .opacity(envPairs.count > 1 ? 1 : 0.3)
                                    .disabled(envPairs.count <= 1)
                                }
                            }
                            Button {
                                envPairs.append(EnvPair())
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Add Variable")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.orange)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Add Server") { addServer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(serverName.trimmingCharacters(in: .whitespaces).isEmpty ||
                              command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 500)
    }

    private func fieldGroup<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func addServer() {
        let name = serverName.trimmingCharacters(in: .whitespaces)
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !cmd.isEmpty else { return }

        let argsList = args.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }

        var env: [String: String] = [:]
        for pair in envPairs {
            let k = pair.key.trimmingCharacters(in: .whitespaces)
            let v = pair.value.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { env[k] = v }
        }

        let config = MCPServerConfig(
            command: cmd,
            args: argsList.isEmpty ? nil : argsList,
            env: env.isEmpty ? nil : env
        )

        appState.addServer(name: name, config: config)
        dismiss()
    }
}
