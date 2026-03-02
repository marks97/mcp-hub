import SwiftUI

/// Card displaying an MCP server with its enable toggle, tool count badge, and expandable tool list.
struct ServerCardView: View {
    @ObservedObject var server: ServerState
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Server header
            HStack(spacing: 10) {
                Circle()
                    .fill(server.enabled ? Theme.green : Theme.midGray)
                    .frame(width: 8, height: 8)

                Text(server.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(server.enabled ? Theme.textPrimary : Theme.textSecondary)

                Spacer()

                if !server.tools.isEmpty {
                    toolCountBadge
                }

                Toggle("", isOn: Binding(
                    get: { server.enabled },
                    set: { newValue in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            server.enabled = newValue
                        }
                        appState.saveConfig()
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.orange)

                if !server.tools.isEmpty {
                    expandButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Expandable tool list
            if server.isExpanded && !server.tools.isEmpty {
                Divider()
                    .foregroundStyle(Theme.cardBorder)

                VStack(spacing: 0) {
                    ForEach($server.tools) { $tool in
                        ToolRow(tool: $tool, serverEnabled: server.enabled) {
                            appState.saveConfig()
                        }

                        if tool.id != server.tools.last?.id {
                            Divider()
                                .foregroundStyle(Theme.cardBorder)
                                .padding(.leading, 38)
                        }
                    }
                }
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Command info + remove button
            if server.isExpanded {
                Divider()
                    .foregroundStyle(Theme.cardBorder)

                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    Text("\(server.command) \(server.args.joined(separator: " "))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer()

                    Button {
                        withAnimation {
                            appState.removeServer(name: server.name)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                            Text("Remove")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Theme.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .transition(.opacity)
            }
        }
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.cardBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        .opacity(server.enabled ? 1.0 : 0.65)
        .animation(.easeInOut(duration: 0.25), value: server.enabled)
    }

    private var toolCountBadge: some View {
        Text("\(server.enabledToolCount)/\(server.tools.count) tools")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(server.enabled ? Theme.orange : Theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(server.enabled ? Theme.orange.opacity(0.1) : Theme.lightGray.opacity(0.5))
            )
    }

    private var expandButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                server.isExpanded.toggle()
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(server.isExpanded ? 90 : 0))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }
}

/// A single tool row within a server card, showing name, description, and enable toggle.
struct ToolRow: View {
    @Binding var tool: DiscoveredTool
    let serverEnabled: Bool
    let onChange: () -> Void

    private var isActive: Bool { tool.enabled && serverEnabled }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 11))
                .foregroundStyle(isActive ? Theme.orange : Theme.textTertiary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)

                if !tool.description.isEmpty {
                    Text(tool.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
