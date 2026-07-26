{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
  # Linked libraries (DT_NEEDED of claude-desktop / chrome_crashpad_handler /
  # app.asar.unpacked native modules)
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  gdk-pixbuf,
  glib,
  gtk3,
  libcap_ng,
  libdrm,
  libgbm,
  libseccomp,
  libxkbcommon,
  nspr,
  nss,
  pango,
  systemd,
  libx11,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxrandr,
  libxtst,
  libxcb,
  # dlopen'd at runtime (not in DT_NEEDED)
  libGL,
  libnotify,
  libpulseaudio,
  libsecret,
  pipewire,
}:
let
  pname = "claude-desktop";
  version = "1.24012.9";

  # Official Anthropic apt repository for the native Linux build.
  # Version discovery: fetch
  #   ${aptRepo}/dists/stable/main/binary-amd64/Packages
  # and read the last Package stanza's Version/Filename/SHA256 fields
  # (one stanza per published version, oldest first; arm64 lives in
  # binary-arm64). The SHA256 there is the deb's hash — convert with
  # `nix hash convert --hash-algo sha256 <hex>`.
  aptRepo = "https://downloads.claude.ai/claude-desktop/apt/stable";

  srcs = {
    x86_64-linux = fetchurl {
      url = "${aptRepo}/pool/main/c/claude-desktop/claude-desktop_${version}_amd64.deb";
      hash = "sha256-MC5tII3YyOnlIGfaoo7zsRcaFhNYb9DhC+3GQiJbbuE=";
    };
    aarch64-linux = fetchurl {
      url = "${aptRepo}/pool/main/c/claude-desktop/claude-desktop_${version}_arm64.deb";
      hash = "sha256-Gpvhd7BjNluS5SL+3RnIfa9uvJKp9xEhvf9ynifeQIw=";
    };
  };
in
stdenv.mkDerivation {
  inherit pname version;

  src =
    srcs.${stdenv.hostPlatform.system}
      or (throw "claude-desktop: unsupported system ${stdenv.hostPlatform.system}");

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    libcap_ng # bundled virtiofsd (Cowork VM sandbox)
    libdrm
    libgbm
    libseccomp # bundled virtiofsd
    libxkbcommon
    nspr
    nss
    pango
    (lib.getLib stdenv.cc.cc) # libstdc++ for node-pty's pty.node
    (lib.getLib systemd) # libudev
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libxtst
    libxcb
  ];

  # Chromium/Electron dlopens these without them appearing in DT_NEEDED.
  # libGL/libEGL back hardware GL (dlopened from inside bundled ANGLE, so
  # appendRunpaths rather than runtimeDependencies — the latter only extends
  # executables' rpaths, not libraries'). libsecret backs safeStorage
  # (keyring), libnotify backs notifications, pipewire backs Wayland screen
  # sharing.
  appendRunpaths = map (p: "${lib.getLib p}/lib") [
    libGL
    libnotify
    libpulseaudio
    libsecret
    pipewire
    systemd
  ];

  unpackPhase = ''
    runHook preUnpack
    # Not `dpkg-deb -x`: that preserves the SUID bit on chrome-sandbox,
    # which the sandboxed builder isn't allowed to set.
    mkdir unpacked
    dpkg-deb --fsys-tarfile $src \
      | tar -x -C unpacked --no-same-owner --no-same-permissions
    runHook postUnpack
  '';
  sourceRoot = "unpacked";

  dontConfigure = true;
  dontBuild = true;
  # Keep upstream binaries byte-identical apart from rpath patching; stripping
  # a ~200 MB Chromium binary is slow and buys nothing here.
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r usr/lib usr/share $out/
    rm -rf $out/share/lintian

    # Drop the SUID sandbox helper: the Nix store can't carry SUID bits, and
    # a present-but-not-SUID helper makes Chromium abort with a FATAL when it
    # can't use user namespaces. On NixOS unprivileged userns is enabled, so
    # Chromium uses the userns sandbox and never needs the helper. On distros
    # that restrict unconfined userns (Ubuntu 24.04+), an AppArmor allowlist
    # profile is required — see README "Sandboxing on non-NixOS".
    rm $out/lib/${pname}/chrome-sandbox

    # Resolve the desktop file rather than pinning its name: upstream renamed
    # it claude-desktop.desktop -> com.anthropic.Claude.desktop in 1.20186.1,
    # which hard-broke the build. Insist on exactly one match so an unexpected
    # layout still fails loudly instead of silently shipping an unpatched (or
    # missing) entry. nullglob so a zero-match glob is an empty array rather
    # than the literal pattern.
    shopt -s nullglob
    desktopFiles=($out/share/applications/*.desktop)
    shopt -u nullglob
    if [ ''${#desktopFiles[@]} -ne 1 ]; then
      echo "claude-desktop: expected exactly one .desktop file in" \
           "share/applications, found ''${#desktopFiles[@]}: ''${desktopFiles[*]}" >&2
      exit 1
    fi
    desktopFile="''${desktopFiles[0]}"
    desktopName="$(basename "$desktopFile")"

    # Every Exec= is PATH-relative (the main entry plus the NewChat/NewCode
    # actions); point them all at the wrapper so launching also works when the
    # package isn't in PATH (e.g. `nix run`).
    substituteInPlace "$desktopFile" \
      --replace-fail "Exec=claude-desktop" "Exec=$out/bin/claude-desktop"

    # Default to native Wayland via Ozone. --ozone-platform-hint=auto
    # auto-selects the backend: a Wayland session (WAYLAND_DISPLAY set) runs
    # natively on Wayland, otherwise it falls back to X11.
    #
    # Global shortcuts (Quick Entry's Ctrl+Alt+Space) route through the XDG
    # GlobalShortcutsPortal under native Wayland — needs xdg-desktop-portal
    # with a GlobalShortcuts backend (GNOME 48+ / KDE Plasma); a no-op on
    # portals without one (e.g. most wlroots compositors).
    #
    # Escape hatch: CLAUDE_USE_X11=1 forces XWayland (--ozone-platform=x11
    # takes precedence over the hint; the Wayland-only flags are inert under
    # X11, so they're passed unconditionally).
    mkdir -p $out/bin
    makeWrapper $out/lib/${pname}/${pname} $out/bin/${pname} \
      --add-flags "--ozone-platform-hint=auto" \
      --add-flags "--enable-features=GlobalShortcutsPortal,WaylandWindowDecorations" \
      --add-flags "--enable-wayland-ime" \
      --add-flags "--wayland-text-input-version=3" \
      --add-flags "\''${CLAUDE_USE_X11:+--ozone-platform=x11}" \
      --set-default GTK_USE_PORTAL "1" \
      --set CHROME_DESKTOP "$desktopName" \
      --prefix XDG_DATA_DIRS : "$out/share"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Claude Desktop for Linux (official native build, repackaged from the Anthropic apt repository)";
    homepage = "https://claude.ai";
    license = licenses.unfree;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = pname;
  };
}
