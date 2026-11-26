#!/bin/bash
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="boo_box"
APP_BUNDLE="$ROOT/build/${APP_NAME}.app"
BIN_DIR="$ROOT/.build/${CONFIG}"

cd "$ROOT"
echo "Building ${APP_NAME} + boobox-attach + boobox-clone + boobox-proxy (${CONFIG})..."
swift build -c "$CONFIG" --product boo_box
swift build -c "$CONFIG" --product boobox-attach
swift build -c release --product boobox-clone
swift build -c "$CONFIG" --product boobox-proxy

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/vm"

cp "$BIN_DIR/boo_box" "$APP_BUNDLE/Contents/MacOS/boo_box"
cp "$BIN_DIR/boobox-attach" "$APP_BUNDLE/Contents/MacOS/boobox-attach"
cp "$ROOT/.build/release/boobox-clone" "$APP_BUNDLE/Contents/MacOS/boobox-clone"
cp "$BIN_DIR/boobox-proxy" "$APP_BUNDLE/Contents/MacOS/boobox-proxy"
chmod +x "$APP_BUNDLE/Contents/MacOS/boo_box" "$APP_BUNDLE/Contents/MacOS/boobox-attach" "$APP_BUNDLE/Contents/MacOS/boobox-clone" "$APP_BUNDLE/Contents/MacOS/boobox-proxy"
# App icon
if [ -f "$ROOT/Resources/boo_box.icns" ]; then
    cp "$ROOT/Resources/boo_box.icns" "$APP_BUNDLE/Contents/Resources/boo_box.icns"
fi

# Bundle `boo` and `boobox-env` CLI scripts under Resources/bin (keeps Contents/MacOS Mach-O-only for codesign)
mkdir -p "$APP_BUNDLE/Contents/Resources/bin"
if [ -f "$ROOT/scripts/boo" ]; then
    cp "$ROOT/scripts/boo" "$APP_BUNDLE/Contents/Resources/bin/boo"
    chmod +x "$APP_BUNDLE/Contents/Resources/bin/boo"
fi
if [ -f "$ROOT/scripts/boobox-env" ]; then
    cp "$ROOT/scripts/boobox-env" "$APP_BUNDLE/Contents/Resources/bin/boobox-env"
    chmod +x "$APP_BUNDLE/Contents/Resources/bin/boobox-env"
fi

# Bundle version-matched Ghostty 1.4.0 terminfo & shell integration
GHOSTTY_RES="/Applications/Ghostty.app/Contents/Resources"
if [ -d "$GHOSTTY_RES/terminfo" ]; then
    cp -R "$GHOSTTY_RES/terminfo" "$APP_BUNDLE/Contents/Resources/terminfo"
fi
if [ -d "$GHOSTTY_RES/ghostty" ]; then
    cp -R "$GHOSTTY_RES/ghostty" "$APP_BUNDLE/Contents/Resources/ghostty"
fi

# Bundle Linux microVM kernel + sparse APFS-cloned Alpine rootfs (zero extra disk blocks via cp -c)
if [ -f "$ROOT/Resources/vm/vmlinux-arm64" ] && [ -f "$ROOT/Resources/vm/rootfs.ext4" ]; then
    cp -c "$ROOT/Resources/vm/vmlinux-arm64" "$APP_BUNDLE/Contents/Resources/vm/vmlinux-arm64" \
        || cp "$ROOT/Resources/vm/vmlinux-arm64" "$APP_BUNDLE/Contents/Resources/vm/vmlinux-arm64"
    cp -c "$ROOT/Resources/vm/rootfs.ext4" "$APP_BUNDLE/Contents/Resources/vm/rootfs.ext4" \
        || cp "$ROOT/Resources/vm/rootfs.ext4" "$APP_BUNDLE/Contents/Resources/vm/rootfs.ext4"
else
    echo "WARNING: Resources/vm assets missing; run ./scripts/build-guest-image.sh first" >&2
fi

GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "")"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>boo_box</string>
    <key>CFBundleExecutable</key>
    <string>boo_box</string>
    <key>CFBundleIconFile</key>
    <string>boo_box</string>
    <key>CFBundleIdentifier</key>
    <string>dev.boo-box.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>boo_box</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>BooBoxGitRepo</key>
    <string>apguan/boo_box</string>
    <key>BooBoxGitCommit</key>
    <string>${GIT_COMMIT}</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Folder</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>dev.boo-box.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>boobox</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Sign nested helper first, then main app with Virtualization.framework entitlement
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/boobox-attach"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/boobox-clone"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/boobox-proxy"
codesign --force --sign - --entitlements "$ROOT/Resources/boo_box.entitlements" "$APP_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" 2>/dev/null || true

# Record built app path for portable `boo` CLI lookup & install/update `~/.local/bin/boo`
mkdir -p "$HOME/boo_box"
printf '%s\n' "$APP_BUNDLE" > "$HOME/boo_box/.app-path"
printf '%s\n' "$ROOT" > "$HOME/boo_box/.repo-path"
if [ -f "$ROOT/scripts/boo" ]; then
    mkdir -p "$HOME/.local/bin"
    cp "$ROOT/scripts/boo" "$HOME/.local/bin/boo"
    chmod +x "$HOME/.local/bin/boo"
fi
echo "Bundled: $APP_BUNDLE (CLI installed at ~/.local/bin/boo)"
