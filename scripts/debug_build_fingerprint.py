"""Bind a signed Debug bundle to the inputs verified by its Swift build."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

RECORD = "DebugBuild.json"
BUILD_COMMAND = "MANPING_SIGN_IDENTITY=- python3 scripts/build_debug_app.py"


def source_manifest(root):
    root = Path(root)
    inputs = [root / name for name in (
        "Package.swift", "Package.resolved", "scripts/build_debug_app.py",
        "scripts/debug_build_fingerprint.py", "scripts/resource_bundles.py")]
    for directory in ("Sources", "Resources"):
        inputs.extend(path for path in (root / directory).rglob("*")
                      if path.is_file() and path.name != ".DS_Store")
    files = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
             for path in sorted(inputs) if path.is_file()}
    fingerprint = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    return {"fingerprint": fingerprint, "files": files}


def write_build_record(app, manifest, verified):
    record = {"schema": 1, "verified": verified, **manifest}
    (Path(app) / "Contents/Resources" / RECORD).write_text(
        json.dumps(record, ensure_ascii=False, sort_keys=True, indent=2) + "\n")


def validate_build_record(record, current):
    if not isinstance(record, dict) or record.get("schema") != 1 or record.get("verified") is not True or not isinstance(record.get("files"), dict):
        raise RuntimeError(f"Debug build is unverified (--no-build cannot certify source freshness). Rebuild: {BUILD_COMMAND}")
    if record.get("fingerprint") != current["fingerprint"] or record.get("files") != current["files"]:
        old_files = record.get("files", {})
        changed = [name for name in sorted(old_files.keys() | current["files"].keys())
                   if old_files.get(name) != current["files"].get(name)]
        raise RuntimeError(f"Debug bundle is stale; changed inputs: {', '.join(changed[:6]) or 'fingerprint'}. Rebuild: {BUILD_COMMAND}")


def require_fresh_debug_app(root, app):
    app = Path(app)
    with (app / "Contents/Info.plist").open("rb") as handle:
        if plistlib.load(handle).get("CFBundleIdentifier") != "io.github.pidean.manping.debug":
            raise RuntimeError("In-app capture requires the isolated Manping Debug bundle")
    try:
        record = json.loads((app / "Contents/Resources" / RECORD).read_text())
    except (OSError, ValueError) as error:
        raise RuntimeError(f"Debug bundle has no build fingerprint. Rebuild: {BUILD_COMMAND}") from error
    validate_build_record(record, source_manifest(root))
    # The resource seal binds this source record to the executable copied by the builder.
    result = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                            capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Debug bundle signature is invalid. Rebuild: {BUILD_COMMAND}")
    return record["fingerprint"]
