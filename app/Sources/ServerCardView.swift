import SwiftUI

/// Card displaying an MCP server with its enable toggle, tool count badge, and expandable tool list.
struct ServerCardView: View {
    @ObservedObject var server: ServerState
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(server.enabled ? Theme.green : Theme.toggleOff)
                    .frame(width: 7, height: 7)

                Text(server.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(server.enabled ? Theme.textPrimary : Theme.textSecondary)

                Spacer()

                if !server.tools.isEmpty {
                    Text("\(server.enabledToolCount)/\(server.tools.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.trailing, 4)
                }

                Toggle("", isOn: Binding(
                    get: { server.enabled },
                    set: { newValue in
                        server.enabled = newValue
                        appState.saveConfig()
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.orange)

                if !server.tools.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            server.isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: server.isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if server.isExpanded && !server.tools.isEmpty {
                Divider()
                    .background(Theme.cardBorder)

                VStack(spacing: 0) {
                    ForEach($server.tools) { $tool in
                        ToolRow(tool: $tool, serverEnabled: server.enabled) {
                            appState.saveConfig()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.cardBorder, lineWidth: 0.5)
        )
        .opacity(server.enabled ? 1.0 : 0.6)
    }
}

/// A single tool row within a server card, showing name, description, and enable toggle.
struct ToolRow: View {
    @Binding var tool: DiscoveredTool
    let serverEnabled: Bool
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench")
                .font(.system(size: 9))
                .foregroundStyle(tool.enabled && serverEnabled ? Theme.orange : Theme.textTertiary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(tool.enabled && serverEnabled ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)

                if !tool.description.isEmpty {
                    Text(tool.description)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { tool.enabled },
                set: { newValue in
                    tool.enabled = newValue
                    onChange()
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.orange)
            .disabled(!serverEnabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
