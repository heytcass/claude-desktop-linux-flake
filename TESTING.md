# Testing Claude Desktop (Linux)

This is the acceptance matrix for a release. The first group is checked
automatically (by the build and by CI); the second group needs a real GNOME/KDE
graphical session and a human, and is meant to be run on the testbed.

## Automatically verified (build + CI)

These fail the build or the `update-claude-desktop` workflow if they regress:

| Check | How |
| --- | --- |
| App resources extract from the DMG | `buildPhase` errors if `Claude.app` is missing |
| All JS patches still apply | marker greps in the verify step (`Platform detection`, `Origin validation`, tray theme/debounce, DBus delay) |
| **Patched bundle is valid JavaScript** | `node --check` on `index.js` — gates against regex drift that injects a substring but breaks syntax |
| Package builds end to end | `nix build .#claude-desktop` (run by CI on every version bump) |
| `claude://` is registered | desktop file ships `MimeType=x-scheme-handler/claude`; `update-desktop-database` maps it to `Claude.desktop` |
| Desktop file is valid | `desktop-file-validate` (run manually below) |

Quick local re-run:

```bash
NIXPKGS_ALLOW_UNFREE=1 nix build .#claude-desktop --impure -L   # build + node --check gate
OUT=$(readlink -f result)
nix shell nixpkgs#desktop-file-utils -c desktop-file-validate "$OUT"/share/applications/Claude.desktop
```

## Manual matrix (run on the testbed)

Run once on **GNOME (Wayland)** and, where noted, once with `CLAUDE_USE_X11=1`.
On a non-NixOS host, the Chromium SUID sandbox is usually not configured, so
either install on NixOS, enable the sandbox helper, or launch with `--no-sandbox`.

| # | Test | Pass criteria | Notes |
| --- | --- | --- | --- |
| 1 | **Launch** | Window appears; no SyntaxError / ENOENT in stderr | `claude-desktop 2>&1 \| tee /tmp/cd.log` |
| 2 | **OAuth login round-trip** | "Sign in" opens the system browser, redirects back via `claude://`, lands logged in; relaunch stays logged in | exercises both `claude://` handling and keyring token persistence |
| 3 | **Tray icon** | Icon appears in the tray with correct light/dark variant; menu opens; "Quit" exits | needs an AppIndicator host — see the claudeos GNOME module |
| 4 | **Global hotkey** | Ctrl+Alt+Space opens Quick Entry. On GNOME Wayland, approve the one-time portal permission dialog on first use | if it does nothing on native Wayland, retry with `CLAUDE_USE_X11=1` |
| 5 | **File picker** | Attaching a file opens the portal file dialog and the file attaches | `GTK_USE_PORTAL=1` is the default |
| 6 | **Drag-and-drop** | Dragging a file onto the window attaches it (no spurious "open app.asar?" prompt) | |
| 7 | **`claude://` handling** | From a terminal: `xdg-open "claude://test"` focuses/opens the app and routes the URL | desktop-database half is auto-verified; this confirms the app acts on it |

Record results as `pass` / `fail` / `n-a (reason)`. Treat 1, 2, and 7 as release
blockers; 3–6 as known-environment-dependent (see README → Known limitations).
