# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial Nix flake packaging Anthropic's **official native Linux build** of Claude Desktop (published as a deb to their apt repository since July 2026). The old approach — repackaging the macOS DMG with `patchy-cnb` stub bindings and JS patches — is gone; this is now a standard deb repackage.

## Key Commands

### Building and Running Claude Desktop

```bash
# One-time run
NIXPKGS_ALLOW_UNFREE=1 nix run github:k3d3/claude-desktop-linux-flake --impure

# Build locally
NIXPKGS_ALLOW_UNFREE=1 nix build .#claude-desktop --impure

# Build with FHS environment (for MCP support)
NIXPKGS_ALLOW_UNFREE=1 nix build .#claude-desktop-with-fhs --impure
```

## Architecture

The package works by:

1. Fetching the versioned deb from Anthropic's apt pool at `https://downloads.claude.ai/claude-desktop/apt/stable` (per-arch: amd64 + arm64)
2. Extracting it (via `dpkg-deb --fsys-tarfile | tar --no-same-permissions` — plain `dpkg-deb -x` fails in the sandbox on the SUID `chrome-sandbox`)
3. Patching ELF rpaths with `autoPatchelfHook` (main binary, crashpad handler, bundled `virtiofsd`, `@ant/claude-native` and `node-pty` Node modules)
4. Removing `chrome-sandbox` (can't be SUID in the store; the userns sandbox is used instead)
5. Shipping upstream's desktop file (`claude-desktop.desktop`, window class `claude-desktop`) and hicolor icons, with `Exec` pointed at the wrapper
6. Wrapping with Wayland-friendly Chromium flags (`--ozone-platform-hint=auto`, GlobalShortcutsPortal, Wayland IME; `CLAUDE_USE_X11=1` escape hatch)

Key files:

- `/pkgs/claude-desktop.nix`: The package definition
- `/flake.nix`: Flake outputs, including the FHS wrapper for MCP support
- `/.github/workflows/update-claude-desktop.yml`: Weekly auto-update from the apt `Packages` index

### Updating for a new version

CI does this automatically, but by hand: read the latest `Version`/`SHA256` per arch from
`https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-{amd64,arm64}/Packages`,
convert hashes with `nix hash convert --hash-algo sha256 <hex>`, and update `version` plus both `hash` fields in `/pkgs/claude-desktop.nix`.

### Host caveats (see README for details)

- Non-NixOS hosts with restricted userns (Ubuntu 24.04+) need an AppArmor allowlist profile for the sandbox.
- Non-NixOS hosts fall back to software rendering unless wrapped with nixGL.

## MCP Server Setup

This flake includes an FHS shell environment for installing MCP servers. To set up Home Assistant integration:

### Install MCP Proxy
```bash
nix run .#claude-desktop-shell
uv tool install mcp-proxy
export PATH="/home/tom/.local/bin:$PATH"
```

### Configure Claude Desktop
Create `/home/tom/.config/Claude/claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "Home Assistant": {
      "command": "/home/tom/.local/bin/mcp-proxy",
      "env": {
        "SSE_URL": "https://your-ha-instance.com/mcp_server/sse",
        "API_ACCESS_TOKEN": "your_long_lived_access_token"
      }
    }
  }
}
```

### Enable in Home Assistant
Add to `configuration.yaml`:
```yaml
mcp_server:
```

Then restart Home Assistant and Claude Desktop with FHS support:
```bash
nix run .#claude-desktop-with-fhs
```

## Memories

- The location for my NixOS configuration is at `/home/tom/.nixos`. It's entry point is `/home/tom/.nixos/flake.nix`.
