"""Copy only the SwiftPM resource bundles the product needs, with stable identifiers.

SwiftPM leaves every bundle it ever produced in the build folder (tests, targets from before
the rename) and derives each bundle's CFBundleIdentifier from the checkout folder name. An
explicit allow-list keeps those out of the app, and the identifier is rewritten to a value
that does not depend on the folder name.
"""
import pathlib
import plistlib
import shutil

# The product's own bundle: SwiftPM name -> stable identifier.
OWN = {'Manping_ManpingApp.bundle': 'io.github.pidean.manping.ManpingApp.resources'}
# Dependencies of the executable that ship privacy manifests; their identifiers stay as built.
THIRD_PARTY = ('SwiftProtobuf_SwiftProtobuf.bundle', 'swift-nio_NIOPosix.bundle')


def copy_resource_bundles(bin_dir, resources):
    """Copy the allow-listed bundles into `resources`, drop any other bundle there; fail if one is missing."""
    bin_dir, resources = pathlib.Path(bin_dir), pathlib.Path(resources)
    missing = [name for name in (*OWN, *THIRD_PARTY) if not (bin_dir / name).is_dir()]
    if missing:
        raise RuntimeError(f'Required resource bundles missing from {bin_dir}: {", ".join(missing)}')
    # A template app (build_debug_app.py copies the Release app) may carry bundles from older builds.
    for stale in resources.glob('*.bundle'):
        if stale.name not in (*OWN, *THIRD_PARTY): shutil.rmtree(stale)
    for name in (*OWN, *THIRD_PARTY):
        destination = resources / name
        if destination.exists(): shutil.rmtree(destination)
        shutil.copytree(bin_dir / name, destination)
        if name in OWN:
            info = destination / 'Contents' / 'Info.plist'
            with info.open('rb') as handle: plist = plistlib.load(handle)
            plist['CFBundleIdentifier'] = OWN[name]
            with info.open('wb') as handle: plistlib.dump(plist, handle)
