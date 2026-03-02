import SwiftUI

/// Sheet for browsing and installing servers from the MCP registry.
struct MarketplaceSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var searchQuery = ""
    @State private var results: [RegistryServer] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var showAddSheet = false
    @State private var prefillName = ""
    @State private var prefillCommand = ""
    @State private var prefillArgs = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("MCP Marketplace")
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

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search MCP servers...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { search() }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(10)
            .background(Theme.pampas)
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
            .padding(.horizontal, 20)

            Divider()
                .padding(.top, 12)

            // Results
            if let error = errorMessage {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.red)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if results.isEmpty && !isSearching {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.textTertiary)
                    Text("Search the official MCP registry")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Find servers to add to your project")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(results) { server in
                            serverRow(server)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 550, height: 500)
        .sheet(isPresented: $showAddSheet) {
            AddServerSheet(
                serverName: prefillName,
                command: prefillCommand,
                args: prefillArgs
            )
            .environmentObject(appState)
        }
        .onAppear { search() }
    }

    private func serverRow(_ server: RegistryServer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 16))
                .foregroundStyle(Theme.blue)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(server.server.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                if let desc = server.server.description {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }

                if let packages = server.server.packages, let first = packages.first {
                    HStack(spacing: 4) {
                        Text(first.registryType)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.blue.opacity(0.1))
                            .clipShape(Capsule())

                        Text(first.identifier)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Button {
                addFromRegistry(server)
            } label: {
                Text("Add")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Theme.orange)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.cardBorder, lineWidth: 0.5)
        )
    }

    private func search() {
        isSearching = true
        errorMessage = nil

        appState.searchRegistry(query: searchQuery) { result in
            isSearching = false
            switch result {
            case .success(let servers):
                results = servers
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addFromRegistry(_ server: RegistryServer) {
        guard let pkg = server.server.packages?.first else {
            prefillName = server.server.name
            prefillCommand = ""
            prefillArgs = ""
            showAddSheet = true
            return
        }

        prefillName = server.server.name

        switch pkg.registryType {
        case "npm":
            prefillCommand = "npx"
            prefillArgs = "-y \(pkg.identifier)"
        case "pypi":
            prefillCommand = "uvx"
            prefillArgs = pkg.identifier
        case "docker":
            prefillCommand = "docker"
            prefillArgs = "run --rm -i \(pkg.identifier)"
        default:
            prefillCommand = pkg.identifier
            prefillArgs = ""
        }

        showAddSheet = true
    }
}
