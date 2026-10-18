"""One None-only sigmoid experiment; retain the existing fixture and all native pixels."""
import argparse
import json
import math
import os
from pathlib import Path
import socket
import subprocess
import time

import numpy as np

from verify_full_pipeline import ROOT, digest, property_parity

OUT = ROOT / '.build/sigmoid-controls'
VIDEO = ROOT / '.build/full-pipeline/static.mp4'
EVIDENCE = ROOT / 'docs/evidence/artcnn-none-sigmoid-controls.json'


def metrics(left, right):
    delta = np.abs(left - right)
    mse = float(np.mean(delta ** 2))
    location = np.unravel_index(np.argmax(delta), delta.shape)
    return {'identical': bool(np.array_equal(left, right)),
            'changedPixels': int(np.count_nonzero(np.any(delta != 0, axis=2))),
            'mae': float(np.mean(delta)), 'mse': mse, 'max': float(np.max(delta)),
            'psnr': -10 * math.log10(mse) if mse else None,
            'maxLocationXYChannel': [int(location[1]), int(location[0]), int(location[2])]}


def geometry(properties):
    dimensions = properties['osd-dimensions']
    if isinstance(dimensions, str):
        dimensions = json.loads(dimensions)
    assert [dimensions['w'], dimensions['h']] == [1280, 720], dimensions
    assert all(dimensions[key] == 0 for key in ['ml', 'mr', 'mt', 'mb']), dimensions
    return dimensions


def profile(properties):
    expected = {'hwdec-current': 'no', 'video-params/w': 640, 'video-params/h': 360,
                'video-params/colormatrix': 'bt.709', 'video-params/colorlevels': 'limited',
                'video-params/primaries': 'bt.709', 'video-params/gamma': 'bt.1886',
                'target-prim': 'bt.709', 'target-trc': 'srgb', 'target-peak': 203,
                'tone-mapping': 'bt.2390', 'scale': 'bilinear', 'cscale': 'bilinear',
                'dscale': 'bilinear', 'dither-depth': 'no'}
    for key, value in expected.items():
        actual = properties[key]
        if isinstance(actual, bool):
            actual = 'yes' if actual else 'no'
        assert (float(actual) == value if isinstance(value, int) else actual == value), (key, actual, value)


def native_capture(app, control):
    name = 'cgl-' + ('no-sigmoid' if control else 'baseline')
    capture, report_path = OUT / (name + '.pfm'), OUT / (name + '.json')
    capture.unlink(missing_ok=True)
    report_path.unlink(missing_ok=True)
    env = dict(os.environ, MANPING_CAPTURE_PATH=str(capture), PATH='/usr/bin:/bin:/usr/sbin:/sbin')
    env.pop('MANPING_MPV_LIBRARY', None)
    command = [str(app / 'Contents/MacOS/Manping'), '--diagnose', str(VIDEO),
               '--fixed-viewport', '--sdr', '--hwdec-mode', 'no', '--seconds', '5',
               '--report', str(report_path)]
    if control:
        command += ['--sigmoid-upscaling', 'no']
    with (OUT / (name + '.log')).open('w') as log:
        process = subprocess.run(command, env=env, stdout=log, stderr=log, timeout=45)
    assert process.returncode == 0, process.returncode
    data = json.loads(report_path.read_text())
    assert not data['error'], data['error']
    assert data['viewportPixels'] == [1280, 720], data['viewportPixels']
    assert 'size=1280x720' in data['render'] and 'componentType=0x1406 redBits=16' in data['render'], data['render']
    assert 'linkFailures=0' in data['render'] and not data['shaderRequested'], data
    properties = data['actualProperties']
    geometry(properties)
    profile(properties)
    assert properties['linear-upscaling'] == 'no', properties
    assert properties['sigmoid-upscaling'] == ('no' if control else 'yes'), properties
    with capture.open('rb') as stream:
        assert stream.readline().strip() == b'PF'
        width, height = map(int, stream.readline().split())
        assert [width, height] == [1280, 720]
        assert stream.readline().strip() == b'-1.0'
        pixels = np.frombuffer(stream.read(), dtype='<f4').reshape(height, width, 3)[::-1].astype(np.float64)
    assert np.all(np.isfinite(pixels))
    return pixels, {'command': command, 'exit': process.returncode, 'captureSHA256': digest(capture),
                    'reportSHA256': digest(report_path), 'logSHA256': digest(OUT / (name + '.log')),
                    'actualProperties': properties, 'geometry': geometry(properties),
                    'render': data['render'], 'passes': data['passes'], 'events': data['events'],
                    'pixelRangeUnclamped': [float(np.min(pixels)), float(np.max(pixels))]}


def reference_capture(mpv, ffmpeg, control, property_names):
    name = 'gpu-next-' + ('no-sigmoid' if control else 'baseline')
    png, ipc = OUT / (name + '.png'), OUT / 'sigmoid.sock'
    png.unlink(missing_ok=True)
    ipc.unlink(missing_ok=True)
    command = [str(mpv), '--no-config', '--vo=gpu-next', '--gpu-api=vulkan', '--gpu-context=macvk',
               '--hwdec=no', '--pause', '--keep-open=yes', '--geometry=1280x720',
               '--hidpi-window-scale=no', '--no-terminal', '--target-colorspace-hint=no',
               '--target-prim=bt.709', '--target-trc=srgb', '--target-peak=203',
               '--tone-mapping=bt.2390', '--scale=bilinear', '--cscale=bilinear', '--dscale=bilinear',
               '--dither-depth=no', '--screenshot-format=png', '--screenshot-high-bit-depth=yes',
               '--glsl-shaders=', '--input-ipc-server=' + str(ipc)]
    if control:
        command += ['--sigmoid-upscaling=no']
    command.append(str(VIDEO))
    properties = {}
    with (OUT / (name + '.log')).open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=log)
        try:
            for _ in range(200):
                if ipc.exists():
                    break
                if process.poll() is not None:
                    raise RuntimeError('Reference exited before IPC')
                time.sleep(.05)
            with socket.socket(socket.AF_UNIX) as connection:
                connection.connect(str(ipc))
                connection.settimeout(30)
                pending = b''

                def request(command, request_id):
                    nonlocal pending
                    connection.sendall(json.dumps({'command': command, 'request_id': request_id}).encode() + b'\n')
                    while True:
                        while b'\n' in pending:
                            line, pending = pending.split(b'\n', 1)
                            response = json.loads(line)
                            if response.get('request_id') == request_id:
                                return response
                        chunk = connection.recv(65536)
                        if not chunk:
                            raise RuntimeError('Reference IPC disconnected')
                        pending += chunk

                time.sleep(1.5)
                for index, key in enumerate(property_names, 10):
                    response = request(['get_property', key], index)
                    properties[key] = response.get('data', 'unavailable: ' + response.get('error', 'unknown'))
                geometry(properties)
                profile(properties)
                assert properties['linear-upscaling'] is False, properties
                assert properties['sigmoid-upscaling'] is (not control), properties
                assert request(['screenshot-to-file', str(png), 'window'], 1)['error'] == 'success'
                connection.sendall(b'{"command":["quit"]}\n')
                process.wait(timeout=15)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)
    assert process.returncode == 0, process.returncode
    raw_png = png.read_bytes()
    assert [int.from_bytes(raw_png[16:20], 'big'), int.from_bytes(raw_png[20:24], 'big')] == [1280, 720]
    assert raw_png[24] == 16, 'Reference PNG must retain 16-bit samples'
    raw = subprocess.check_output([str(ffmpeg), '-v', 'error', '-i', str(png),
                                   '-f', 'rawvideo', '-pix_fmt', 'rgb48le', '-'])
    pixels = np.frombuffer(raw, dtype='<u2').reshape(720, 1280, 3).astype(np.float64) / 65535
    evidence = {'command': command, 'exit': process.returncode, 'captureSHA256': digest(png),
                'actualProperties': properties, 'geometry': geometry(properties),
                'logSHA256': digest(OUT / (name + '.log')), 'pngBitDepth': raw_png[24]}
    (OUT / (name + '.json')).write_text(json.dumps(evidence, indent=2) + '\n')
    return pixels, evidence


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/diagnostics/Manping.app')
    parser.add_argument('--mpv', type=Path, default=Path('/opt/homebrew/bin/mpv'))
    args = parser.parse_args()
    app, mpv = args.app.resolve(), args.mpv.resolve()
    OUT.mkdir(parents=True, exist_ok=True)
    fixture_hash = digest(VIDEO)
    expected = json.loads((ROOT / 'docs/evidence/artcnn-golden-full-pipeline-fixed.json').read_text())['fixtureSHA256']
    assert fixture_hash == expected, (fixture_hash, expected)
    ffmpeg = app / 'Contents/MacOS/ffmpeg'
    frame_md5 = subprocess.check_output([str(ffmpeg), '-v', 'error', '-i', str(VIDEO), '-f', 'framemd5', '-'], text=True)
    (OUT / 'source.framemd5').write_text(frame_md5)
    frames = [line.split(',')[-1].strip() for line in frame_md5.splitlines() if line and not line.startswith('#')]
    assert len(frames) == 720 and len(set(frames)) == 1, (len(frames), len(set(frames)))
    cgl_base, cgl_base_data = native_capture(app, False)
    ref_base, ref_base_data = reference_capture(mpv, ffmpeg, False, cgl_base_data['actualProperties'])
    # Both baseline getters have confirmed linear-upscaling=no before either control runs.
    cgl_no, cgl_no_data = native_capture(app, True)
    ref_no, ref_no_data = reference_capture(mpv, ffmpeg, True, cgl_base_data['actualProperties'])
    cgl_diff, ref_diff = metrics(cgl_base, cgl_no), metrics(ref_base, ref_no)
    unchanged = [key for key in cgl_base_data['actualProperties'] if key not in ['sigmoid-upscaling', 'vo-passes']]
    for before, after in [(cgl_base_data, cgl_no_data), (ref_base_data, ref_no_data)]:
        assert all(before['actualProperties'][key] == after['actualProperties'][key] for key in unchanged)
    supported = not cgl_diff['identical'] and ref_diff['identical']
    report = {'experiment': 'None-only sigmoid-upscaling=no; baseline options otherwise unchanged',
              'method': 'CGL float32 PFM of RGBA16Float FBO vs gpu-next/macvk 16-bit PNG; full 1280x720, zero margins, no clamp/crop/resample',
              'buildMode': 'release', 'shader': 'None', 'fixtureSHA256': fixture_hash,
              'sourceFramemd5SHA256': digest(OUT / 'source.framemd5'),
              'sourceFrames': len(frames), 'sourceUniqueFrameMD5': sorted(set(frames)),
              'executableSHA256': digest(app / 'Contents/MacOS/Manping'),
              'patchedMpvSHA256': digest(app / 'Contents/Frameworks/libmpv.2.dylib'),
              'referenceExecutableSHA256': digest(mpv),
              'productionSettingsChanged': False, 'shaderWeightsChanged': False,
              'pixelEquivalent': False, 'fullGatePassed': False,
              'baselineGettersConfirmedBeforeControls': True,
              'unchangedPropertiesWithinEachRenderer': unchanged,
              'captures': {'cglBaseline': cgl_base_data, 'referenceBaseline': ref_base_data,
                           'cglNoSigmoid': cgl_no_data, 'referenceNoSigmoid': ref_no_data},
              'selfDifference': {'cgl': cgl_diff, 'gpuNext': ref_diff},
              'crossDifference': {'baseline': metrics(cgl_base, ref_base), 'noSigmoid': metrics(cgl_no, ref_no)},
              'actualPropertyParity': {'baseline': property_parity(cgl_base_data['actualProperties'], ref_base_data['actualProperties']),
                                       'noSigmoid': property_parity(cgl_no_data['actualProperties'], ref_no_data['actualProperties'])},
              'hypothesisSupportedForThisFixture': supported,
              'gateDecision': 'Pending main agent review; no production change or expanded matrix',
              'limitation': 'Renderer paths, sample precision, and transfer mapping remain distinct. Public vo-passes may be unavailable; this experiment cannot establish general or eight-shader equivalence.'}
    assert digest(VIDEO) == fixture_hash, 'Fixture changed during experiment'
    EVIDENCE.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ['selfDifference', 'crossDifference', 'hypothesisSupportedForThisFixture']}, indent=2))
    if not ref_diff['identical']:
        raise RuntimeError('Reference changed: stop hypothesis; inspect need_fbo/hook trace before further work')
    if cgl_diff['identical']:
        raise RuntimeError('CGL unchanged: hypothesis unsupported; no parameter retry')


if __name__ == '__main__':
    main()
