import SwiftUI

/// Modal for creating or editing a user-defined Docker image template.
/// Built-in images are not edited here directly — users duplicate them first
/// from the cloud-instance image picker.
struct DockerImageEditorSheet: View {
    @EnvironmentObject var appState: AppState

    @State private var name: String = ""
    @State private var dockerfile: String = ""
    @State private var entrypoint: String = ""
    @State private var isExistingImage: Bool = false
    @State private var existingId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isExistingImage ? "Edit Docker Image" : "New Docker Image")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    appState.closeImageEditorAndResumeCloudInstanceSheet()
                } label: {
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
                    fieldGroup(label: "Name") {
                        TextField("e.g. Default + Tailscale", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    fieldGroup(label: "Dockerfile") {
                        TextEditor(text: $dockerfile)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(minHeight: 240)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.smallCornerRadius)
                                    .stroke(Theme.cardBorder, lineWidth: 1)
                            )
                    }

                    fieldGroup(label: "Entrypoint (entrypoint.sh)") {
                        TextEditor(text: $entrypoint)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(minHeight: 160)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.smallCornerRadius)
                                    .stroke(Theme.cardBorder, lineWidth: 1)
                            )
                    }

                    Text("The gateway/ folder is added to the build context automatically and copied into the image during build.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.closeImageEditorAndResumeCloudInstanceSheet()
                }
                .keyboardShortcut(.cancelAction)

                Button(isExistingImage ? "Save" : "Create") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 720, height: 640)
        .onAppear {
            if let img = appState.editingDockerImage {
                name = img.name
                dockerfile = img.dockerfile
                entrypoint = img.entrypoint
                isExistingImage = true
                existingId = img.id
            } else {
                // New: prefill from bundled default so the user has a working baseline.
                let bundled = DockerImageBuilder.bundledDefaultImage()
                name = "New Image"
                dockerfile = bundled.dockerfile
                entrypoint = bundled.entrypoint
                isExistingImage = false
                existingId = nil
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !dockerfile.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let savedId: UUID
        if let id = existingId, let existing = appState.dockerImages.first(where: { $0.id == id }) {
            var updated = existing
            updated.name = trimmedName
            updated.dockerfile = dockerfile
            updated.entrypoint = entrypoint
            appState.updateDockerImage(updated)
            savedId = updated.id
        } else {
            let new = DockerImage(
                name: trimmedName,
                dockerfile: dockerfile,
                entrypoint: entrypoint,
                isBuiltIn: false
            )
            appState.addDockerImage(new)
            savedId = new.id
        }
        // Pre-select the just-saved image in the resumed form.
        appState.cloudInstanceDraft?.dockerImageId = savedId
        appState.closeImageEditorAndResumeCloudInstanceSheet()
    }

    private func fieldGroup<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}
