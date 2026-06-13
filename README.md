***THIS IS AN UNOFFICIAL BUILD SCRIPT!***

If you run into an issue with this build script, make an issue here. Don't bug Anthropic about it - they already have enough on their plates.

# Claude Desktop for Linux (Nix)

Supports MCP!
![image](https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45)

Supports the Ctrl+Alt+Space popup! (natively on Wayland via the XDG global-shortcuts portal on GNOME 48+/KDE — see [Display backend & global shortcuts](#display-backend--global-shortcuts))
![image](https://github.com/user-attachments/assets/1deb4604-4c06-4e4b-b63f-7f6ef9ef28c1)

Supports the Tray menu! (Screenshot of running on KDE)

![image](https://github.com/user-attachments/assets/ba209824-8afb-437c-a944-b53fd9ecd559)

This is a Nix flake for running Claude Desktop on Linux with proper desktop integration.

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

## GNOME Desktop Integration

This flake includes comprehensive fixes for proper GNOME desktop integration, particularly on Wayland:

- **Correct Icon Display**: Shows the proper orange Claude sunburst icon instead of a generic gear icon
- **Dock Icon Grouping**: Running applications properly group with pinned dock icons (no duplicate icons)
- **Wayland Compatibility**: Proper window class and desktop file association for GNOME on Wayland
- **FHS + Desktop Integration**: The `claude-desktop-with-fhs` package includes both MCP server support AND desktop files

The integration has been thoroughly tested on GNOME 48 with Wayland and works reliably across different installation methods.

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
| `GTK_THEME` | `Adwaita:dark` | Passed through to the app; override to change theming. |
| `COLOR_SCHEME_PREFERENCE` | `dark` | Light/dark preference hint. |

## Other distributions

This repository only provides a Nix flake, and does not provide a package for e.g. Ubuntu, Fedora, or Arch Linux.

Other known variants:
- https://github.com/aaddrick/claude-desktop-debian - A debian builder for Claude Desktop
- https://aur.archlinux.org/packages/claude-desktop-bin - An Arch package for Claude Desktop
- https://github.com/wankdanker/claude-desktop-linux-bash - A bash-based Claude Desktop builder that works on Ubuntu and possibly other Debian derivatives

If anyone else packages Claude Desktop for other distributions, make an issue or PR and I'll link it here.

# How it works

Claude Desktop is an Electron application. That means the majority of the application is inside an `app.asar` archive, which usually contains minified Javascript, HTML, and CSS, along with images and a few other things.

Despite there being no official Linux Claude Desktop release, the vast majority of the code is completely cross-platform.

With the exception of one library.

## `claude-native-bindings`

![image](https://github.com/user-attachments/assets/9b386f42-2565-441a-a351-9c09347f9f5f)

Node, and by extension Electron, allow you to import natively-compiled objects into the Node runtime as if they were regular modules.
These are typically used to extend the functionality in ways Node itself can't do. Only problem, as shown above, is that these objects 
are only compiled for one OS. 

Luckily enough, because it's a loadable Node module, that means you can open it up yourself in node and inspect it - no decompilation or disassembly needed:

![image](https://github.com/user-attachments/assets/b2f1e72c-f763-45c0-8631-2de5555ae653)

There are many functions here for getting monitor/window information, as well as for controlling the mouse and keyboard.
I'm not sure what exactly these are for - my best guess is something unreleased related to [Computer Use](https://docs.anthropic.com/en/docs/build-with-claude/computer-use),
however I'm not a huge fan of this functionality existing in the first place.

As for how to move forward with getting Claude Desktop working on Linux, seeing as how the API surface area of this module is relatively
small, it looked fairly easy to just wholesale reimplement it, using stubs for the functionality.

## `patchy-cnb`

The result of that is a library I call `patchy-cnb`, which uses NAPI-RS to match the original API with stub functions.
Turns out, the original module also used NAPI-RS. Neat!

From there, it's just a matter of compiling `patchy-cnb`, repackaging the app.asar to include the newly built Linux module, and
making a new Electron build with these files.

# Known limitations

This is a repackaging of a macOS build, and a few things either don't work or work differently than on macOS. Rather than pretend otherwise:

- **`patchy-cnb` is a stub.** The Windows/macOS `claude-native` module is reimplemented as no-ops: window/monitor enumeration returns empty, and the mouse/keyboard control entry points do nothing. Anything that would drive **Computer Use**-style screen/input control through these native bindings is therefore inert. The normal chat app does not depend on them, so day-to-day use is unaffected.
- **Cowork / local-agent native features are not wired up.** This flake does **not** vendor the Cowork daemon, bubblewrap/KVM sandbox backends, or `node-pty` that the [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian) build ships. Features that depend on the Cowork VM service won't be available here. If you need those, that project (which also offers a Nix flake) is the more complete option today.
- **In-app auto-update is intentionally disabled.** On Nix the store path is read-only, so the app can't update itself. Updates are this repo's job instead: the weekly `update-claude-desktop` workflow reads Claude's `RELEASES.json`, repins the flake, and opens an auto-merging PR once a real `nix build` (including patch verification) passes. Bump your flake input to get the new version.
- **Native Wayland global shortcuts depend on your compositor's portal.** See [Display backend & global shortcuts](#display-backend--global-shortcuts) — they work on GNOME 48+/KDE but are a no-op on portals without a GlobalShortcuts backend; use `CLAUDE_USE_X11=1` there.

# License

The build scripts in this repository, as well as `patchy-cnb`, are dual-licensed under the terms of the MIT license and the Apache License (Version 2.0).

See [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE) for details.

The Claude Desktop application, not included in this repository, is likely covered by [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

## Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any
additional terms or conditions.
