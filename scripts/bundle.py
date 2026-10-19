#!/usr/bin/env python3
"""Build an arm64, recursively closed, ad-hoc signed .app without Homebrew runtime paths."""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import uuid

from resource_bundles import copy_resource_bundles

ROOT = pathlib.Path(__file__).resolve().parents[1]

# The original product name; Finder, Launchpad and Spotlight show the bundle file name.
APP_NAME = '满屏.app'



SIGNING_NAME = "Manping Local Signing"
# Release signing kept outside the repository and outside the login keychain's search list:
# a dedicated keychain file and its password (docs/Signing.md, 正式发布签名).
RELEASE_SIGNING = pathlib.Path.home() / "Library/Application Support/Manping Signing"
RELEASE_IDENTITY = "Manping Release Signing"


def signing_args():
    """codesign arguments for a stable identity, so Keychain approvals survive updates.

    Ad-hoc signatures change with every build, so macOS treats each build as a new app and asks
    for the Keychain password again. In order: MANPING_SIGN_IDENTITY (with an optional
    MANPING_SIGN_KEYCHAIN), the release signing keychain, a self-signed "Manping Local Signing"
    certificate in the login keychain (see docs/Signing.md), else ad-hoc.
    """
    explicit = os.environ.get("MANPING_SIGN_IDENTITY")
    if explicit:
        keychain = os.environ.get("MANPING_SIGN_KEYCHAIN")
        return ['--sign', explicit] + (['--keychain', keychain] if keychain else [])
    keychain = RELEASE_SIGNING / "signing.keychain-db"
    password = RELEASE_SIGNING / "keychain-password"
    if keychain.exists() and password.exists():
        subprocess.check_call(['security', 'unlock-keychain', '-p', password.read_text().strip(), str(keychain)])
        return ['--sign', RELEASE_IDENTITY, '--keychain', str(keychain)]
    listed = subprocess.run(["security", "find-identity", "-p", "codesigning"],
        capture_output=True, text=True).stdout
    return ['--sign', SIGNING_NAME if f'"{SIGNING_NAME}"' in listed else "-"]

def run(*args, capture=False):
    return subprocess.check_output(args, text=True).strip() if capture else subprocess.check_call(args)

def links(path):
    return [line.strip().split(' (compatibility')[0] for line in run('otool', '-L', str(path), capture=True).splitlines()[1:]]

def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

def system(dep):
    return dep.startswith('/System/Library/') or dep.startswith('/usr/lib/')

def resolve(dep, original, executable):
    if dep.startswith('@loader_path/'):
        return (original.parent / dep[len('@loader_path/'):]).resolve()
    if dep.startswith('@executable_path/'):
        return (executable.parent / dep[len('@executable_path/'):]).resolve()
    if dep.startswith('@rpath/'):
        suffix = dep[len('@rpath/'):]
        paths = [original.parent / suffix, pathlib.Path('/opt/homebrew/lib') / suffix]
        lines = run('otool', '-l', str(original), capture=True).splitlines()
        for index, line in enumerate(lines):
            if line.strip() == 'cmd LC_RPATH':
                raw = lines[index + 2].strip().split('path ')[1].split(' (offset')[0]
                base = raw.replace('@loader_path', str(original.parent)).replace('@executable_path', str(executable.parent))
                paths.append(pathlib.Path(base) / suffix)
        for candidate in paths:
            if candidate.exists(): return candidate.resolve()
        raise RuntimeError(f'Unresolved {dep} in {original}')
    return pathlib.Path(dep).resolve()

def portable(path):
    # Paths inside the project are recorded relative to it, so lock files and the bundled
    # origin list never carry the builder's home folder.
    # Anything else under a home folder is written as "~/…", never with the user name.
    path = pathlib.Path(path)
    if path.is_relative_to(ROOT): return str(path.relative_to(ROOT))
    if path.is_relative_to(pathlib.Path.home()): return '~/'+str(path.relative_to(pathlib.Path.home()))
    if path.is_relative_to('/Users'): raise RuntimeError(f'Refusing to record a path in another home folder: {path}')
    return str(path)

def canonical(path):
    # .build may be a symlink to a cache outside the synced project folder; record
    # project build outputs by their stable ROOT/.build path so the lock stays portable.
    build = (ROOT / '.build').resolve()
    return ROOT / '.build' / path.relative_to(build) if path.is_relative_to(build) else path

def input_closure(mpv, ffmpeg):
    found = {}
    def visit(original):
        original = pathlib.Path(original).resolve()
        if original in found: return
        found[original] = {'source': portable(canonical(original)), 'library': original.name, 'sha256': sha256(original)}
        for dep in links(original):
            if not system(dep): visit(resolve(dep, original, ffmpeg))
    visit(mpv)
    visit(ffmpeg)
    return found

def verify_lock(lock, actual, mpv_metadata, ffmpeg):
    expected = {item['source']: item['sha256'] for item in lock['libraries']}
    observed = {item['source']: item['sha256'] for path, item in actual.items() if path != ffmpeg}
    if expected != observed:
        raise RuntimeError('Dependency closure/input SHA mismatch; review sources and use --update-lock explicitly')
    if lock.get('ffmpegExecutable') != {'source': portable(ffmpeg), 'sha256': sha256(ffmpeg)}:
        raise RuntimeError('FFmpeg executable input SHA mismatch')
    if lock.get('mpvPatchedBuild') != mpv_metadata:
        raise RuntimeError('MpvBuild metadata mismatch')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mpv', default=str(ROOT / '.build/mpv-build/libmpv.2.dylib'))
    parser.add_argument('--ffmpeg', default='/opt/homebrew/bin/ffmpeg')
    parser.add_argument('--debug', action='store_true')
    parser.add_argument('--update-lock', action='store_true')
    parser.add_argument('--verify-inputs', action='store_true')
    parser.add_argument('--scratch-path', type=pathlib.Path, default=ROOT / '.build' / 'release-bundle-v2')  # v1's XCBuildData build.db was corrupt (disk I/O error)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'dist' / 'release' / APP_NAME)
    parser.add_argument('--replace-release', action='store_true', help='Stage and verify a new canonical Release, retaining the previous one under .build')
    args = parser.parse_args()
    app = args.output.resolve()
    publish = None
    if not args.verify_inputs:
        release = ROOT / 'dist' / 'release'
        sealed = [ROOT / 'dist' / name for name in ('integration', 'diagnostics', 'renderer')]
        if any(app.is_relative_to(path.resolve()) for path in sealed):
            raise RuntimeError('Sealed runtime archives are read-only; dist outputs must be under dist/release')
        if app.is_relative_to((ROOT / 'dist').resolve()) and (release.is_symlink() or not app.is_relative_to(release.resolve())):
            raise RuntimeError('Only dist/release may be written under dist')
        if args.replace_release:
            if app != release / APP_NAME:
                raise RuntimeError('--replace-release only supports dist/release/' + APP_NAME)
            publish = app
            app = ROOT / '.build' / 'release-stage' / uuid.uuid4().hex / APP_NAME
        elif app.exists() or (app.parent / 'BundleManifest.json').exists():
            raise RuntimeError('Release output already exists; use --replace-release or a new directory under dist/release')
    os.environ['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    mpv = pathlib.Path(args.mpv).resolve()
    ffmpeg_input = pathlib.Path(args.ffmpeg).resolve()
    if not mpv.exists(): raise RuntimeError('Pinned mpv is missing; run python3 scripts/build_mpv.py')
    mpv_manifest = mpv.parent / 'MpvBuild.json'
    if not mpv_manifest.exists(): raise RuntimeError('Pinned MpvBuild.json is required')
    metadata = json.loads(mpv_manifest.read_text())
    from build_mpv import PATCHES, ARCHIVE_SHA
    if metadata.get('sourceSHA256') != ARCHIVE_SHA or metadata.get('patches') != PATCHES:
        raise RuntimeError('Unexpected mpv archive/patch metadata')
    if any(sha256(ROOT / 'patches' / name) != digest for name, digest in PATCHES.items()):
        raise RuntimeError('Pinned patch input SHA mismatch')
    if metadata.get('librarySHA256') != sha256(mpv): raise RuntimeError('mpv library input SHA mismatch')
    actual = input_closure(mpv, ffmpeg_input)
    lock_path = ROOT / 'Dependencies.lock.json'
    lock = json.loads(lock_path.read_text())
    if args.update_lock:
        previous = {item['source']: item for item in lock['libraries']}
        lock['libraries'] = [dict(previous.get(item['source'], {}), **item)
            for path, item in sorted(actual.items(), key=lambda pair: pair[1]['library']) if path != ffmpeg_input]
        lock['mpvPatchedBuild'] = metadata
        lock['ffmpegExecutable'] = {'source': portable(ffmpeg_input), 'sha256': sha256(ffmpeg_input)}
        lock_path.write_text(json.dumps(lock, indent=2) + '\n')
    verify_lock(lock, actual, metadata, ffmpeg_input)
    if args.verify_inputs:
        print(json.dumps({'libraries': len(lock['libraries']), 'ffmpegInputVerified': True, 'mpvBuildVerified': True}))
        return
    config = 'debug' if args.debug else 'release'
    build = ['swift', 'build', '--scratch-path', str(args.scratch_path.resolve()), '-c', config, '--arch', 'arm64']
    run(*build)
    bin_dir = pathlib.Path(run(*build, '--show-bin-path', capture=True))
    mac = app / 'Contents' / 'MacOS'
    frameworks = app / 'Contents' / 'Frameworks'
    resources = app / 'Contents' / 'Resources'
    for folder in [mac, frameworks, resources]: folder.mkdir(parents=True, exist_ok=True)
    executable = mac / 'Manping'
    shutil.copy2(bin_dir / 'Manping', executable)
    ffmpeg = mac / 'ffmpeg'
    shutil.copy2(args.ffmpeg, ffmpeg)
    copy_resource_bundles(bin_dir, resources)
    ca = pathlib.Path('/opt/homebrew/etc/ca-certificates/cert.pem')
    if not ca.exists(): raise RuntimeError('CA certificate bundle is missing')
    shutil.copy2(ca, resources / 'cacert.pem')
    # Layered icon: actool compiles the Icon Composer document into Assets.car plus a flat AppIcon.icns fallback.
    # A failing actool aborts the bundle (check=True); there is no silent fallback to the prebuilt .icns.
    icon_build = pathlib.Path(tempfile.mkdtemp(prefix='manping-icon-'))
    run('xcrun', 'actool', str(ROOT / 'Resources/AppIcon/AppIcon.icon'), '--compile', str(icon_build), '--platform', 'macosx',
        '--minimum-deployment-target', '27.0', '--app-icon', 'AppIcon', '--output-partial-info-plist', str(icon_build / 'partial.plist'))
    for produced in ('Assets.car', 'AppIcon.icns'):
        if not (icon_build / produced).is_file(): raise RuntimeError('actool did not produce ' + produced)
        shutil.copy2(icon_build / produced, resources / produced)
    shutil.rmtree(icon_build)
    plist = {'CFBundleName':'满屏', 'CFBundleDisplayName':'满屏', 'CFBundleExecutable':'Manping', 'CFBundleIdentifier':'io.github.pidean.manping', 'CFBundleVersion':'5', 'CFBundleShortVersionString':'0.1.4', 'CFBundlePackageType':'APPL', 'LSMinimumSystemVersion':'27.0', 'NSHighResolutionCapable':True, 'CFBundleIconFile':'AppIcon', 'CFBundleIconName':'AppIcon', 'NSAppTransportSecurity':{'NSAllowsArbitraryLoads':False}, 'CFBundleURLTypes':[{'CFBundleURLName':'io.github.pidean.manping.link', 'CFBundleURLSchemes':['manping'], 'CFBundleTypeRole':'Viewer'}]}
    with (app / 'Contents' / 'Info.plist').open('wb') as handle: plistlib.dump(plist, handle)
    copied = {}
    origins = {}
    def collect(original, name=None):
        original=pathlib.Path(original).resolve()
        name=name or original.name
        if original in copied: return copied[original]
        target=frameworks/name
        if target.name in origins and origins[target.name]!=portable(canonical(original)): raise RuntimeError(f'Dylib name collision: {name}')
        origins[target.name]=portable(canonical(original))
        shutil.copy2(original,target)
        copied[original]=target
        rewrite(original,target)
        return target
    def rewrite(original,target):
        architecture=run('lipo','-archs',str(target),capture=True).split()
        if 'arm64' not in architecture: raise RuntimeError(f'Non-arm64 binary: {original}')
        if len(architecture)>1:
            temporary=target.with_suffix(target.suffix+'.thin')
            run('lipo',str(target),'-thin','arm64','-output',str(temporary));temporary.replace(target)
        os.chmod(target,0o755)
        # Debug symbol tables (STABS) carry build-machine paths; drop them (code is unchanged).
        run('strip','-S',str(target))
        dependencies=links(original)
        for dep in dependencies:
            if system(dep): continue
            # The first otool entry for dylibs is its own install name.
            resolved=resolve(dep, original, ffmpeg_input)
            if resolved==original: continue
            child=collect(resolved)
            run('install_name_tool','-change',dep,'@rpath/'+child.name,str(target))
        if target.parent==frameworks:
            run('install_name_tool','-id','@rpath/'+target.name,str(target))
            run('install_name_tool','-add_rpath','@loader_path',str(target))
        else: run('install_name_tool','-add_rpath','@executable_path/../Frameworks',str(target))
        # Strip every absolute build-time RPATH, including paths not present in LC_LOAD_DYLIB.
        lines=run('otool','-l',str(target),capture=True).splitlines()
        for index,line in enumerate(lines):
            if line.strip()=='cmd LC_RPATH':
                raw=lines[index+2].strip().split('path ')[1].split(' (offset')[0]
                if raw.startswith('/opt/homebrew') or raw.startswith(str(ROOT)): run('install_name_tool','-delete_rpath',raw,str(target))
    collect(mpv,'libmpv.2.dylib')
    if mpv_manifest.exists(): shutil.copy2(mpv_manifest, resources / 'MpvBuild.json')
    rewrite(pathlib.Path(args.ffmpeg).resolve(),ffmpeg)
    rewrite(bin_dir/'Manping',executable)
    if {str(path) for path in copied} != {str(path) for path in actual if path != ffmpeg_input}:
        raise RuntimeError('Built executable changed the verified dependency closure')
    SIGN = signing_args()
    manifest = []
    inputs = {target: source for source, target in copied.items()}
    inputs[ffmpeg] = ffmpeg_input
    inputs[executable] = bin_dir / 'Manping'
    for binary in [*frameworks.glob("*.dylib"),ffmpeg,executable]:
        for dep in links(binary):
            if not system(dep) and not dep.startswith('@rpath/'): raise RuntimeError(f'External runtime dependency remains: {dep}')
        run('codesign','--force',*SIGN,str(binary))
        manifest.append({'bundledPath': str(binary.relative_to(app)),
            'arch': run('lipo', '-archs', str(binary), capture=True).split(),
            'dependencies': links(binary), 'inputSHA256': sha256(inputs[binary]),
            'signedSHA256': sha256(binary)})
    shutil.copytree(ROOT/'ThirdPartyNotices',resources/'ThirdPartyNotices',dirs_exist_ok=True)
    shutil.copy2(ROOT/'LICENSE',resources/'LICENSE')
    if (ROOT/'Dependencies.lock.json').exists(): shutil.copy2(ROOT/'Dependencies.lock.json',resources/'Dependencies.lock.json')
    (resources/'DependencyOrigins.json').write_text(json.dumps(origins,indent=2)+'\n')
    for item in manifest:
        item['signaturePhase'] = 'nested-signed' if item['bundledPath'] != 'Contents/MacOS/Manping' else 'before-app-resource-seal'
    (resources / 'BundleManifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    run('codesign','--force',*SIGN,str(app))
    for item in manifest:
        final_sha = sha256(app / item['bundledPath'])
        if item['signaturePhase'] == 'nested-signed' and final_sha != item['signedSHA256']:
            raise RuntimeError('App signing unexpectedly changed a nested binary SHA')
        item['signedSHA256'] = final_sha
        item['signaturePhase'] = 'final-app-signed'
    # The main executable's signature seals Resources, so its final hash must live outside
    # that seal. This authoritative manifest records all final binary hashes without a cycle.
    (app.parent / 'BundleManifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    run('codesign','--verify','--deep','--strict',str(app))
    if publish:
        backup = ROOT / '.build' / 'release-backups' / uuid.uuid4().hex
        backup.parent.mkdir(parents=True, exist_ok=True)
        previous = publish.parent.exists()
        if previous: publish.parent.rename(backup)
        try:
            publish.parent.parent.mkdir(parents=True, exist_ok=True)
            app.parent.rename(publish.parent)
        except BaseException:
            if previous: backup.rename(publish.parent)
            raise
        if previous: shutil.rmtree(backup)
        app = publish
        print('Previous Release replaced' if previous else 'New Release published')
    print(app)

if __name__ == '__main__': main()
