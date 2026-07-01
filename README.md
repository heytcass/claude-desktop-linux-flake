***THIS IS AN UNOFFICIAL PACKAGE!***

If you run into an issue with this flake, make an issue here. Don't bug Anthropic about it - they already have enough on their plates.

# Claude Desktop for Linux (Nix)

A Nix flake packaging **Anthropic's official native Linux build** of Claude Desktop, straight from their apt repository, with proper NixOS/GNOME/Wayland desktop integration.

> **History:** before July 2026 there was no official Linux release, and this flake worked by repackaging the macOS build with stub native bindings (`patchy-cnb`) and a stack of JS patches. Anthropic now ships a real Linux build (deb, amd64 + arm64) with native bindings, `node-pty` for Claude Code, and even the Cowork VM tooling — so all of that machinery is gone. This is now a straightforward deb repackage: extract, patch ELF rpaths for Nix, wrap.

Supports MCP, the Ctrl+Alt+Space Quick Entry popup (natively on Wayland via the XDG global-shortcuts portal on GNOME 48+/KDE), the tray menu, and Claude Code.

# Usage

To run this once, make sure Nix is installed, then run

```bash
NIXPKGS_ALLOW_UNFREE=1 nix run github:k3d3/claude-desktop-linux-flake --impure
```

The "unfree" part is due to the fact that Claude Desktop is not an open source application, and thus, Nix's licensing rules
are dictated by the application itself, not the build script used to build the application.

## Installation on NixOS with Flakes

Add the following to your `flake.nix`:
```nix
inputs.claude-desktop.url = "github:k3d3/claude-desktop-linux-flake";
inputs.claude-desktop.inputs.nixpkgs.follows = "nixpkgs";
inputs.claude-desktop.inputs.flake-utils.follows = "flake-utils";
```

And then the following package to your `environment.systemPackages` or `home.packages`:
```nix
inputs.claude-desktop.packages.${system}.claude-desktop
```

If you would like to run [MCP servers with Claude Desktop](https://modelcontextprotocol.io/quickstart/user) on NixOS, use the `claude-desktop-with-fhs` package. This will allow running MCP servers with calls to `npx`, `uvx`, or `docker` (assuming docker is installed).
```nix
inputs.claude-desktop.packages.${system}.claude-desktop-with-fhs
```

Both `x86_64-linux` and `aarch64-linux` are supported — upstream publishes amd64 and arm64 debs.

> **Upgrading from the pre-native-build flake:** the desktop file is now upstream's `claude-desktop.desktop` (window class `claude-desktop`) instead of this flake's old `Claude.desktop`. If you had Claude pinned to your dock, re-pin it once after upgrading.

## How it works

Anthropic publishes the Linux build to an apt repository at
`https://downloads.claude.ai/claude-desktop/apt/stable`. This flake:

1. Fetches the versioned deb from the apt pool (hash-pinned from the repo's signed `Packages` index)
2. Extracts it and patches ELF interpreter/rpaths with `autoPatchelfHook` so every binary — the Electron app, `chrome_crashpad_handler`, the bundled `virtiofsd`, and the native Node modules (`@ant/claude-native`, `node-pty`) — finds its libraries in the Nix store
3. Ships upstream's own desktop file and hicolor icons, with `Exec` pointed at the wrapper
4. Wraps the binary with Wayland-friendly Chromium flags (see below)

The deb's Debian maintainer scripts (AppArmor profile, apt source registration) are intentionally not replicated — they don't apply on NixOS.

Updates are automated: the weekly `update-claude-desktop` workflow reads the apt `Packages` index, repins version + per-arch hashes, and opens an auto-merging PR gated on a real `nix build`.

## Display backend & global shortcuts

The launcher defaults to **native Wayland** via `--ozone-platform-hint=auto`. On a
Wayland session it runs natively on Wayland; on an X11 session it transparently
falls back to X11, so the default is safe either way.

Quick Entry's global shortcut (**Ctrl+Alt+Space**) works under native Wayland by
routing through the **XDG GlobalShortcuts portal**. That path requires
`xdg-desktop-portal` with a GlobalShortcuts backend:

- **GNOME 48+** and **KDE Plasma** ship one. On GNOME a one-time permission dialog
  appears the first time the shortcut is bound — approve it for the hotkey to work.
- Compositors whose portal has no GlobalShortcuts backend (e.g. most wlroots
  setups like Sway/Hyprland) silently make the feature a no-op — the global
  hotkey won't fire under native Wayland there.

If the portal route misbehaves on your compositor, set **`CLAUDE_USE_X11=1`** to
force XWayland. That restores the older X11 key-grab global shortcut and the more
mature IME/HiDPI rendering path.

### Environment variables

| Variable | Default | Effect |
| --- | --- | --- |
| `CLAUDE_USE_X11` | unset | Set to `1` to force XWayland (`--ozone-platform=x11`) instead of native Wayland. |
| `GTK_USE_PORTAL` | `1` | Use the XDG portal for native file dialogs. Set to `0` to use Electron's built-in GTK dialogs. |

## Sandboxing on non-NixOS

The Nix store can't carry SUID binaries, so the package removes Chromium's
`chrome-sandbox` helper and relies on the **user-namespace sandbox** instead.

- **NixOS**: unprivileged user namespaces are enabled by default — everything just works.
- **Ubuntu 24.04+ (and other AppArmor-restricted distros)**: unconfined binaries
  can't create user namespaces (`kernel.apparmor_restrict_unprivileged_userns=1`),
  so the app aborts at startup. Allowlist it the same way the official deb's
  postinst does — as root, create `/etc/apparmor.d/claude-desktop-nix`:

  ```
  abi <abi/4.0>,
  include <tunables/global>

  profile claude-desktop-nix /nix/store/*-claude-desktop-*/lib/claude-desktop/claude-desktop flags=(unconfined) {
    userns,

    include if exists <local/claude-desktop-nix>
  }
  ```

  then load it with `sudo apparmor_parser -r /etc/apparmor.d/claude-desktop-nix`.
  The glob keeps working across Nix store path changes. (`flags=(unconfined)`
  does not confine the app — it only allowlists it for userns creation.)

Do **not** run with `--no-sandbox` outside of throwaway testing.

## GPU acceleration on non-NixOS

On NixOS, hardware GL resolves through `/run/opengl-driver` automatically. On
other distros that path doesn't exist, so Chromium logs EGL errors at startup
and falls back to software rendering — functional, just not accelerated. Use
[nixGL](https://github.com/nix-community/nixGL) (`nixGL claude-desktop`) for
hardware acceleration on non-NixOS hosts.

## Other distributions

This repository only provides a Nix flake. On other distros you can simply install
Anthropic's official deb, or see:

- https://github.com/aaddrick/claude-desktop-debian - A debian builder for Claude Desktop (predates the official deb)
- https://aur.archlinux.org/packages/claude-desktop-bin - An Arch package for Claude Desktop

# Known limitations

- **In-app auto-update is intentionally inert.** On Nix the store path is read-only, so the app can't update itself (on regular distros, updates flow through apt). Updates are this repo's job instead: the weekly `update-claude-desktop` workflow repins the flake from the apt index. Bump your flake input to get the new version.
- **Cowork's VM sandbox needs host virtualization.** The deb Recommends `qemu-system-x86`, `ovmf`, and `virtiofsd` (a `virtiofsd` is bundled and patched, but qemu/OVMF must come from the host). Without them, Cowork VM features won't start.
- **Native Wayland global shortcuts depend on your compositor's portal.** See [Display backend & global shortcuts](#display-backend--global-shortcuts) — they work on GNOME 48+/KDE but are a no-op on portals without a GlobalShortcuts backend; use `CLAUDE_USE_X11=1` there.
- **Sandbox and GPU acceleration need one-time setup on non-NixOS hosts.** See the two sections above.

# License

The build scripts in this repository are dual-licensed under the terms of the MIT license and the Apache License (Version 2.0).

See [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE) for details.

The Claude Desktop application, not included in this repository, is likely covered by [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

## Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any
additional terms or conditions.
