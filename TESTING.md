# Testing Claude Desktop (Linux)

This is the acceptance matrix for a release. The first group is checked
automatically (by the build and by CI); the second group needs a real GNOME/KDE
graphical session and a human, and is meant to be run on the testbed.

## Automatically verified (build + CI)

These fail the build or the `update-claude-desktop` workflow if they regress:

| Check | How |
| --- | --- |
| Deb matches the apt index | `fetchurl` verifies the pinned SHA256 (repinned by CI from the signed apt `Packages` index) |
| Every ELF's dependencies resolve | `autoPatchelfHook` fails the build on any unsatisfied `DT_NEEDED` (covers the main binary, crashpad, bundled virtiofsd, native Node modules) |
| Package builds end to end | `nix build .#claude-desktop` (run by CI on every version bump) |
| `claude://` is registered | upstream desktop file ships `MimeType=x-scheme-handler/claude`; `update-desktop-database` maps it to `claude-desktop.desktop` |
| Desktop file is valid | `desktop-file-validate` (run manually below) |

Quick local re-run:

```bash
NIXPKGS_ALLOW_UNFREE=1 nix build .#claude-desktop --impure -L
OUT=$(readlink -f result)
nix shell nixpkgs#desktop-file-utils -c desktop-file-validate "$OUT"/share/applications/claude-desktop.desktop
```

## Manual matrix (run on the testbed)

Run once on **GNOME (Wayland)** and, where noted, once with `CLAUDE_USE_X11=1`.
On NixOS the Chromium user-namespace sandbox works out of the box. On non-NixOS
hosts that restrict unprivileged user namespaces (Ubuntu 24.04+), install the
AppArmor profile from README → "Sandboxing on non-NixOS" first, or launch with
`--no-sandbox` for throwaway testing only.

| # | Test | Pass criteria | Notes |
| --- | --- | --- | --- |
| 1 | **Launch** | Window appears; no FATAL / missing-library errors in stderr | `claude-desktop 2>&1 \| tee /tmp/cd.log`; GL-driver fallback noise on non-NixOS is expected (see README) |
| 2 | **OAuth login round-trip** | "Sign in" opens the system browser, redirects back via `claude://`, lands logged in; relaunch stays logged in | exercises both `claude://` handling and keyring token persistence |
| 3 | **Tray icon** | Icon appears in the tray; menu opens; "Quit" exits | needs an AppIndicator host — see the claudeos GNOME module |
| 4 | **Global hotkey** | Ctrl+Alt+Space opens Quick Entry. On GNOME Wayland, approve the one-time portal permission dialog on first use | if it does nothing on native Wayland, retry with `CLAUDE_USE_X11=1` |
| 5 | **File picker** | Attaching a file opens the portal file dialog and the file attaches | `GTK_USE_PORTAL=1` is the default |
| 6 | **Drag-and-drop** | Dragging a file onto the window attaches it | |
| 7 | **`claude://` handling** | From a terminal: `xdg-open "claude://test"` focuses/opens the app and routes the URL | desktop-database half is auto-verified; this confirms the app acts on it |
| 8 | **Claude Code terminal** | Opening a Claude Code session gets a working terminal | exercises the bundled `node-pty` prebuild after rpath patching |
| 9 | **Cowork sandbox (optional)** | With `qemu` + OVMF installed, Cowork's VM sandbox starts | uses the bundled `virtiofsd`/`cowork-linux-helper`; `n-a` without qemu on the host |

Record results as `pass` / `fail` / `n-a (reason)`. Treat 1, 2, and 7 as release
blockers; 3–6 and 8–9 as known-environment-dependent (see README → Known limitations).
