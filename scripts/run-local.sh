#!/bin/bash
# Build, sign, install and launch the independent development app.
set -euo pipefail
REMARC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMARC_APP_DIR="$REMARC_ROOT/app"
REMARC_PACKAGE="$REMARC_APP_DIR/RemarcPackage"
REMARC_OUTPUT="$REMARC_APP_DIR/DerivedData/Build/Products/Debug/Remarc Dev.app"
REMARC_LOCK_BACKUP="$(mktemp -t remarc-local-lock)"
cp "$REMARC_PACKAGE/Package.resolved" "$REMARC_LOCK_BACKUP"
trap 'cp "$REMARC_LOCK_BACKUP" "$REMARC_PACKAGE/Package.resolved"; rm -f "$REMARC_LOCK_BACKUP"' EXIT
REMARC_XCODE_VERSION="$(xcodebuild -version 2>/dev/null | head -n 1 | awk '{print $2}')" || true
if python3 - "${REMARC_XCODE_VERSION:-0}" <<'PYTHON'
import sys
raise SystemExit(0 if tuple(map(int, sys.argv[1].split('.'))) >= (26, 2) else 1)
PYTHON
then
    export REMARC_BUILD_CONFIGURATION=Debug
    if [[ "$(uname -m)" = x86_64 ]]; then
        bash "$REMARC_ROOT/scripts/build-ventura.sh"
    else
        bash "$REMARC_ROOT/scripts/build-apple-silicon.sh"
    fi
else
    echo "Building a signed Remarc Dev preview with Command Line Tools."
    REMARC_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    if [ ! -d "$REMARC_SDK" ]; then
        echo "This preview needs the macOS 26.5 SDK, or full Xcode selected with xcode-select." >&2
        exit 1
    fi
    # CLT lacks Apple's SwiftUI macro plugins. Expand the single @Entry in an
    # isolated dependency copy and omit its Xcode-only canvas previews. The
    # pinned dependency and all repository sources remain unchanged.
    swift package --package-path "$REMARC_PACKAGE" resolve
    REMARC_KEYBOARD="$REMARC_APP_DIR/DerivedData/LocalDependencies/KeyboardShortcuts"
    if [ ! -d "$REMARC_KEYBOARD" ]; then
        mkdir -p "$(dirname "$REMARC_KEYBOARD")"
        ditto "$REMARC_PACKAGE/.build/checkouts/KeyboardShortcuts" "$REMARC_KEYBOARD"
        chmod -R u+w "$REMARC_KEYBOARD"
    fi
    python3 - "$REMARC_KEYBOARD" <<'PYTHON'
from pathlib import Path
import sys
root = Path(sys.argv[1]) / 'Sources/KeyboardShortcuts'
path = root / 'ConflictPolicy.swift'
source = path.read_text()
old = 'extension EnvironmentValues {\n\t@Entry\n\tvar keyboardShortcutsConflictPolicy = KeyboardShortcuts.ConflictPolicy.default\n}'
replacement = '''private struct LocalConflictPolicyKey: EnvironmentKey {
    static let defaultValue = KeyboardShortcuts.ConflictPolicy.default
}
extension EnvironmentValues {
    var keyboardShortcutsConflictPolicy: KeyboardShortcuts.ConflictPolicy {
        get { self[LocalConflictPolicyKey.self] }
        set { self[LocalConflictPolicyKey.self] = newValue }
    }
}'''
if old in source:
    path.write_text(source.replace(old, replacement))
elif 'LocalConflictPolicyKey' not in source:
    raise SystemExit('Unsupported KeyboardShortcuts macro layout. Use full Xcode.')
path = root / 'Recorder.swift'
source = path.read_text()
if '\n#Preview {' in source:
    path.write_text(source[:source.index('\n#Preview {')] + '\n#endif\n')
PYTHON
    swift package --package-path "$REMARC_PACKAGE" edit KeyboardShortcuts --path "$REMARC_KEYBOARD" 2>/dev/null || \
        test -f "$REMARC_KEYBOARD/Sources/KeyboardShortcuts/ConflictPolicy.swift"
    if [ "${1:-}" = "--clean" ]; then
        swift package --package-path "$REMARC_PACKAGE" --build-system native --sdk "$REMARC_SDK" clean
    fi
    # Compile the real feature package and the real application entry point.
    # The normal release continues to use Xcode and its asset compiler.
    swift build --package-path "$REMARC_PACKAGE" --build-system native --sdk "$REMARC_SDK" \
        -Xswiftc -DREMARC_COMMAND_LINE_PREVIEW --product RemarcFeature
    REMARC_BIN="$(swift build --package-path "$REMARC_PACKAGE" --build-system native --sdk "$REMARC_SDK" --show-bin-path)"
    REMARC_SPARKLE="$REMARC_PACKAGE/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
    test -d "$REMARC_SPARKLE/Sparkle.framework"
    mkdir -p "$REMARC_OUTPUT/Contents/MacOS" "$REMARC_OUTPUT/Contents/Resources" "$REMARC_OUTPUT/Contents/Frameworks"
    REMARC_OBJECTS=()
    while IFS= read -r -d '' REMARC_OBJECT; do
        case "$REMARC_OBJECT" in
            *Tests.build/*|*PackageDiscoveredTests.build/*|*PackageTests.build/*) continue ;;
        esac
        REMARC_OBJECTS+=("$REMARC_OBJECT")
    done < <(find "$REMARC_BIN" -name '*.o' -type f -print0)
    swiftc -parse-as-library -D DEBUG -swift-version 5 \
        -sdk "$REMARC_SDK" -target "$(uname -m)-apple-macosx14.0" \
        -I "$REMARC_BIN/Modules" -F "$REMARC_SPARKLE" \
        -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
        "$REMARC_APP_DIR/Remarc/RemarcApp.swift" "${REMARC_OBJECTS[@]}" \
        -o "$REMARC_OUTPUT/Contents/MacOS/RemarcDev"
    cp "$REMARC_APP_DIR/Remarc/Info.plist" "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.metepolat.Remarc.dev' "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string RemarcDev' "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleName string Remarc Dev' "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Remarc Dev' "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 1.2.4' "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 23' "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$REMARC_OUTPUT/Contents/Info.plist"
    # SwiftPM accessors retain a fallback to the local build directory. Keep
    # conventional resource copies here as well; app bundle roots must be sealed.
    for REMARC_RESOURCE in "$REMARC_BIN"/*.bundle; do
        [ -d "$REMARC_RESOURCE" ] || continue
        ditto "$REMARC_RESOURCE" "$REMARC_OUTPUT/Contents/Resources/$(basename "$REMARC_RESOURCE")"
        if [ -d "$REMARC_OUTPUT/$(basename "$REMARC_RESOURCE")" ]; then
            rm -rf "$REMARC_OUTPUT/$(basename "$REMARC_RESOURCE")"
        fi
    done
    ditto "$REMARC_SPARKLE/Sparkle.framework" "$REMARC_OUTPUT/Contents/Frameworks/Sparkle.framework"
    # Command Line Tools has no actool. Reuse only installed visual assets
    # when available; application code is entirely compiled from this checkout.
    for REMARC_ASSET in Assets.car; do
        if [ -f "/Applications/Remarc.app/Contents/Resources/$REMARC_ASSET" ]; then
            cp "/Applications/Remarc.app/Contents/Resources/$REMARC_ASSET" "$REMARC_OUTPUT/Contents/Resources/$REMARC_ASSET"
        fi
    done
    cp "$REMARC_ROOT/mcp/vendor/remarc-mcp.js" "$REMARC_OUTPUT/Contents/Resources/remarc-mcp.js"
    cp "$REMARC_ROOT/mcp/skill/SKILL.md" "$REMARC_OUTPUT/Contents/Resources/remarc-skill.md"
    if [ -d "$REMARC_ROOT/Remarc.popclipext" ]; then
        ditto "$REMARC_ROOT/Remarc.popclipext" "$REMARC_OUTPUT/Contents/Resources/Remarc.popclipext"
    fi
    # The CLT preview reuses production visual assets only where available;
    # its app and menu icons always come from the development assets in this repo.
    cp "$REMARC_ROOT/app/Remarc/Assets.xcassets/MenuBarIconDev.imageset/"*.png "$REMARC_OUTPUT/Contents/Resources/"
    REMARC_ICONSET="$REMARC_APP_DIR/DerivedData/Development.iconset"
    mkdir -p "$REMARC_ICONSET"
    python3 - "$REMARC_ROOT" "$REMARC_ICONSET" "$REMARC_OUTPUT" <<'PYTHON'
from pathlib import Path
import plistlib, re, sys
root, iconset, app = map(Path, sys.argv[1:])
assets = root / 'app/Remarc/Assets.xcassets/AppIconDev.appiconset'
for size in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        suffix = '@2x' if scale == 2 else ''
        (iconset / f'icon_{size}x{size}{suffix}.png').write_bytes((assets / f'icon_{size*scale}x{size*scale}.png').read_bytes())
plist = app / 'Contents/Info.plist'
info = plistlib.loads(plist.read_bytes())
config = (root / 'app/Config/Shared.xcconfig').read_text()
for key, setting in [('CFBundleShortVersionString', 'MARKETING_VERSION'), ('CFBundleVersion', 'CURRENT_PROJECT_VERSION')]:
    info[key] = re.search(r'^' + setting + r'\s*=\s*(.+)$', config, re.M).group(1).strip()
info['CFBundleIconFile'] = 'AppIconDev.icns'
info['CFBundleIconName'] = 'AppIconDev'
plist.write_bytes(plistlib.dumps(info))
PYTHON
    iconutil -c icns "$REMARC_ICONSET" -o "$REMARC_OUTPUT/Contents/Resources/AppIconDev.icns"
    python3 "$REMARC_ROOT/scripts/prepare-app.py" "$REMARC_OUTPUT" --channel development
    python3 "$REMARC_ROOT/scripts/sign-app.py" "$REMARC_OUTPUT" --channel development
    python3 "$REMARC_ROOT/scripts/relaunch-app.py" "$REMARC_OUTPUT"
fi
python3 "$REMARC_ROOT/scripts/install-app.py" "$REMARC_OUTPUT" --channel development
