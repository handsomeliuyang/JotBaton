"""Executable dependency rules for the macOS package; no dependency resolution."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "app/RemarcPackage"
ALLOWED = {
    "CorePlatform": set(),
    "CoreLocalization": set(),
    "CoreTheme": set(),
    "CoreUI": {"CorePlatform", "CoreLocalization", "CoreTheme"},
    "FeatureComments": {"CorePlatform", "CoreLocalization"},
    "FeatureCapture": {"CorePlatform", "CoreLocalization", "CoreTheme", "CoreUI"},
    "FeatureIntegrations": {"CorePlatform", "CoreLocalization"},
    "FeatureSnapshotSync": {"CorePlatform", "CoreLocalization", "FeatureComments", "FeatureCapture"},
    "FeatureUpdates": {"CorePlatform", "CoreLocalization"},
    "FeatureSettings": {
        "CorePlatform", "CoreLocalization", "CoreUI", "FeatureComments",
        "FeatureCapture", "FeatureIntegrations",
    },
    "FeatureOnboarding": {"CorePlatform", "CoreLocalization", "CoreTheme", "CoreUI", "FeatureCapture"},
}
APP = "RemarcFeature"
EXTERNAL = {"KeyboardShortcuts", "Sparkle", "AppMover"}


def manifest(ventura):
    env = {**os.environ, "REMARC_VENTURA": "1" if ventura else "0"}
    # Manifest inspection must not wait for a concurrent app build's .build lock.
    with tempfile.TemporaryDirectory(prefix="remarc-manifest-") as scratch:
        return json.loads(subprocess.check_output(
            ["swift", "package", "--package-path", str(PACKAGE),
             "--scratch-path", scratch, "dump-package"],
            env=env, text=True,
        ))


def dependencies(target):
    names = set()
    for dependency in target["dependencies"]:
        for kind in ("byName", "target", "product"):
            if kind in dependency:
                names.add(dependency[kind][0])
    return names


def owned_sources(target):
    root = PACKAGE / (target.get("path") or "Sources/" + target["name"])
    excluded = [root / path for path in target.get("exclude", [])]
    sources = target.get("sources")
    entries = [root / path for path in sources] if sources is not None else [root]
    files = set()
    for entry in entries:
        candidates = [entry] if entry.is_file() else entry.rglob("*.swift")
        for source in candidates:
            if source.suffix == ".swift" and not any(source == path or path in source.parents for path in excluded):
                files.add(source)
    return files


class SwiftBoundariesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.profiles = [manifest(False), manifest(True)]

    def test_both_profiles_preserve_dependency_direction_and_declared_imports(self):
        owned = set(ALLOWED) | {APP}
        for profile in self.profiles:
            targets = {t["name"]: t for t in profile["targets"]}
            self.assertTrue(owned <= targets.keys())
            for name in owned:
                declared = dependencies(targets[name])
                permitted = owned - {APP} if name == APP else ALLOWED[name]
                self.assertLessEqual(declared & owned, permitted, name)
                for source in owned_sources(targets[name]):
                    imports = set(re.findall(
                        r"^\s*(?:@\w+\s+)?import\s+(\w+)", source.read_text(), re.M
                    ))
                    self.assertLessEqual(
                        imports & (owned | EXTERNAL), declared,
                        str(source.relative_to(ROOT)),
                    )

    def test_modules_do_not_reexport_implementations_or_bypass_access_control(self):
        for source in (PACKAGE / "Sources").rglob("*.swift"):
            text = source.read_text()
            self.assertNotRegex(text, r"@(?:_exported|testable)\s+import", str(source))
        targets = {t["name"]: t for t in self.profiles[0]["targets"]}
        for name in ALLOWED:
            for source in owned_sources(targets[name]):
                forbidden = r"\bAppServices\b" if name == "FeatureSettings" else r"\b(?:AppServices|SettingsManager)\b"
                self.assertNotRegex(source.read_text(), forbidden, str(source))

    def test_every_source_has_exactly_one_compilation_owner(self):
        for profile in self.profiles:
            owners = {}
            for target in profile["targets"]:
                if target["name"] == "RemarcFeatureTests":
                    continue
                for source in owned_sources(target):
                    self.assertNotIn(source, owners, str(source))
                    owners[source] = target["name"]
            self.assertEqual(set(owners), set((PACKAGE / "Sources").rglob("*.swift")))

    def test_resource_owners_are_stable(self):
        self.assertTrue((PACKAGE / "Sources/Core/Localization/Resources/Localizations.json").is_file())
        for legacy in ("Views", "Models", "Services", "Utilities", "Annotation", "Core"):
            self.assertFalse((PACKAGE / "Sources" / APP / legacy).exists())


if __name__ == "__main__":
    unittest.main()
