import SwiftUI

/// Sheet for creating a new cloud instance.
struct AddCloudInstanceSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var instanceType: CloudInstanceType = .ec2

    // EC2 — minimal fields, rest is auto-provisioned
    @State private var ec2Region = "us-east-1"
    @State private var ec2InstanceType = "t3.small"
    @State private var ec2VolumeGB = "30"

    // SSH — connect to existing machine
    @State private var sshHost = ""
    @State private var sshUser = ""
    @State private var sshPort = "22"
    @State private var sshKeyPath = ""
    @State private var sshTestResult: String?
    @State private var sshTesting = false

    // Fargate — serverless container
    @State private var fargateRegion = "us-east-1"
    @State private var fargateImage = ""    // empty = use default Claude Hub image (build + push to ECR)
    @State private var fargateUseDefault = true
    @State private var fargateCpu = "1024"
    @State private var fargateMemory = "2048"

    // Docker — local container
    @State private var dockerImage = "ubuntu:24.04"
    @State private var dockerContainerName = ""

    // Credentials source
    @State private var credentialsSource = "" // project path, or "" for Keychain/system

    // Selected Docker image template (EC2 only). nil = bundled default.
    @State private var selectedDockerImageId: UUID?
    @State private var showingImagePicker = false

    // Provisioning state
    @State private var isProvisioning = false
    @State private var provisioningStatus = ""
    @State private var provisioningError: String?

    private let ec2Regions: [(id: String, label: String)] = [
        ("us-east-1", "US East (N. Virginia)"),
        ("us-east-2", "US East (Ohio)"),
        ("us-west-1", "US West (N. California)"),
        ("us-west-2", "US West (Oregon)"),
        ("eu-west-1", "EU (Ireland)"),
        ("eu-west-2", "EU (London)"),
        ("eu-west-3", "EU (Paris)"),
        ("eu-central-1", "EU (Frankfurt)"),
        ("eu-central-2", "EU (Zurich)"),
        ("eu-south-1", "EU (Milan)"),
        ("eu-south-2", "EU (Spain)"),
        ("eu-north-1", "EU (Stockholm)"),
        ("ap-southeast-1", "Asia (Singapore)"),
        ("ap-southeast-2", "Asia (Sydney)"),
        ("ap-northeast-1", "Asia (Tokyo)"),
        ("sa-east-1", "South America (Sao Paulo)"),
    ]

    private let ec2InstanceTypes: [(id: String, label: String)] = [
        ("t3.micro", "t3.micro — 2 vCPU / 1 GB — ~$8/mo"),
        ("t3.small", "t3.small — 2 vCPU / 2 GB — ~$15/mo"),
        ("t3.medium", "t3.medium — 2 vCPU / 4 GB — ~$30/mo"),
        ("t3.large", "t3.large — 2 vCPU / 8 GB — ~$60/mo"),
        ("t3.xlarge", "t3.xlarge — 4 vCPU / 16 GB — ~$120/mo"),
        ("t3.2xlarge", "t3.2xlarge — 8 vCPU / 32 GB — ~$240/mo"),
        ("m6i.large", "m6i.large — 2 vCPU / 8 GB — ~$70/mo"),
        ("m6i.xlarge", "m6i.xlarge — 4 vCPU / 16 GB — ~$140/mo"),
        ("c6i.large", "c6i.large — 2 vCPU / 4 GB — ~$62/mo"),
        ("c6i.xlarge", "c6i.xlarge — 4 vCPU / 8 GB — ~$124/mo"),
    ]

    private let fargateSizes: [(label: String, cpu: String, mem: String, cost: String)] = [
        ("Small — 0.5 vCPU / 1 GB — ~$15/mo", "512", "1024", "~$15/mo"),
        ("Medium — 1 vCPU / 2 GB — ~$30/mo", "1024", "2048", "~$30/mo"),
        ("Large — 2 vCPU / 4 GB — ~$60/mo", "2048", "4096", "~$60/mo"),
        ("XL — 4 vCPU / 8 GB — ~$120/mo", "4096", "8192", "~$120/mo"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Create Instance")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { cancelAndDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(isProvisioning)
            }
            .padding(20)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        fieldGroup(label: "Instance Name") {
                            TextField("e.g. my-automation-box", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }

                        fieldGroup(label: "Type") {
                            Picker("", selection: $instanceType) {
                                Text("EC2").tag(CloudInstanceType.ec2)
                                Text("Fargate").tag(CloudInstanceType.fargate)
                                Text("Docker").tag(CloudInstanceType.docker)
                                Text("SSH").tag(CloudInstanceType.ssh)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        switch instanceType {
                        case .ec2: ec2Fields
                        case .docker: dockerFields
                        case .ssh: sshFields
                        case .fargate: fargateFields
                        }

                        if isProvisioning {
                            provisioningView
                        }

                        if let error = provisioningError {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.red)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.red.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
                        }

                        // Anchor for auto-scroll: kept at the very end of content.
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(20)
                }
                // Auto-scroll to the latest progress text whenever it updates,
                // so the user doesn't have to manually scroll past long forms.
                .onChange(of: provisioningStatus) { _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: isProvisioning) { provisioning in
                    if provisioning {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: provisioningError) { err in
                    if err != nil {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                if (instanceType == .ec2 || instanceType == .fargate) && !hasAWSCredentials {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.orange)
                        Text("Select a project with AWS credentials or configure ~/.aws/credentials")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                Spacer()
                Button("Cancel") { cancelAndDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isProvisioning)

                Button(createButtonTitle) { createInstance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || isProvisioning)
            }
            .padding(16)
        }
        .frame(width: 480, height: (instanceType == .ec2 || instanceType == .fargate) ? 460 : instanceType == .ssh ? 480 : 380)
        .onAppear {
            if let d = appState.cloudInstanceDraft {
                // Resuming from a paused state (e.g. after editing/adding a Docker image)
                name = d.name
                instanceType = d.instanceType
                ec2Region = d.ec2Region
                ec2InstanceType = d.ec2InstanceType
                ec2VolumeGB = d.ec2VolumeGB
                sshHost = d.sshHost
                sshUser = d.sshUser
                sshPort = d.sshPort
                sshKeyPath = d.sshKeyPath
                fargateRegion = d.fargateRegion
                fargateImage = d.fargateImage
                fargateUseDefault = d.fargateUseDefault
                fargateCpu = d.fargateCpu
                fargateMemory = d.fargateMemory
                dockerImage = d.dockerImage
                dockerContainerName = d.dockerContainerName
                credentialsSource = d.credentialsSource
                selectedDockerImageId = d.dockerImageId
                appState.cloudInstanceDraft = nil
                return
            }
            ec2Region = appState.settings.awsDefaultRegion
            fargateRegion = appState.settings.awsDefaultRegion
            if !appState.settings.defaultSSHKeyPath.isEmpty {
                sshKeyPath = appState.settings.defaultSSHKeyPath
            }
            // Auto-select first project with AWS keys, or Keychain, or system
            if let first = projectsWithAWSKeys.first {
                credentialsSource = first.path
            } else if appState.loadAWSCredentialsFromKeychain() != nil {
                credentialsSource = "__keychain__"
            }
            // Default image = bundled
            selectedDockerImageId = nil
        }
    }

    /// Snapshot the form into a draft so it can be restored after a paused
    /// modal (Docker image editor) returns control.
    private func makeDraft() -> CloudInstanceDraft {
        CloudInstanceDraft(
            name: name,
            instanceType: instanceType,
            ec2Region: ec2Region,
            ec2InstanceType: ec2InstanceType,
            ec2VolumeGB: ec2VolumeGB,
            sshHost: sshHost,
            sshUser: sshUser,
            sshPort: sshPort,
            sshKeyPath: sshKeyPath,
            fargateRegion: fargateRegion,
            fargateImage: fargateImage,
            fargateUseDefault: fargateUseDefault,
            fargateCpu: fargateCpu,
            fargateMemory: fargateMemory,
            dockerImage: dockerImage,
            dockerContainerName: dockerContainerName,
            credentialsSource: credentialsSource,
            dockerImageId: selectedDockerImageId
        )
    }

    private var createButtonTitle: String {
        switch instanceType {
        case .ec2: return isProvisioning ? "Launching..." : "Launch EC2 Instance"
        case .fargate: return isProvisioning ? "Launching..." : "Launch Fargate Task"
        case .docker: return isProvisioning ? "Creating..." : "Create Container"
        case .ssh: return "Connect"
        }
    }

    // MARK: - Project Picker

    private var projectPicker: some View {
        fieldGroup(label: "Project") {
            Picker("", selection: $credentialsSource) {
                Text("None").tag("")
                ForEach(projectsWithAWSKeys, id: \.path) { project in
                    Text(project.name).tag(project.path)
                }
            }
            .labelsHidden()
            Text("AWS credentials are read from the project's .env file. SSH keys are saved to the project folder.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var projectsWithAWSKeys: [Project] {
        appState.projects.filter { project in
            for envPath in ["\(project.path)/.env", "\(project.path)/.claude/infra/.env"] {
                if let contents = try? String(contentsOfFile: envPath, encoding: .utf8),
                   contents.contains("AWS_ACCESS_KEY") {
                    return true
                }
            }
            return false
        }
    }

    // MARK: - EC2 Fields

    private var ec2Fields: some View {
        Group {
            projectPicker

            fieldGroup(label: "Region") {
                Picker("", selection: $ec2Region) {
                    ForEach(ec2Regions, id: \.id) { r in
                        Text(r.label).tag(r.id)
                    }
                }
                .labelsHidden()
            }

            fieldGroup(label: "Instance Size") {
                Picker("", selection: $ec2InstanceType) {
                    ForEach(ec2InstanceTypes, id: \.id) { t in
                        Text(t.label).tag(t.id)
                    }
                }
                .labelsHidden()
            }

            fieldGroup(label: "Disk (GB)") {
                HStack(spacing: 8) {
                    TextField("30", text: $ec2VolumeGB)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text(diskCostNote)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            fieldGroup(label: "Docker Image") {
                imagePicker
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What happens when you click Launch:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    bulletPoint("Creates an SSH key pair and saves it locally")
                    bulletPoint("Creates a security group (port 22 open)")
                    bulletPoint("Launches Ubuntu 24.04 LTS instance")
                    bulletPoint("Waits for boot, then installs Claude CLI + tools")
                }
            }
            .padding(12)
            .background(Theme.pampas)
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
        }
    }

    /// Dynamic note showing EBS storage cost (~$0.08/GB-month gp3).
    private var diskCostNote: String {
        let gb = max(8, Int(ec2VolumeGB.trimmingCharacters(in: .whitespaces)) ?? 30)
        let monthly = Double(gb) * 0.08
        return String(format: "gp3 EBS storage ≈ $%.2f/mo. Default image needs ~6 GB to build; 30 GB recommended.", monthly)
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Docker Fields

    private var dockerFields: some View {
        Group {
            fieldGroup(label: "Image") {
                TextField("ubuntu:24.04", text: $dockerImage)
                    .textFieldStyle(.roundedBorder)
            }
            fieldGroup(label: "Container Name (optional)") {
                TextField("auto-generated if empty", text: $dockerContainerName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - SSH Fields

    private var sshFields: some View {
        Group {
            fieldGroup(label: "Host") {
                TextField("e.g. 192.168.1.100 or myhost.example.com", text: $sshHost)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                fieldGroup(label: "User") {
                    TextField("e.g. ubuntu", text: $sshUser)
                        .textFieldStyle(.roundedBorder)
                }
                fieldGroup(label: "Port") {
                    TextField("22", text: $sshPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            fieldGroup(label: "SSH Key Path") {
                HStack(spacing: 6) {
                    TextField("e.g. ~/.ssh/id_rsa", text: $sshKeyPath)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let panel = NSOpenPanel()
                        panel.title = "Select SSH Key"
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
                        if panel.runModal() == .OK, let url = panel.url {
                            sshKeyPath = url.path
                        }
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button {
                    testSSHConnection()
                } label: {
                    HStack(spacing: 4) {
                        if sshTesting {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text("Test Connection")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .disabled(sshHost.isEmpty || sshTesting)

                if let result = sshTestResult {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundStyle(result.contains("Success") ? Theme.green : Theme.red)
                }
            }
        }
    }

    // MARK: - Fargate Fields

    private var fargateFields: some View {
        Group {
            projectPicker

            fieldGroup(label: "Region") {
                Picker("", selection: $fargateRegion) {
                    ForEach(ec2Regions, id: \.id) { r in
                        Text(r.label).tag(r.id)
                    }
                }
                .labelsHidden()
            }

            fieldGroup(label: "Size") {
                Picker("", selection: $fargateCpu) {
                    ForEach(fargateSizes, id: \.cpu) { size in
                        Text(size.label).tag(size.cpu)
                    }
                }
                .labelsHidden()
                .onChange(of: fargateCpu) { _, newCpu in
                    if let match = fargateSizes.first(where: { $0.cpu == newCpu }) {
                        fargateMemory = match.mem
                    }
                }
            }

            fieldGroup(label: "Container Image") {
                Picker("", selection: $fargateUseDefault) {
                    Text("Default (Claude Hub: VNC + Chrome + Playwright)").tag(true)
                    Text("Custom image URL").tag(false)
                }
                .labelsHidden()
                if !fargateUseDefault {
                    TextField("e.g. ubuntu:24.04 or 123.dkr.ecr.us-east-1.amazonaws.com/my-image:latest", text: $fargateImage)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What happens when you click Launch:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    if fargateUseDefault {
                        bulletPoint("Builds the default image locally (~5 min, requires Docker Desktop)")
                        bulletPoint("Pushes it to your ECR (creates repo if needed)")
                    }
                    bulletPoint("Creates an ECS cluster")
                    bulletPoint("Creates a task execution role (if needed)")
                    bulletPoint("Registers a task definition with the image")
                    bulletPoint("Finds default VPC subnets + creates security group")
                    bulletPoint("Runs the task with a public IP")
                }
            }
            .padding(12)
            .background(Theme.pampas)
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
        }
    }

    // MARK: - Provisioning View

    private var provisioningView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(provisioningStatus)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
    }

    // MARK: - Image Picker

    /// Resolved currently-selected image (falls back to bundled default).
    private var selectedImage: DockerImage {
        if let id = selectedDockerImageId,
           let img = appState.dockerImages.first(where: { $0.id == id }) {
            return img
        }
        return appState.dockerImages.first(where: { $0.id == DockerImageBuilder.bundledDefaultImageId })
            ?? DockerImageBuilder.bundledDefaultImage()
    }

    private var imagePicker: some View {
        Button {
            showingImagePicker.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Text(selectedImage.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallCornerRadius)
                    .stroke(Theme.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingImagePicker, arrowEdge: .bottom) {
            imagePickerMenu
        }
    }

    private var imagePickerMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(appState.dockerImages) { img in
                ImagePickerRow(
                    image: img,
                    isSelected: img.id == selectedImage.id,
                    onSelect: {
                        selectedDockerImageId = (img.id == DockerImageBuilder.bundledDefaultImageId) ? nil : img.id
                        showingImagePicker = false
                    },
                    onDuplicate: {
                        let copy = appState.duplicateDockerImage(img)
                        showingImagePicker = false
                        // Open the editor on the new copy. Pause sheet first.
                        appState.pauseCloudInstanceSheetAndEditImage(draft: makeDraft(), image: copy)
                    },
                    onDelete: img.isBuiltIn ? nil : {
                        appState.removeDockerImage(img)
                        if selectedDockerImageId == img.id { selectedDockerImageId = nil }
                    },
                    onEdit: img.isBuiltIn ? nil : {
                        showingImagePicker = false
                        appState.pauseCloudInstanceSheetAndEditImage(draft: makeDraft(), image: img)
                    }
                )
            }

            Divider()

            Button {
                showingImagePicker = false
                appState.pauseCloudInstanceSheetAndEditImage(draft: makeDraft(), image: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11))
                    Text("Add new image…")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 360)
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func fieldGroup<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private var hasAWSCredentials: Bool {
        if appState.loadAWSCredentialsFromKeychain() != nil { return true }
        if !projectsWithAWSKeys.isEmpty { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return FileManager.default.fileExists(atPath: "\(home)/.aws/credentials")
    }

    private var canCreate: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        switch instanceType {
        case .ec2:
            return hasName && hasAWSCredentials
        case .fargate:
            return hasName && hasAWSCredentials &&
                   (fargateUseDefault || !fargateImage.trimmingCharacters(in: .whitespaces).isEmpty)
        case .docker:
            return hasName && !dockerImage.trimmingCharacters(in: .whitespaces).isEmpty
        case .ssh:
            return hasName && !sshHost.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func createInstance() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        switch instanceType {
        case .ec2:
            provisionEC2(name: trimmedName)
        case .fargate:
            provisionFargate(name: trimmedName)
        case .docker:
            provisionDocker(name: trimmedName)
        case .ssh:
            connectSSH(name: trimmedName)
        }
    }

    // MARK: - SSH Connect

    private func connectSSH(name: String) {
        let instance = CloudInstance(
            name: name,
            type: .ssh,
            sshConfig: SSHConfig(
                host: sshHost.trimmingCharacters(in: .whitespaces),
                user: sshUser.trimmingCharacters(in: .whitespaces),
                port: Int(sshPort) ?? 22,
                keyPath: sshKeyPath.trimmingCharacters(in: .whitespaces)
            )
        )
        appState.addCloudInstance(instance)
        cancelAndDismiss()
    }

    /// Closes the sheet and discards any pending draft (Cancel and successful
    /// create both go through here).
    private func cancelAndDismiss() {
        appState.clearCloudInstanceDraft()
        dismiss()
    }

    // MARK: - Docker Provision

    private func provisionDocker(name: String) {
        isProvisioning = true
        provisioningError = nil
        provisioningStatus = "Creating container..."

        let containerName = dockerContainerName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "claudehub-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
            : dockerContainerName.trimmingCharacters(in: .whitespaces)

        let instance = CloudInstance(
            name: name,
            type: .docker,
            dockerConfig: DockerConfig(
                imageName: dockerImage.trimmingCharacters(in: .whitespaces),
                containerName: containerName
            )
        )

        appState.addCloudInstance(instance)

        appState.dockerRun(instance) { success, message in
            if success {
                cancelAndDismiss()
            } else {
                provisioningError = message
                isProvisioning = false
            }
        }
    }

    // MARK: - EC2 Provision

    private func provisionEC2(name: String) {
        isProvisioning = true
        provisioningError = nil
        provisioningStatus = "Creating key pair..."

        let safeName = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let region = ec2Region
        let instType = ec2InstanceType
        let volumeGB = max(8, Int(ec2VolumeGB.trimmingCharacters(in: .whitespaces)) ?? 30)

        DispatchQueue.global(qos: .userInitiated).async {
            let env = buildAWSEnv(region: region)
            print("[ClaudeHub] EC2 provision env: \(env.filter { $0.key.hasPrefix("AWS") }.mapValues { String($0.prefix(8)) + "..." })")

            // Step 1: Create key pair
            let keyName = "claudehub-\(safeName)"
            let selectedProject = credentialsSource
            let keyPath: String
            if !selectedProject.isEmpty {
                keyPath = "\(selectedProject)/\(keyName).pem"
            } else {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                keyPath = "\(home)/.ssh/\(keyName).pem"
            }

            let keyResult = appState.runCommand(
                executable: AppState.resolveExecutable("aws"),
                arguments: [
                    "ec2", "create-key-pair",
                    "--key-name", keyName,
                    "--query", "KeyMaterial",
                    "--output", "text",
                    "--region", region,
                ],
                environment: env
            )

            if !keyResult.success && !keyResult.stderr.contains("already exists") {
                DispatchQueue.main.async {
                    provisioningError = "Key pair failed: \(keyResult.stderr)"
                    isProvisioning = false
                }
                return
            }

            if !keyResult.success {
                DispatchQueue.main.async {
                    provisioningStatus = "Key pair exists, continuing..."
                }
            }

            if keyResult.success {
                // Save the private key to project root or ~/.ssh/
                let keyDir = (keyPath as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: keyDir, withIntermediateDirectories: true)
                try? keyResult.stdout.write(toFile: keyPath, atomically: true, encoding: .utf8)
                // chmod 600
                var attrs = (try? FileManager.default.attributesOfItem(atPath: keyPath)) ?? [:]
                attrs[.posixPermissions] = 0o600
                try? FileManager.default.setAttributes(attrs, ofItemAtPath: keyPath)
            }

            DispatchQueue.main.async {
                provisioningStatus = "Creating security group..."
            }

            // Step 2: Create security group
            let sgName = "claudehub-\(safeName)"
            let sgResult = appState.runCommand(
                executable: AppState.resolveExecutable("aws"),
                arguments: [
                    "ec2", "create-security-group",
                    "--group-name", sgName,
                    "--description", "Claude Hub instance \(name)",
                    "--region", region,
                    "--output", "json",
                ],
                environment: env
            )

            var sgId = ""
            if sgResult.success,
               let data = sgResult.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let gid = json["GroupId"] as? String {
                sgId = gid
            } else if sgResult.stderr.contains("already exists") {
                // Look up existing SG
                let descResult = appState.runCommand(
                    executable: AppState.resolveExecutable("aws"),
                    arguments: [
                        "ec2", "describe-security-groups",
                        "--group-names", sgName,
                        "--region", region,
                        "--output", "json",
                    ],
                    environment: env
                )
                if let data = descResult.stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let groups = json["SecurityGroups"] as? [[String: Any]],
                   let gid = groups.first?["GroupId"] as? String {
                    sgId = gid
                }
            }

            if sgResult.success && !sgId.isEmpty {
                // Open port 22
                _ = appState.runCommand(
                    executable: AppState.resolveExecutable("aws"),
                    arguments: [
                        "ec2", "authorize-security-group-ingress",
                        "--group-id", sgId,
                        "--protocol", "tcp",
                        "--port", "22",
                        "--cidr", "0.0.0.0/0",
                        "--region", region,
                    ],
                    environment: env
                )
            }

            DispatchQueue.main.async {
                provisioningStatus = "Looking up Ubuntu 24.04 AMI..."
            }

            // Step 3: Find Ubuntu 24.04 AMI
            let amiResult = appState.runCommand(
                executable: AppState.resolveExecutable("aws"),
                arguments: [
                    "ec2", "describe-images",
                    "--owners", "099720109477", // Canonical
                    "--filters",
                    "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*",
                    "Name=state,Values=available",
                    "--query", "sort_by(Images, &CreationDate)[-1].ImageId",
                    "--output", "text",
                    "--region", region,
                ],
                environment: env
            )

            let ami = amiResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard amiResult.success, !ami.isEmpty, ami != "None" else {
                DispatchQueue.main.async {
                    provisioningError = "Could not find Ubuntu 24.04 AMI in \(region)"
                    isProvisioning = false
                }
                return
            }

            DispatchQueue.main.async {
                provisioningStatus = "Launching instance..."
            }

            // Step 4: Launch instance
            let setupScript = Self.instanceSetupScript
            let encodedScript = Data(setupScript.utf8).base64EncodedString()

            // Block device mapping for root volume (EBS gp3, delete-on-termination)
            let blockDeviceMapping = "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":\(volumeGB),\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]"

            var launchArgs = [
                "ec2", "run-instances",
                "--image-id", ami,
                "--instance-type", instType,
                "--key-name", keyName,
                "--region", region,
                "--count", "1",
                "--user-data", encodedScript,
                "--block-device-mappings", blockDeviceMapping,
                "--tag-specifications",
                "ResourceType=instance,Tags=[{Key=Name,Value=\(name)},{Key=ManagedBy,Value=ClaudeHub}]",
                "--output", "json",
            ]
            if !sgId.isEmpty {
                launchArgs += ["--security-group-ids", sgId]
            }

            let launchResult = appState.runCommand(
                executable: AppState.resolveExecutable("aws"),
                arguments: launchArgs,
                environment: env
            )

            guard launchResult.success,
                  let data = launchResult.stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let instances = json["Instances"] as? [[String: Any]],
                  let inst = instances.first,
                  let instanceId = inst["InstanceId"] as? String else {
                DispatchQueue.main.async {
                    provisioningError = "Launch failed: \(launchResult.stderr)"
                    isProvisioning = false
                }
                return
            }

            DispatchQueue.main.async {
                provisioningStatus = "Waiting for instance to start..."
            }

            // Step 5: Wait for running state + public IP
            var publicIP: String?
            for _ in 0..<60 { // up to ~2 minutes
                Thread.sleep(forTimeInterval: 2)
                let descResult = appState.runCommand(
                    executable: AppState.resolveExecutable("aws"),
                    arguments: [
                        "ec2", "describe-instances",
                        "--instance-ids", instanceId,
                        "--region", region,
                        "--output", "json",
                    ],
                    environment: env
                )
                if let data = descResult.stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let reservations = json["Reservations"] as? [[String: Any]],
                   let insts = reservations.first?["Instances"] as? [[String: Any]],
                   let i = insts.first {
                    let state = (i["State"] as? [String: Any])?["Name"] as? String
                    publicIP = i["PublicIpAddress"] as? String
                    if state == "running" && publicIP != nil { break }
                }
            }

            DispatchQueue.main.async {
                let instance = CloudInstance(
                    name: name,
                    type: .ec2,
                    ec2Config: EC2Config(
                        instanceId: instanceId,
                        region: region,
                        instanceType: instType,
                        ami: ami,
                        keyPair: keyName,
                        securityGroup: sgId,
                        sshUser: "ubuntu",
                        sshKeyPath: keyPath
                    ),
                    awsCredentialsProjectPath: credentialsSource,
                    dockerImageId: selectedDockerImageId
                )
                appState.addCloudInstance(instance)

                if let ip = publicIP {
                    appState.cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(
                        status: .running,
                        publicIP: ip
                    )
                }

                isProvisioning = false
                cancelAndDismiss()
            }
        }
    }

    // MARK: - Fargate Provision

    private func provisionFargate(name: String) {
        isProvisioning = true
        provisioningError = nil
        provisioningStatus = "Preparing..."

        let safeName = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let region = fargateRegion
        let useDefault = fargateUseDefault
        let customImage = fargateImage.trimmingCharacters(in: .whitespaces)
        let cpu = fargateCpu
        let memory = fargateMemory

        DispatchQueue.global(qos: .userInitiated).async {
            let env = buildAWSEnv(region: region)
            let clusterName = "claudehub-\(safeName)"

            // Step 0: If using default image, build + push to ECR
            var image = customImage
            if useDefault {
                guard let resolvedImage = self.buildAndPushDefaultImage(env: env, region: region) else {
                    return // error already reported
                }
                image = resolvedImage
            }

            // Step 1: Create cluster
            let clusterResult = appState.runCommand(
                executable: AppState.resolveExecutable("aws"),
                arguments: ["ecs", "create-cluster", "--cluster-name", clusterName, "--region", region, "--output", "json"],
                environment: env
            )
            if !clusterResult.success && !clusterResult.stderr.contains("already exists") {
                DispatchQueue.main.async {
                    provisioningError = "Cluster creation failed: \(clusterResult.stderr)"
                    isProvisioning = false
                }
                return
            }

            DispatchQueue.main.async { provisioningStatus = "Setting up task execution role..." }

            // Step 2: Ensure ecsTaskExecutionRole exists
            let roleName = "ecsTaskExecutionRole"
            let roleCheck = appState.runCommand(
                executable: AppState.resolveExecutable("aws"),
                arguments: ["iam", "get-role", "--role-name", roleName, "--output", "json"],
                environment: env
            )
            var roleArn = ""
            if roleCheck.success,
               let data = roleCheck.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let role = json["Role"] as? [String: Any],
               let arn = role["Arn"] as? String {
                roleArn = arn
            } else {
                // Create the role
                let trustPolicy = """
                {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
                """
                let createRole = appState.runCommand(
                    executable: AppState.resolveExecutable("aws"),
                    arguments: [
                        "iam", "create-role",
                        "--role-name", roleName,
                        "--assume-role-policy-document", trustPolicy,
                        "--output", "json",
                    ],
                    environment: env
                )
                if let data = createRole.stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let role = json["Role"] as? [String: Any],
                   let arn = role["Arn"] as? String {
                    roleArn = arn
                }
                // Attach the execution policy
                _ = appState.runCommand(
                    executable: AppState.resolveExecutable("aws"),
                    arguments: [
                        "iam", "attach-role-policy",
                        "--role-name", roleName,
                        "--policy-arn", "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
                    ],
                    environment: env
                )
                Thread.sleep(forTimeInterval: 5) // Wait for IAM propagation
            }

            DispatchQueue.main.async { provisioningStatus = "Registering task definition..." }

            // Step 3: Register task definition
            let taskFamily = "claudehub-\(safeName)"
            let portMappings = useDefault
                ? "[{\"containerPort\":22,\"protocol\":\"tcp\"},{\"containerPort\":5900,\"protocol\":\"tcp\"},{\"containerPort\":6080,\"protocol\":\"tcp\"}]"
                : "[]"
            let cmdJSON = useDefault ? "" : ",\"command\":[\"sleep\",\"infinity\"]"
            let containerDef = """
            [{"name":"\(safeName)","image":"\(image)","cpu":\(cpu),"memory":\(Int(memory)! - 128),"essential":true,"portMappings":\(portMappings)\(cmdJSON),"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"/ecs/claudehub-\(safeName)","awslogs-region":"\(region)","awslogs-stream-prefix":"ecs","awslogs-create-group":"true"}}}]
            """
            var taskDefArgs = [
                "ecs", "register-task-definition",
                "--family", taskFamily,
                "--network-mode", "awsvpc",
                "--requires-compatibilities", "FARGATE",
                "--cpu", cpu,
                "--memory", memory,
                "--container-definitions", containerDef,
                "--region", region,
                "--output", "json",
            ]
            if !roleArn.isEmpty {
                taskDefArgs += ["--execution-role-arn", roleArn]
            }

            let taskDefResult = appState.runCommand(
                executable: AppState.resolveExecutable("aws"),
                arguments: taskDefArgs,
                environment: env
            )
            guard taskDefResult.success else {
                DispatchQueue.main.async {
                    provisioningError = "Task definition failed: \(taskDefResult.stderr)"
                    isProvisioning = false
                }
                return
            }

            DispatchQueue.main.async { provisioningStatus = "Finding default VPC subnets..." }

            // Step 4: Get default VPC subnets
            let subnetResult = appState.runCommand(
                executable: AppState.resolveExecutable("aws"),
                arguments: [
                    "ec2", "describe-subnets",
                    "--filters", "Name=default-for-az,Values=true",
                    "--query", "Subnets[*].SubnetId",
                    "--output", "json",
                    "--region", region,
                ],
                environment: env
            )
            var subnets: [String] = []
            if let data = subnetResult.stdout.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                subnets = Array(arr.prefix(3))
            }

            // Step 5: Create security group
            let sgName = "claudehub-fargate-\(safeName)"
            var sgId = ""
            let sgResult = appState.runCommand(
                executable: AppState.resolveExecutable("aws"),
                arguments: [
                    "ec2", "create-security-group",
                    "--group-name", sgName,
                    "--description", "Claude Hub Fargate \(name)",
                    "--region", region,
                    "--output", "json",
                ],
                environment: env
            )
            if sgResult.success,
               let data = sgResult.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let gid = json["GroupId"] as? String {
                sgId = gid
            } else if sgResult.stderr.contains("already exists") {
                let descResult = appState.runCommand(
                    executable: AppState.resolveExecutable("aws"),
                    arguments: ["ec2", "describe-security-groups", "--group-names", sgName, "--region", region, "--output", "json"],
                    environment: env
                )
                if let data = descResult.stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let groups = json["SecurityGroups"] as? [[String: Any]],
                   let gid = groups.first?["GroupId"] as? String {
                    sgId = gid
                }
            }

            // Open ports on the security group
            if !sgId.isEmpty {
                let ports = useDefault ? [22, 5900, 6080] : [22]
                for port in ports {
                    _ = appState.runCommand(
                        executable: AppState.resolveExecutable("aws"),
                        arguments: [
                            "ec2", "authorize-security-group-ingress",
                            "--group-id", sgId,
                            "--protocol", "tcp",
                            "--port", "\(port)",
                            "--cidr", "0.0.0.0/0",
                            "--region", region,
                        ],
                        environment: env
                    )
                }
            }

            DispatchQueue.main.async { provisioningStatus = "Launching Fargate task..." }

            // Step 6: Run task
            var netConfig = "awsvpcConfiguration={subnets=[\(subnets.joined(separator: ","))],assignPublicIp=ENABLED"
            if !sgId.isEmpty {
                netConfig += ",securityGroups=[\(sgId)]"
            }
            netConfig += "}"

            let runResult = appState.runCommand(
                executable: AppState.resolveExecutable("aws"),
                arguments: [
                    "ecs", "run-task",
                    "--cluster", clusterName,
                    "--task-definition", taskFamily,
                    "--launch-type", "FARGATE",
                    "--network-configuration", netConfig,
                    "--region", region,
                    "--output", "json",
                ],
                environment: env
            )

            var taskArn = ""
            if let data = runResult.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tasks = json["tasks"] as? [[String: Any]],
               let task = tasks.first,
               let arn = task["taskArn"] as? String {
                taskArn = arn
            }

            guard !taskArn.isEmpty else {
                DispatchQueue.main.async {
                    provisioningError = "Task launch failed: \(runResult.stderr)"
                    isProvisioning = false
                }
                return
            }

            DispatchQueue.main.async { provisioningStatus = "Waiting for task to start..." }

            // Step 7: Wait for running + IP
            var publicIP: String?
            for _ in 0..<60 {
                Thread.sleep(forTimeInterval: 3)
                let descResult = appState.runCommand(
                    executable: AppState.resolveExecutable("aws"),
                    arguments: [
                        "ecs", "describe-tasks",
                        "--cluster", clusterName,
                        "--tasks", taskArn,
                        "--region", region,
                        "--output", "json",
                    ],
                    environment: env
                )
                if let data = descResult.stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tasks = json["tasks"] as? [[String: Any]],
                   let task = tasks.first {
                    let status = task["lastStatus"] as? String
                    if status == "RUNNING" {
                        // Get IP from attachments
                        if let attachments = task["attachments"] as? [[String: Any]] {
                            for att in attachments {
                                if let details = att["details"] as? [[String: Any]] {
                                    for d in details {
                                        if d["name"] as? String == "privateIPv4Address" {
                                            publicIP = d["value"] as? String
                                        }
                                    }
                                }
                            }
                        }
                        break
                    }
                    if status == "STOPPED" || status == "DEPROVISIONING" {
                        DispatchQueue.main.async {
                            provisioningError = "Task stopped unexpectedly"
                            isProvisioning = false
                        }
                        return
                    }
                }
            }

            DispatchQueue.main.async {
                let instance = CloudInstance(
                    name: name,
                    type: .fargate,
                    fargateConfig: FargateConfig(
                        cluster: clusterName,
                        taskDefinition: taskFamily,
                        region: region,
                        subnets: subnets,
                        securityGroups: sgId.isEmpty ? [] : [sgId],
                        taskArn: taskArn,
                        containerName: safeName
                    ),
                    awsCredentialsProjectPath: credentialsSource
                )
                appState.addCloudInstance(instance)

                appState.cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(
                    status: .running,
                    publicIP: publicIP
                )

                isProvisioning = false
                cancelAndDismiss()
            }
        }
    }

    /// Builds the default Claude Hub image locally with `docker build`, then pushes to ECR.
    /// Returns the full ECR image URI on success, nil on failure (error already reported via UI).
    private func buildAndPushDefaultImage(env: [String: String], region: String) -> String? {
        let dockerPath = AppState.resolveExecutable("docker")
        guard FileManager.default.fileExists(atPath: dockerPath) else {
            DispatchQueue.main.async {
                provisioningError = "Docker Desktop is required to build the default image. Install it or use a custom image URL."
                isProvisioning = false
            }
            return nil
        }

        DispatchQueue.main.async { provisioningStatus = "Looking up AWS account ID..." }

        // Get AWS account ID
        let stsResult = appState.runCommand(
            executable: AppState.resolveExecutable("aws"),
            arguments: ["sts", "get-caller-identity", "--query", "Account", "--output", "text"],
            environment: env
        )
        let accountId = stsResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stsResult.success, !accountId.isEmpty else {
            DispatchQueue.main.async {
                provisioningError = "Failed to get AWS account ID: \(stsResult.stderr)"
                isProvisioning = false
            }
            return nil
        }

        let repoName = "claudehub"
        let imageURI = "\(accountId).dkr.ecr.\(region).amazonaws.com/\(repoName):latest"

        DispatchQueue.main.async { provisioningStatus = "Ensuring ECR repository exists..." }

        // Create repo if missing
        let createRepo = appState.runCommand(
            executable: AppState.resolveExecutable("aws"),
            arguments: ["ecr", "create-repository", "--repository-name", repoName, "--region", region],
            environment: env
        )
        if !createRepo.success && !createRepo.stderr.contains("RepositoryAlreadyExistsException") {
            DispatchQueue.main.async {
                provisioningError = "ECR repo creation failed: \(createRepo.stderr)"
                isProvisioning = false
            }
            return nil
        }

        DispatchQueue.main.async { provisioningStatus = "Logging into ECR..." }

        // ECR login
        let pwResult = appState.runCommand(
            executable: AppState.resolveExecutable("aws"),
            arguments: ["ecr", "get-login-password", "--region", region],
            environment: env
        )
        guard pwResult.success else {
            DispatchQueue.main.async {
                provisioningError = "ECR login failed: \(pwResult.stderr)"
                isProvisioning = false
            }
            return nil
        }
        let ecrPassword = pwResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let loginResult = appState.runCommand(
            executable: "/bin/bash",
            arguments: ["-c", "echo '\(ecrPassword)' | '\(dockerPath)' login --username AWS --password-stdin \(accountId).dkr.ecr.\(region).amazonaws.com"]
        )
        guard loginResult.success else {
            DispatchQueue.main.async {
                provisioningError = "Docker ECR login failed: \(loginResult.stderr)"
                isProvisioning = false
            }
            return nil
        }

        DispatchQueue.main.async { provisioningStatus = "Building Docker image (this takes ~5 minutes)..." }

        // Write build context (Fargate default uses the bundled image; the
        // per-instance picker only applies to EC2 today).
        guard let buildDir = DockerImageBuilder.writeBuildContext(image: DockerImageBuilder.bundledDefaultImage()) else {
            DispatchQueue.main.async {
                provisioningError = "Failed to create build context"
                isProvisioning = false
            }
            return nil
        }
        defer { try? FileManager.default.removeItem(atPath: buildDir) }

        let buildResult = appState.runCommand(
            executable: dockerPath,
            arguments: ["build", "--platform", "linux/amd64", "-t", imageURI, buildDir],
            timeout: 900 // 15 min cap
        )
        guard buildResult.success else {
            DispatchQueue.main.async {
                provisioningError = "Docker build failed: \(buildResult.stderr.suffix(500))"
                isProvisioning = false
            }
            return nil
        }

        DispatchQueue.main.async { provisioningStatus = "Pushing image to ECR..." }

        let pushResult = appState.runCommand(
            executable: dockerPath,
            arguments: ["push", imageURI],
            timeout: 600
        )
        guard pushResult.success else {
            DispatchQueue.main.async {
                provisioningError = "Docker push failed: \(pushResult.stderr.suffix(500))"
                isProvisioning = false
            }
            return nil
        }

        return imageURI
    }

    private func buildAWSEnv(region: String) -> [String: String] {
        var env: [String: String] = ["AWS_DEFAULT_REGION": region]

        if credentialsSource == "__keychain__" {
            // Keychain
            if let creds = appState.loadAWSCredentialsFromKeychain() {
                env["AWS_ACCESS_KEY_ID"] = creds.accessKey
                env["AWS_SECRET_ACCESS_KEY"] = creds.secretKey
            }
        } else if !credentialsSource.isEmpty {
            // Project .env
            let projectPath = credentialsSource
            for envPath in ["\(projectPath)/.env", "\(projectPath)/.claude/infra/.env"] {
                guard let contents = try? String(contentsOfFile: envPath, encoding: .utf8) else { continue }
                for line in contents.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("#"), trimmed.contains("=") else { continue }
                    let parts = trimmed.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "AWS_ACCESS_KEY_ID", "AWS_ACCESS_KEY":
                        env["AWS_ACCESS_KEY_ID"] = value
                    case "AWS_SECRET_ACCESS_KEY", "AWS_ACCESS_TOKEN", "AWS_ACCESS_SECRET":
                        env["AWS_SECRET_ACCESS_KEY"] = value
                    case "AWS_SESSION_TOKEN":
                        env["AWS_SESSION_TOKEN"] = value
                    default: break
                    }
                }
                if env["AWS_ACCESS_KEY_ID"] != nil && env["AWS_SECRET_ACCESS_KEY"] != nil { break }
            }
        }
        // else: empty string = system ~/.aws/credentials, don't set anything

        return env
    }

    /// Minimal cloud-init: just installs Docker and creates dirs. The app
    /// finishes the bootstrap (rsync build context + docker build + docker run)
    /// over SSH once the host is reachable. Keeps user-data well under AWS's
    /// 16KB hard limit.
    static var instanceSetupScript: String {
        return """
        #!/bin/bash
        set -ex
        export DEBIAN_FRONTEND=noninteractive

        apt-get update
        apt-get install -y curl git unzip jq rsync ca-certificates gnupg

        # Install Docker
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        usermod -aG docker ubuntu
        systemctl enable --now docker

        # Pre-create dirs the app will rsync into
        mkdir -p /opt/claudehub /home/ubuntu/projects
        chown -R ubuntu:ubuntu /opt/claudehub /home/ubuntu/projects

        # Signal: host is ready for the app to push the build context
        touch /home/ubuntu/.claudehub-host-ready
        chown ubuntu:ubuntu /home/ubuntu/.claudehub-host-ready
        """
    }

    // MARK: - SSH Test

    private func testSSHConnection() {
        sshTesting = true
        sshTestResult = nil

        let host = sshHost.trimmingCharacters(in: .whitespaces)
        let user = sshUser.trimmingCharacters(in: .whitespaces)
        let port = sshPort.trimmingCharacters(in: .whitespaces)
        let keyPath = sshKeyPath.trimmingCharacters(in: .whitespaces)

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no"]
            if !port.isEmpty, port != "22" {
                args += ["-p", port]
            }
            if !keyPath.isEmpty {
                let expanded = (keyPath as NSString).expandingTildeInPath
                args += ["-i", expanded]
            }
            let target = user.isEmpty ? host : "\(user)@\(host)"
            args += [target, "echo", "ok"]
            process.arguments = args

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let success = process.terminationStatus == 0
                DispatchQueue.main.async {
                    sshTestResult = success ? "Success — connected!" : "Failed — check credentials"
                    sshTesting = false
                }
            } catch {
                DispatchQueue.main.async {
                    sshTestResult = "Error — \(error.localizedDescription)"
                    sshTesting = false
                }
            }
        }
    }
}

/// Row in the Docker-image picker popover. Shows duplicate/edit/delete
/// buttons on hover; tap the row body to select.
private struct ImagePickerRow: View {
    let image: DockerImage
    let isSelected: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onDelete: (() -> Void)?
    let onEdit: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Theme.orange : Theme.textTertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(image.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if image.isBuiltIn {
                    Text("Built-in")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }

            if isHovering {
                if let onEdit {
                    rowButton(systemImage: "pencil", help: "Edit image", action: onEdit)
                }
                rowButton(systemImage: "doc.on.doc", help: "Duplicate", action: onDuplicate)
                if let onDelete {
                    rowButton(systemImage: "trash", help: "Delete", action: onDelete)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHovering ? Theme.pampas : Color.clear)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private func rowButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 22)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.cardBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
