#!/usr/bin/env python3
"""Reuse the sealed runtime closure for a local UI Debug app; never rebuild libmpv."""
import argparse
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from resource_bundles import copy_resource_bundles  # noqa: E402



SIGNING_NAME = "Manping Local Signing"


def signing_identity():
    """A stable local code-signing certificate keeps Keychain approvals across rebuilds.

    Ad-hoc signatures change with every build, so macOS treats each build as a new app and asks
    for the Keychain password again. If the user created a self-signed "Manping Local
    Signing" certificate (see docs/Signing.md) or set MANPING_SIGN_IDENTITY, sign with it instead.
    """
    explicit = os.environ.get("MANPING_SIGN_IDENTITY")
    if explicit:
        return explicit
    listed = subprocess.run(["security", "find-identity", "-p", "codesigning"],
        capture_output=True, text=True).stdout
    return SIGNING_NAME if f'"{SIGNING_NAME}"' in listed else "-"

def run(*args, capture=False):
    if capture:
        return subprocess.check_output(args, text=True).strip()
    subprocess.check_call(args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=pathlib.Path,
                        default=ROOT / "dist/release/满屏.app")
    parser.add_argument("--no-build", action="store_true")
    args = parser.parse_args()
    os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    template = args.template.resolve()
    app = ROOT / ".build/ui/满屏 Debug.app"
    if not (template / "Contents/Frameworks/libmpv.2.dylib").is_file():
        raise RuntimeError("A bundled runtime template with libmpv.2.dylib is required")
    if template == app.resolve():
        raise RuntimeError("Template cannot be the Debug output")
    if not args.no_build:
        run("swift", "build")
    binary_directory = pathlib.Path(run("swift", "build", "--show-bin-path", capture=True))
    if app.exists():
        shutil.rmtree(app)
    shutil.copytree(template, app)
    executable = app / "Contents/MacOS/Manping"
    shutil.copy2(binary_directory / "Manping", executable)
    resources = app / "Contents/Resources"
    copy_resource_bundles(binary_directory, resources)
    # The Release executable manifest does not describe this local Debug executable.
    (resources / "BundleManifest.json").unlink(missing_ok=True)
    shutil.copy2(ROOT / "Resources/AppIcon/AppIconDebug.icns", resources / "AppIcon.icns")
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    info["CFBundleDisplayName"] = "满屏 Debug"
    info["CFBundleIdentifier"] = "io.github.pidean.manping.debug"
    info["CFBundleIconFile"] = "AppIcon"
    info["CFBundleIconName"] = "AppIcon"
    # Same link scheme as Release (the template may predate it).
    info["CFBundleURLTypes"] = [{"CFBundleURLName": "io.github.pidean.manping.link", "CFBundleURLSchemes": ["manping"],
        "CFBundleTypeRole": "Viewer"}]
    with (app / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
    run("codesign", "--force", "--sign", signing_identity(), str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    print(app)
    print("Launch: open -n " + str(app) + " --args --skip-auth --ui-page popular")


if __name__ == "__main__":
    main()
