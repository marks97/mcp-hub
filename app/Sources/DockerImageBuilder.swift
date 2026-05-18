import Foundation

/// Default Dockerfile and entrypoint for Claude Hub cloud instances.
/// Provides: Node 22, Python 3, Chrome + Chromium, Playwright, VNC (Xvfb + x11vnc + noVNC),
/// SSH server, Claude CLI, common dev tools.
enum DockerImageBuilder {

    /// Returns the gateway/index.js content from the app bundle.
    static var gatewayIndexJS: String? {
        guard let url = Bundle.module.url(forResource: "index", withExtension: "js", subdirectory: "gateway") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Returns the gateway/package.json content from the app bundle.
    static var gatewayPackageJSON: String? {
        guard let url = Bundle.module.url(forResource: "package", withExtension: "json", subdirectory: "gateway") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static let defaultDockerfile: String = """
    FROM --platform=linux/amd64 node:22-bookworm-slim

    ENV DEBIAN_FRONTEND=noninteractive
    ENV DISPLAY=:99
    ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

    # System dependencies + browser deps + VNC stack + SSH
    RUN apt-get update && \\
        apt-get install -y --no-install-recommends \\
            ca-certificates curl gnupg unzip git rsync jq sudo \\
            python3 python3-pip python3-venv \\
            openssh-server \\
            xvfb xauth xdotool x11vnc novnc websockify \\
            fluxbox xterm \\
            ffmpeg \\
            libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \\
            libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \\
            libgbm1 libasound2 libpango-1.0-0 libcairo2 libgdk-pixbuf2.0-0 libgtk-3-0 \\
            fonts-liberation fonts-noto-color-emoji && \\
        rm -rf /var/lib/apt/lists/*

    # Install Google Chrome (stable)
    RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \\
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \\
        apt-get update && \\
        apt-get install -y --no-install-recommends google-chrome-stable && \\
        rm -rf /var/lib/apt/lists/*

    # Install Playwright + Chromium
    RUN npm install -g playwright && \\
        npx playwright install chromium --with-deps

    # Install Claude CLI
    RUN npm install -g @anthropic-ai/claude-code

    # Install MCP Gateway (bundled from claude-hub/gateway/)
    COPY gateway /opt/claudehub/gateway
    RUN cd /opt/claudehub/gateway && npm install --omit=dev

    # Setup SSH (root login allowed for container admin; interactive `claude` runs as `node`)
    RUN mkdir /var/run/sshd && \\
        echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config && \\
        echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config && \\
        echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config && \\
        mkdir -p /root/.ssh && chmod 700 /root/.ssh

    # Configure the existing `node` user (UID 1000 in node:22 base) for interactive use:
    # passwordless sudo + matching .ssh dir so users can `docker exec -u node` and run
    # `claude --dangerously-skip-permissions` (the CLI blocks uid=0 for safety).
    RUN apt-get update && apt-get install -y --no-install-recommends sudo && rm -rf /var/lib/apt/lists/* && \\
        usermod -aG sudo node && \\
        echo 'node ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/node && \\
        mkdir -p /home/node/.ssh && chmod 700 /home/node/.ssh && chown node:node /home/node/.ssh

    # Workdir owned by node so claude can write logs/cache there
    WORKDIR /workspace

    # Entrypoint
    COPY entrypoint.sh /entrypoint.sh
    RUN chmod +x /entrypoint.sh

    EXPOSE 22
    EXPOSE 5900
    EXPOSE 6080

    ENTRYPOINT ["/entrypoint.sh"]
    """

    static let defaultEntrypoint: String = """
    #!/usr/bin/env bash
    # NOTE: do NOT use `set -e` — backgrounded daemons returning non-zero
    # would crash-loop the container. Each step has its own || true guard.

    mkdir -p /root/.ssh /var/run/sshd /home/node/.ssh

    # Inject SSH public keys from env (one or more, separated by newlines or commas)
    if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
        echo "$SSH_PUBLIC_KEY" > /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
    fi

    if [ -f /root/.ssh/authorized_keys ]; then
        chmod 600 /root/.ssh/authorized_keys
        # Mirror to the `node` user so `ssh node@host` works too
        cp /root/.ssh/authorized_keys /home/node/.ssh/authorized_keys
        chown -R node:node /home/node/.ssh
        chmod 600 /home/node/.ssh/authorized_keys
    fi

    # Make the workspace writable by the non-root `node` user (claude runs as them)
    chown -R node:node /workspace 2>/dev/null || true

    # Generate SSH host keys if missing (slim images may not have run the postinst hooks)
    ssh-keygen -A 2>/dev/null || true

    # Start SSH daemon in background
    /usr/sbin/sshd || echo "sshd failed to start"

    # Start Xvfb (virtual display)
    Xvfb :99 -screen 0 1920x1080x24 &
    sleep 1

    # Lightweight window manager so Chrome has a frame
    DISPLAY=:99 fluxbox &

    # x11vnc bound to the Xvfb display
    if [ -n "${VNC_PASSWORD:-}" ]; then
        mkdir -p /root/.vnc
        x11vnc -storepasswd "${VNC_PASSWORD}" /root/.vnc/passwd
        x11vnc -display :99 -forever -shared -rfbport 5900 -rfbauth /root/.vnc/passwd -bg || true
    else
        x11vnc -display :99 -forever -shared -rfbport 5900 -nopw -bg || true
    fi

    # noVNC web client at http://host:6080/vnc.html (-D = daemon)
    websockify -D --web /usr/share/novnc/ 6080 localhost:5900 || true

    echo "============================================"
    echo "Claude Hub Cloud Instance Ready"
    echo "  SSH:    port 22"
    echo "  VNC:    port 5900"
    echo "  noVNC:  http://localhost:6080/vnc.html"
    echo "  Display: $DISPLAY"
    echo "============================================"

    # Stay alive (or run command if passed)
    if [ "$#" -gt 0 ]; then
        exec "$@"
    else
        # Tail forever to keep container running
        tail -f /dev/null
    fi
    """

    /// Returns the path to a temp directory containing the Dockerfile, entrypoint,
    /// and gateway/ sources — the full build context the EC2 bootstrap needs.
    /// Caller is responsible for cleanup.
    static func writeBuildContext() -> String? {
        let tmpDir = NSTemporaryDirectory() + "claudehub-image-\(UUID().uuidString)"
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: "\(tmpDir)/gateway", withIntermediateDirectories: true)
            try defaultDockerfile.write(toFile: "\(tmpDir)/Dockerfile", atomically: true, encoding: .utf8)
            try defaultEntrypoint.write(toFile: "\(tmpDir)/entrypoint.sh", atomically: true, encoding: .utf8)
            try (gatewayIndexJS ?? "").write(toFile: "\(tmpDir)/gateway/index.js", atomically: true, encoding: .utf8)
            try (gatewayPackageJSON ?? "").write(toFile: "\(tmpDir)/gateway/package.json", atomically: true, encoding: .utf8)
            return tmpDir
        } catch {
            return nil
        }
    }
}
