{
  lib,
  stdenvNoCC,
  fetchurl,
  electron,
  p7zip,
  libicns,
  nodePackages,
  imagemagick,
  makeDesktopItem,
  makeWrapper,
  wrapGAppsHook3,
  patchy-cnb,
  perl,
  glib-networking
}: let
  pname = "claude-desktop";
  version = "1.1.799";
  # Mac DMG source - actively updated, unlike Windows installer
  srcDmg = fetchurl {
    # The redirect URL provides the latest version; we pin to a specific version for reproducibility
    url = "https://downloads.claude.ai/releases/darwin/universal/${version}/Claude-2e02b656cbbb1f14a5a81a4ed79b1c5ea1427507.dmg";
    hash = "sha256-Bsi7hru9p1GjkxMoTNPL8MsCfeBh0Mu9Vj0Abny5AZU=";
  };
in
  stdenvNoCC.mkDerivation rec {
    inherit pname version;

    src = ./.;

    nativeBuildInputs = [
      p7zip
      nodePackages.asar
      makeWrapper
      imagemagick
      libicns
      perl
    ];

    desktopItem = makeDesktopItem {
      name = "Claude";
      exec = "claude-desktop %u";
      icon = "claude";
      type = "Application";
      terminal = false;
      desktopName = "Claude";
      genericName = "Claude Desktop";
      comment = "AI Assistant by Anthropic";
      startupWMClass = "Claude";
      startupNotify = true;
      categories = [
        "Office"
        "Utility"
        "Network"
        "Chat"
      ];
      mimeTypes = ["x-scheme-handler/claude"];
    };

    buildPhase = ''
      runHook preBuild

      # Create temp working directory
      mkdir -p $TMPDIR/build
      cd $TMPDIR/build

      # Extract Mac DMG (7z handles HFS+ despite warnings)
      echo "Extracting Mac DMG..."
      7z x -y ${srcDmg} || true

      # Verify extraction worked
      if [ ! -d "Claude/Claude.app" ]; then
        echo "ERROR: Failed to extract Claude.app from DMG"
        ls -la
        exit 1
      fi

      APP_CONTENTS="$TMPDIR/build/Claude/Claude.app/Contents"
      RESOURCES="$APP_CONTENTS/Resources"

      echo "Extracted app contents:"
      ls -la "$RESOURCES"

      # Extract icons from electron.icns
      echo "Extracting icons from electron.icns..."
      icns2png -x "$RESOURCES/electron.icns"

      for size in 16 32 48 128 256 512; do
        mkdir -p $TMPDIR/build/icons/hicolor/"$size"x"$size"/apps
        if [ -f "electron_"$size"x"$size"x32.png" ]; then
          install -Dm 644 "electron_"$size"x"$size"x32.png" \
            $TMPDIR/build/icons/hicolor/"$size"x"$size"/apps/claude.png
        elif [ -f "electron_"$size"x"$size".png" ]; then
          install -Dm 644 "electron_"$size"x"$size".png" \
            $TMPDIR/build/icons/hicolor/"$size"x"$size"/apps/claude.png
        fi
      done

      # Process app.asar files
      mkdir -p electron-app
      cp "$RESOURCES/app.asar" electron-app/
      cp -r "$RESOURCES/app.asar.unpacked" electron-app/

      cd electron-app
      asar extract app.asar app.asar.contents

      # Title bar patch - check if needed for Mac source
      SEARCH_BASE="app.asar.contents/.vite/renderer/main_window/assets"
      TARGET_PATTERN="MainWindowPage-*.js"

      echo "Searching for '$TARGET_PATTERN' within '$SEARCH_BASE'..."
      TARGET_FILES=$(find "$SEARCH_BASE" -type f -name "$TARGET_PATTERN" 2>/dev/null || true)
      NUM_FILES=$(echo "$TARGET_FILES" | grep -c . || echo 0)

      if [ "$NUM_FILES" -gt 0 ]; then
        echo "Found $NUM_FILES matching files for title bar patch"
        TARGET_FILE=$(echo "$TARGET_FILES" | head -1)
        echo "Patching: $TARGET_FILE"

        # Apply title bar patch
        perl -i -pe 's{if\(!(\w+)\s*&&\s*(\w+)\)}{if($1 && $2)}g' "$TARGET_FILE"
        echo "Title bar patch applied"
      else
        echo "No MainWindowPage files found - title bar patch may not be needed"
      fi

      # Claude Code platform patch - add Linux support
      echo "Patching Claude Code platform detection for Linux..."
      INDEX_FILE="app.asar.contents/.vite/build/index.js"
      if [ -f "$INDEX_FILE" ]; then
        # Add Linux platform support to getPlatform() function
        # Original: if(process.platform==="win32")return"win32-x64";throw new Error
        # Patched:  if(process.platform==="win32")return"win32-x64";if(process.platform==="linux")return"linux-x64";throw new Error
        perl -i -pe 's{if\(process\.platform==="win32"\)return"win32-x64";throw}{if(process.platform==="win32")return"win32-x64";if(process.platform==="linux")return"linux-x64";throw}g' "$INDEX_FILE"
        echo "Claude Code platform patch applied"

        # Origin validation patch - allow file:// protocol when not packaged
        # The app checks isPackaged===true for file:// URLs, but Nix runs with isPackaged=false
        # Original: e.protocol==="file:"&&he.app.isPackaged===!0
        # Patched:  e.protocol==="file:"
        echo "Patching origin validation for file:// protocol..."
        perl -i -pe 's{e\.protocol==="file:"&&\w+\.app\.isPackaged===!0}{e.protocol==="file:"}g' "$INDEX_FILE"
        echo "Origin validation patch applied"

        # Linux tray stability patches (from claude-desktop-debian)
        # These fix common issues with system tray on Linux

        # 1. Theme-aware tray icon selection
        # macOS auto-inverts template icons; Linux needs explicit light/dark selection
        # Patch: Use shouldUseDarkColors to pick the right icon variant
        echo "Patching tray icon theme detection..."
        perl -i -pe 's{:(\w)="TrayIconTemplate\.png"}{:$1=require("electron").nativeTheme.shouldUseDarkColors?"TrayIconTemplate-Dark.png":"TrayIconTemplate.png"}g' "$INDEX_FILE"

        # 2. Tray menu concurrency guard (1500ms throttle)
        # Prevents rapid tray menu calls that can crash on Linux
        echo "Patching tray menu debouncing..."
        # Find the tray click handler function and add debounce guard
        # This pattern matches async tray handler functions
        perl -i -pe 's{(async function \w+Tray\w*\(\)\{)}{$1 if(arguments.callee._running)return;arguments.callee._running=true;setTimeout(()=>arguments.callee._running=false,1500);}g' "$INDEX_FILE"

        # 3. DBus cleanup delay (250ms)
        # Allow proper StatusNotifierItem unregistration before recreation
        echo "Patching DBus cleanup delay..."
        perl -i -pe 's{(\w+)&&\(\1\.destroy\(\),\1=null\)}{$1&&($1.destroy(),$1=null,await new Promise(r=>setTimeout(r,250)))}g' "$INDEX_FILE"

        # 4. Window blur before hide
        # Fixes quick-submit focus issues on Linux
        echo "Patching window blur before hide..."
        perl -i -pe 's{(\w+)\.hide\(\)}{$1.blur(),$1.hide()}g' "$INDEX_FILE"

        echo "Linux tray stability patches applied"
      else
        echo "Warning: index.js not found for Claude Code patch"
      fi

      # Replace native bindings - Mac uses @ant/claude-native path
      echo "Replacing native bindings..."
      mkdir -p app.asar.contents/node_modules/@ant/claude-native
      mkdir -p app.asar.unpacked/node_modules/@ant/claude-native
      cp ${patchy-cnb}/lib/patchy-cnb.*.node app.asar.contents/node_modules/@ant/claude-native/claude-native-binding.node
      cp ${patchy-cnb}/lib/patchy-cnb.*.node app.asar.unpacked/node_modules/@ant/claude-native/claude-native-binding.node

      # Create stub for @ant/claude-swift (Swift addon not available on Linux)
      echo "Creating Swift addon stubs..."
      mkdir -p app.asar.contents/node_modules/@ant/claude-swift/build/Release
      mkdir -p app.asar.unpacked/node_modules/@ant/claude-swift/build/Release
      # Use patchy-cnb as a stub for now - it will provide empty implementations
      cp ${patchy-cnb}/lib/patchy-cnb.*.node app.asar.contents/node_modules/@ant/claude-swift/build/Release/swift_addon.node
      cp ${patchy-cnb}/lib/patchy-cnb.*.node app.asar.unpacked/node_modules/@ant/claude-swift/build/Release/swift_addon.node

      # Copy tray icons and fix for Linux compatibility
      # On macOS, "Template" icons are semi-transparent and auto-inverted by the OS
      # Linux doesn't support this, so we need to:
      # 1. Copy both light and dark variants
      # 2. Make icons fully opaque (macOS templates are semi-transparent)
      # 3. Patch JS to dynamically select based on theme
      mkdir -p app.asar.contents/resources

      # Copy all tray icon variants
      cp "$RESOURCES"/TrayIconTemplate.png app.asar.contents/resources/ || true
      cp "$RESOURCES"/TrayIconTemplate@2x.png app.asar.contents/resources/ || true
      cp "$RESOURCES"/TrayIconTemplate@3x.png app.asar.contents/resources/ || true
      cp "$RESOURCES"/TrayIconTemplate-Dark.png app.asar.contents/resources/ || true
      cp "$RESOURCES"/TrayIconTemplate-Dark@2x.png app.asar.contents/resources/ || true
      cp "$RESOURCES"/TrayIconTemplate-Dark@3x.png app.asar.contents/resources/ || true
      cp "$RESOURCES"/Tray*.ico app.asar.contents/resources/ || true

      # Fix icon opacity - macOS template icons are semi-transparent for auto-inversion
      # Linux panels need fully opaque icons to be visible
      echo "Fixing tray icon opacity for Linux..."
      for icon in app.asar.contents/resources/TrayIconTemplate*.png; do
        if [ -f "$icon" ]; then
          convert "$icon" -channel A -fx "a>0?1:0" "$icon" || true
        fi
      done

      # Copy i18n json files
      mkdir -p app.asar.contents/resources/i18n
      cp "$RESOURCES"/*.json app.asar.contents/resources/i18n/ || true

      # Repackage app.asar
      asar pack app.asar.contents app.asar

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      # Electron directory structure
      mkdir -p $out/lib/$pname
      cp -r $TMPDIR/build/electron-app/app.asar $out/lib/$pname/
      cp -r $TMPDIR/build/electron-app/app.asar.unpacked $out/lib/$pname/

      # Install icons
      mkdir -p $out/share/icons
      cp -r $TMPDIR/build/icons/* $out/share/icons

      # Install .desktop file
      mkdir -p $out/share/applications
      install -Dm0644 {${desktopItem},$out}/share/applications/Claude.desktop

      # Create wrapper
      # NOTE: Global shortcuts (Ctrl+Alt+Space) don't work in native Wayland mode
      # due to Electron/Chromium limitations. We default to X11/XWayland for compatibility.
      # Set CLAUDE_USE_WAYLAND=1 to force native Wayland (shortcuts won't work).
      mkdir -p $out/bin
      makeWrapper ${electron}/bin/electron $out/bin/$pname \
        --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [glib-networking]}" \
        --add-flags "$out/lib/$pname/app.asar" \
        --add-flags "\''${CLAUDE_USE_WAYLAND:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations,UseOzonePlatform --gtk-version=4}" \
        --set GIO_EXTRA_MODULES "${glib-networking}/lib/gio/modules" \
        --set-default GDK_BACKEND "x11" \
        --set CHROME_DESKTOP "Claude.desktop" \
        --set-default GTK_THEME "\''${GTK_THEME:-Adwaita:dark}" \
        --set-default COLOR_SCHEME_PREFERENCE "\''${COLOR_SCHEME_PREFERENCE:-dark}" \
        --prefix XDG_DATA_DIRS : "$out/share"

      runHook postInstall
    '';

    dontUnpack = true;
    dontConfigure = true;

    meta = with lib; {
      description = "Claude Desktop for Linux";
      license = licenses.unfree;
      platforms = platforms.unix;
      sourceProvenance = with sourceTypes; [binaryNativeCode];
      mainProgram = pname;
    };
  }
