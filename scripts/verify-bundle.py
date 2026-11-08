#!/usr/bin/env python3
"""Validate the identities WidgetKit and App Intents use at runtime."""

import argparse
import plistlib
import subprocess
import sys
from pathlib import Path


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def check(condition, message):
    if not condition:
        raise ValueError(message)


def verify(bundle, identifier, developer_id):
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    check(info["CFBundleIdentifier"] == identifier, f"Unexpected bundle ID: {bundle.name}")
    run("codesign", "--verify", "--strict", str(bundle))
    entitlements = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(bundle)))
    check(not entitlements.get("com.apple.security.get-task-allow", False),
          f"Debugger access enabled in distribution bundle: {bundle.name}")
    check("group.dev.trendingtab.shared" in entitlements.get("com.apple.security.application-groups", []),
          f"App Group missing: {bundle.name}")
    if bundle.suffix == ".appex":
        check(entitlements.get("com.apple.security.app-sandbox") is True, "Widget sandbox missing")
        check(info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
              "WidgetKit extension point missing")
    if developer_id:
        metadata = subprocess.run(["codesign", "-dv", "--verbose=4", str(bundle)],
                                  check=True, capture_output=True).stderr.decode()
        team = next((line.split("=", 1)[1] for line in metadata.splitlines()
                     if line.startswith("TeamIdentifier=")), None)
        check(team and team != "not set", f"Signing team missing: {bundle.name}")
        check(entitlements.get("com.apple.developer.team-identifier") == team,
              f"Runtime Team ID entitlement missing or mismatched: {bundle.name}")
        check(entitlements.get("com.apple.application-identifier") == f"{team}.{identifier}",
              f"Runtime application identifier missing or mismatched: {bundle.name}")
        check("Authority=Developer ID Application:" in metadata, f"Developer ID signature missing: {bundle.name}")
        check("Timestamp=" in metadata, f"Secure timestamp missing: {bundle.name}")
        profile_path = bundle / "Contents/embedded.provisionprofile"
        check(profile_path.is_file(), f"Provisioning profile missing: {bundle.name}")
        profile = plistlib.loads(run("security", "cms", "-D", "-i", str(profile_path)))
        expected = profile["Entitlements"]
        for name in ("com.apple.developer.team-identifier", "com.apple.application-identifier"):
            check(entitlements.get(name) == expected.get(name), f"Profile mismatch for {name}: {bundle.name}")
        check("group.dev.trendingtab.shared" in expected.get("com.apple.security.application-groups", []),
              f"Profile App Group missing: {bundle.name}")
    print(f"Verified runtime identity: {identifier}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--developer-id", action="store_true")
    args = parser.parse_args()
    try:
        verify(args.app, "dev.trendingtab.app", args.developer_id)
        verify(args.app / "Contents/PlugIns/TrendingTabWidget.appex", "dev.trendingtab.app.widget", args.developer_id)
        run("codesign", "--verify", "--deep", "--strict", str(args.app))
        run(sys.executable, str(Path(__file__).with_name("verify-native-architectures.py")), str(args.app))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Bundle validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
