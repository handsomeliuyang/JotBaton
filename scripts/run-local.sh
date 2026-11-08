#!/bin/bash
# Build and launch the current checkout without committing or using GitHub.
set -euo pipefail

REMARC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMARC_APP_DIR="$REMARC_ROOT/app"
REMARC_PACKAGE="$REMARC_APP_DIR/RemarcPackage"
REMARC_OUTPUT="$REMARC_APP_DIR/DerivedData/Build/Products/Debug/Remarc.app"
REMARC_LOCK_BACKUP="$(mktemp -t remarc-local-lock)"
cp "$REMARC_PACKAGE/Package.resolved" "$REMARC_LOCK_BACKUP"
trap 'cp "$REMARC_LOCK_BACKUP" "$REMARC_PACKAGE/Package.resolved"; rm -f "$REMARC_LOCK_BACKUP"' EXIT

if xcodebuild -version >/dev/null 2>&1; then
    cd "$REMARC_APP_DIR"
    if [ ! -f Remarc.xcworkspace/contents.xcworkspacedata ]; then
        mkdir -p Remarc.xcworkspace
        cat > Remarc.xcworkspace/contents.xcworkspacedata <<'WORKSPACE'
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0">
  <FileRef location="group:RemarcPackage"/>
  <FileRef location="container:Remarc.xcodeproj"/>
</Workspace>
WORKSPACE
    fi
    xcodebuild clean build -workspace Remarc.xcworkspace -scheme Remarc \
        -configuration Debug -derivedDataPath "$(pwd)/DerivedData" \
        CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
else
    echo "Full Xcode is unavailable; building a SwiftPM local preview with Command Line Tools."
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
    REMARC_MODULE_MAPS=()
    while IFS= read -r -d '' REMARC_MODULE_MAP; do
        REMARC_MODULE_MAPS+=(-Xcc "-fmodule-map-file=$REMARC_MODULE_MAP")
    done < <(find "$REMARC_PACKAGE/.build/checkouts/FluidAudio/Sources" -name module.modulemap -type f -print0)
    swiftc -parse-as-library -D DEBUG -swift-version 5 \
        -sdk "$REMARC_SDK" -target "$(uname -m)-apple-macosx14.0" \
        -I "$REMARC_BIN/Modules" -F "$REMARC_SPARKLE" \
        -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
        "${REMARC_MODULE_MAPS[@]}" "$REMARC_APP_DIR/Remarc/RemarcApp.swift" "${REMARC_OBJECTS[@]}" \
        -o "$REMARC_OUTPUT/Contents/MacOS/Remarc"
    cp "$REMARC_APP_DIR/Remarc/Info.plist" "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.metepolat.Remarc' "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string Remarc' "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleName string Remarc' "$REMARC_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Remarc Local' "$REMARC_OUTPUT/Contents/Info.plist"
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
    for REMARC_ASSET in Assets.car AppIcon.icns; do
        if [ -f "/Applications/Remarc.app/Contents/Resources/$REMARC_ASSET" ]; then
            cp "/Applications/Remarc.app/Contents/Resources/$REMARC_ASSET" "$REMARC_OUTPUT/Contents/Resources/$REMARC_ASSET"
        fi
    done
    cp "$REMARC_ROOT/mcp/vendor/remarc-mcp.js" "$REMARC_OUTPUT/Contents/Resources/remarc-mcp.js"
    cp "$REMARC_ROOT/mcp/skill/SKILL.md" "$REMARC_OUTPUT/Contents/Resources/remarc-skill.md"
    if [ -d "$REMARC_ROOT/Remarc.popclipext" ]; then
        ditto "$REMARC_ROOT/Remarc.popclipext" "$REMARC_OUTPUT/Contents/Resources/Remarc.popclipext"
    fi
    codesign --force --deep --sign - "$REMARC_OUTPUT"
fi

test -x "$REMARC_OUTPUT/Contents/MacOS/Remarc"
pkill -x Remarc || true
sleep 0.5
open "$REMARC_OUTPUT" --args --show-sync
echo "Running local source: $REMARC_OUTPUT"
