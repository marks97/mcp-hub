import Foundation

/// Default Dockerfile and entrypoint for Claude Hub cloud instances.
/// Provides: Node 22, Python 3, Chrome + Patchright (stealth-patched Playwright fork),
/// VNC (Xvfb + x11vnc + noVNC), SSH server, Claude CLI, common dev tools.
enum DockerImageBuilder {

    /// Stable UUID for the bundled default image. Used as the seed identity so
    /// existing instances pointing at it continue to resolve correctly across
    /// app upgrades.
    static let bundledDefaultImageId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

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

    # Install Patchright (stealth-patched Playwright fork) + Chromium
    RUN npm install -g patchright && \\
        npx patchright install chromium --with-deps

    # Install Claude CLI
    RUN npm install -g @anthropic-ai/claude-code

    # Install iproute2 + tun2socks for optional full-container proxy.
    # When PROXY_URL is set at runtime, the entrypoint reroutes ALL traffic
    # through a TUN device backed by tun2socks → no AWS IP leaks.
    RUN apt-get update && apt-get install -y --no-install-recommends iproute2 iputils-ping && \\
        rm -rf /var/lib/apt/lists/* && \\
        curl -fsSL https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-amd64.zip -o /tmp/t2s.zip && \\
        unzip /tmp/t2s.zip -d /tmp/t2s && \\
        mv /tmp/t2s/tun2socks-linux-amd64 /usr/local/bin/tun2socks && \\
        chmod +x /usr/local/bin/tun2socks && \\
        rm -rf /tmp/t2s /tmp/t2s.zip

    # Stealth wrapper for google-chrome: disables WebRTC IP leak even when
    # the network is tunneled. Apps that launch Chrome via `google-chrome`
    # pick this up automatically.
    RUN mv /usr/bin/google-chrome /usr/bin/google-chrome-real && \\
        printf '%s\\n' \\
            '#!/bin/bash' \\
            'exec /usr/bin/google-chrome-real \\\\' \\
            '  --no-sandbox \\\\' \\
            '  --disable-blink-features=AutomationControlled \\\\' \\
            '  --webrtc-ip-handling-policy=disable_non_proxied_udp \\\\' \\
            '  --force-webrtc-ip-handling-policy \\\\' \\
            '  "$@"' \\
            > /usr/bin/google-chrome && \\
        chmod +x /usr/bin/google-chrome

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

    # --- Optional: route ALL container traffic through PROXY_URL via tun2socks ---
    # When set, the container's default route becomes a TUN device backed by
    # tun2socks pointing at the user-supplied proxy. No AWS / datacenter IP
    # leaks: every packet (including DNS, WebRTC STUN) exits via the proxy.
    if [ -n "${PROXY_URL:-}" ]; then
        echo "[claudehub] PROXY_URL set, configuring tun2socks tunnel..."
        echo "[claudehub] Proxy: ${PROXY_URL}"

        # Resolve the proxy host so we can preserve a direct route to it (otherwise
        # tun2socks would try to reach its own backing proxy via the TUN — loop).
        PROXY_HOST=$(echo "$PROXY_URL" | sed -E 's|^[a-z0-9]+://([^@]+@)?([^:/]+).*|\\2|')
        DEFAULT_GW=$(ip route | awk '/^default/ { print $3; exit }')
        ORIGINAL_IF=$(ip route | awk '/^default/ { print $5; exit }')
        PROXY_IP=$(getent hosts "$PROXY_HOST" | awk '{print $1; exit}')
        if [ -z "$PROXY_IP" ]; then
            # If hostname doesn't resolve (e.g. proxy host given as IP literal), assume it's already an IP.
            PROXY_IP="$PROXY_HOST"
        fi
        echo "[claudehub] Proxy host: $PROXY_HOST -> $PROXY_IP via $ORIGINAL_IF (gw $DEFAULT_GW)"

        # Pin direct route to the proxy through the original gateway.
        ip route add "$PROXY_IP/32" via "$DEFAULT_GW" dev "$ORIGINAL_IF" 2>/dev/null || true

        # Start tun2socks → creates utun0
        /usr/local/bin/tun2socks -device tun://utun0 -proxy "$PROXY_URL" -loglevel warning > /var/log/tun2socks.log 2>&1 &
        TUN_PID=$!
        sleep 2

        # Bring up the TUN interface
        ip addr add 198.18.0.2/15 dev utun0
        ip link set utun0 up

        # Swap default route to the TUN (everything-except-proxy now exits via proxy)
        ip route del default 2>/dev/null || true
        ip route add default via 198.18.0.1 dev utun0

        # Disable IPv6 (dual-stack would bypass the TUN on v6-reachable destinations)
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true

        # Leak verification (best effort, 5s deadline)
        sleep 1
        EXIT_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "TIMEOUT")
        echo "[claudehub] External IP via proxy: $EXIT_IP"

        if [ "$EXIT_IP" = "TIMEOUT" ]; then
            echo "[claudehub] WARNING: leak check timed out — proxy may be unreachable."
            echo "[claudehub] tun2socks log:"
            tail -20 /var/log/tun2socks.log 2>/dev/null || true
        fi
    else
        echo "[claudehub] No PROXY_URL set; using direct network egress."
    fi

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

    /// The bundled built-in image. Seeded into the user's image list on first
    /// run and refreshed (in place, preserving id) on subsequent launches.
    static func bundledDefaultImage() -> DockerImage {
        DockerImage(
            id: bundledDefaultImageId,
            name: "Claude Hub Default (Patchright + VNC)",
            dockerfile: defaultDockerfile,
            entrypoint: defaultEntrypoint,
            isBuiltIn: true
        )
    }

    /// Returns the path to a temp directory containing the supplied image's
    /// Dockerfile + entrypoint plus the bundled gateway sources — the full
    /// build context the EC2 bootstrap needs. Caller is responsible for cleanup.
    static func writeBuildContext(image: DockerImage) -> String? {
        let tmpDir = NSTemporaryDirectory() + "claudehub-image-\(UUID().uuidString)"
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: "\(tmpDir)/gateway", withIntermediateDirectories: true)
            try image.dockerfile.write(toFile: "\(tmpDir)/Dockerfile", atomically: true, encoding: .utf8)
            try image.entrypoint.write(toFile: "\(tmpDir)/entrypoint.sh", atomically: true, encoding: .utf8)
            try (gatewayIndexJS ?? "").write(toFile: "\(tmpDir)/gateway/index.js", atomically: true, encoding: .utf8)
            try (gatewayPackageJSON ?? "").write(toFile: "\(tmpDir)/gateway/package.json", atomically: true, encoding: .utf8)
            return tmpDir
        } catch {
            return nil
        }
    }
}
