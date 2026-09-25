#!/usr/bin/env python3
"""Validate a Mac iCloud profile and merge its capability into generated entitlements."""
import datetime
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys


def validated_entitlements(profile, info, entitlements, environment):
    allowed = profile["Entitlements"]
    container = "iCloud.com.neilgoldader.planmeter"
    app_id = entitlements.get("com.apple.application-identifier")
    if not app_id or allowed.get("com.apple.application-identifier") != app_id:
        raise ValueError("iCloud profile does not match the signed Mac app identifier.")
    if not app_id.endswith("." + info["CFBundleIdentifier"]):
        raise ValueError("iCloud profile does not match the bundle identifier.")
    if container not in allowed.get("com.apple.developer.icloud-container-identifiers", []):
        raise ValueError("iCloud profile does not authorize the PlanMeter container.")
    services = allowed.get("com.apple.developer.icloud-services", [])
    if services != "*" and "CloudKit" not in services and "*" not in services:
        raise ValueError("iCloud profile does not authorize CloudKit.")
    if profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise ValueError("iCloud profile has expired.")
    environments = allowed.get("com.apple.developer.icloud-container-environment", [])
    if isinstance(environments, str):
        environments = [environments]
    if environment not in ("Production", "Development") or environment not in environments:
        raise ValueError("iCloud profile does not authorize the requested environment.")
    team = allowed.get("com.apple.developer.team-identifier")
    if not team or not app_id.startswith(team + "."):
        raise ValueError("iCloud profile has a mismatched team identifier.")
    return {**entitlements,
        "com.apple.developer.icloud-container-identifiers": [container],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-environment": environment,
        "com.apple.developer.team-identifier": team,
    }


def main():
    profile_path, app_path, entitlements_path = map(pathlib.Path, sys.argv[1:])
    profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(profile_path)]))
    info = plistlib.loads((app_path / "Contents/Info.plist").read_bytes())
    entitlements = plistlib.loads(entitlements_path.read_bytes())
    environment = os.environ.get("ICLOUD_ENVIRONMENT", "Production")
    try:
        entitlements = validated_entitlements(profile, info, entitlements, environment)
    except ValueError as error:
        sys.exit(str(error))
    shutil.copyfile(profile_path, app_path / "Contents/embedded.provisionprofile")
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    print(f"Configured iCloud signing ({environment}).")


if __name__ == "__main__":
    main()
