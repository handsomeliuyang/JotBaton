#!/bin/bash
set -euo pipefail
REMARC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMARC_PACKAGE="$REMARC_ROOT/app/RemarcPackage"
if xcodebuild -version >/dev/null 2>&1; then
    swift test --package-path "$REMARC_PACKAGE" --filter CloudSync
    exit
fi

# Run the iCloud sync suite separately from the existing XCTest suite;
# CLT ships Swift Testing, but not XCTest or Apple's UI macro plugins.
REMARC_KEYBOARD="$REMARC_ROOT/app/DerivedData/LocalDependencies/KeyboardShortcuts"
if [ ! -f "$REMARC_KEYBOARD/Sources/KeyboardShortcuts/ConflictPolicy.swift" ]; then
    echo "Run scripts/run-local.sh first to prepare the isolated CLT preview dependencies." >&2
    exit 1
fi
python3 - "$REMARC_ROOT" <<'PYTHON'
from pathlib import Path
import json
import shutil
import sys
root = Path(sys.argv[1])
checks = root / 'app/DerivedData/CloudSyncChecks'
(checks / 'Tests').mkdir(parents=True, exist_ok=True)
lock = root / 'app/RemarcPackage/Package.resolved'
pins = json.loads(lock.read_text())['pins']
dependencies = []
for pin in pins:
    version = pin['state'].get('version')
    if version and pin['identity'] != 'keyboardshortcuts':
        dependencies.append('.package(url: %s, exact: %s)' % (json.dumps(pin['location']), json.dumps(version)))
dependencies += ['.package(path: %s)' % json.dumps(str(root / 'app/RemarcPackage')),
                 '.package(path: %s)' % json.dumps(str(root / 'app/DerivedData/LocalDependencies/KeyboardShortcuts'))]
(checks / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CloudSyncChecks", platforms: [.macOS(.v14)],
    dependencies: [%s],
    targets: [.testTarget(name: "CloudSyncChecks", dependencies: [
        .product(name: "RemarcFeature", package: "RemarcPackage")], path: "Tests")])
''' % ', '.join(dependencies))
test = checks / 'Tests/CloudSyncTests.swift'
if not test.exists():
    test.symlink_to(root / 'app/RemarcPackage/Tests/RemarcFeatureTests/Features/CloudSync/CloudSyncTests.swift')
if not (checks / 'Package.resolved').exists():
    shutil.copyfile(lock, checks / 'Package.resolved')
PYTHON
swift test --package-path "$REMARC_ROOT/app/DerivedData/CloudSyncChecks" \
    --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -Xswiftc -DREMARC_COMMAND_LINE_PREVIEW \
    -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
    --disable-xctest --enable-swift-testing
