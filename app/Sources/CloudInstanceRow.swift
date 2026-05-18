import SwiftUI

/// A single cloud instance row in the sidebar.
struct CloudInstanceRow: View {
    let instance: CloudInstance
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    private var isSelected: Bool {
        appState.selectedCloudInstance?.id == instance.id
    }

    private var runtimeInfo: CloudInstanceRuntimeInfo {
        appState.cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
    }

    var body: some View {
        HStack(spacing: 8) {
            CloudInstanceAvatar(instance: instance, size: 24, isSelected: isSelected)

            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)

                Text(instance.type.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            statusDot

            if isHovered {
                Button {
                    appState.removeCloudInstance(instance)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.red)
                }
                .buttonStyle(.plain)
                .help("Remove instance")
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.blue.opacity(0.15) : isHovered ? Theme.midGray.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectCloudInstance(instance)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(role: .destructive) {
                appState.removeCloudInstance(instance)
            } label: {
                Label("Remove Instance", systemImage: "trash")
            }
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 6, height: 6)
    }

    private var statusColor: Color {
        switch runtimeInfo.status {
        case .running: return Theme.green
        case .starting, .stopping, .terminating: return Theme.orange
        case .stopped, .terminated: return Theme.red
        case .unknown: return Theme.midGray
        }
    }
}

/// Icon avatar for a cloud instance based on its type.
struct CloudInstanceAvatar: View {
    let instance: CloudInstance
    let size: CGFloat
    var isSelected: Bool = false

    var body: some View {
        Image(systemName: instance.type.iconName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(isSelected ? Theme.blue : Theme.textSecondary))
    }
}
