"""Production VideoSurface/CGL vs original gpu-next; identical pixels, no resizing or ROI crop."""
import argparse
import hashlib
import json
import math
import os
import pathlib
import socket
import subprocess
import time

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / '.build/full-pipeline'
SHADERS = ROOT / 'Sources/ManpingApp/Resources/Shaders'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def property_parity(native, reference):
    results = {}
    for name, value in native.items():
        other = reference.get(name)
        if value.startswith('unavailable') or (isinstance(other, str) and other.startswith('unavailable')):
            results[name] = False
        elif isinstance(other, bool):
            results[name] = value == ('yes' if other else 'no')
        elif isinstance(other, (int, float)):
            try: results[name] = math.isclose(float(value), float(other), rel_tol=1e-6, abs_tol=1e-6)
            except ValueError: results[name] = False
        elif isinstance(other, dict):
            results[name] = json.loads(value) == other
        else: results[name] = value == other
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=pathlib.Path, default=ROOT / 'dist/integration/Manping.app')
    parser.add_argument('--build-mode', choices=['debug', 'release'], required=True)
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    image, video = OUT / 'static.png', OUT / 'static.mp4'
    ffmpeg = str(args.app / 'Contents/MacOS/ffmpeg')
    subprocess.run([ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=s=640x360:r=30',
                    '-frames:v', '1', str(image)], check=True)
    subprocess.run([ffmpeg, '-v', 'error', '-y', '-loop', '1', '-i', str(image), '-t', '24',
                    '-r', '30', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-qp', '0', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', str(video)], check=True)
    results = []
    report = {'method': 'Production VideoSurface/VideoLayer CGL RGBA16Float vs original gpu-next/macvk, same static H264 frame and software decoder; BT709/sRGB/203, bt.2390, bilinear scale/cscale/dscale, no dither. No resampling/cropping.',
              'buildMode': args.build_mode, 'executableSHA256': digest(args.app / 'Contents/MacOS/Manping'), 'fixtureSHA256': digest(video), 'requestedPixelSize': [1280, 720],
              'allEightPipelinesSampled': False, 'pixelEquivalent': False, 'gateDecision': 'Pending main agent review', 'results': results}
    for shader in [None, *sorted((SHADERS / 'ArtCNN').glob('*.glsl'))]:
        name = shader.stem if shader else "None"
        shader_name = shader.name if shader else "None"
        capture, native_report = OUT / (name + '.pfm'), OUT / (name + '.json')
        capture.unlink(missing_ok=True)
        env = dict(os.environ, MANPING_CAPTURE_PATH=str(capture), PATH='/usr/bin:/bin:/usr/sbin:/sbin')
        native_command = [str(args.app / 'Contents/MacOS/Manping'), '--diagnose', str(video),
                          '--fixed-viewport', '--sdr', '--hwdec-mode', 'no', '--seconds',
                          ('16' if name.startswith('ArtCNN_C4F32') else '5'), '--report', str(native_report)]
        if shader: native_command += ['--shader', str(SHADERS / 'ArtCNNCompat' / shader_name)]
        with (OUT / (name + '-cgl.log')).open('w') as log:
            native = subprocess.run(native_command, env=env, stdout=log, stderr=log, timeout=45)
        data = json.loads(native_report.read_text())
        with capture.open('rb') as stream:
            assert stream.readline().strip() == b'PF'
            width, height = map(int, stream.readline().split())
            assert stream.readline().strip() == b'-1.0'
            cgl = np.frombuffer(stream.read(), dtype='<f4').reshape(height, width, 3)[::-1].astype(np.float64)
        png, ipc = OUT / (name + '-reference.png'), OUT / 'ipc.sock'
        ipc.unlink(missing_ok=True)
        properties = {}
        with (OUT / (name + '-reference.log')).open('w') as log:
            reference = subprocess.Popen(['/opt/homebrew/bin/mpv', '--no-config', '--vo=gpu-next',
                '--gpu-api=vulkan', '--gpu-context=macvk', '--hwdec=no', '--pause', '--keep-open=yes',
                '--geometry=1280x720', '--hidpi-window-scale=no', '--no-terminal', '--target-colorspace-hint=no',
                '--target-prim=bt.709', '--target-trc=srgb', '--target-peak=203', '--tone-mapping=bt.2390',
                '--scale=bilinear', '--cscale=bilinear', '--dscale=bilinear', '--dither-depth=no',
                '--screenshot-format=png', '--screenshot-high-bit-depth=yes', '--glsl-shaders=' + (str(shader) if shader else ''),
                '--input-ipc-server=' + str(ipc), str(video)], stdout=log, stderr=log)
            try:
                for _ in range(200):
                    if ipc.exists(): break
                    if reference.poll() is not None: raise RuntimeError('reference exited')
                    time.sleep(.05)
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.connect(str(ipc))
                    connection.settimeout(30)
                    time.sleep(1.5)
                    connection.sendall(json.dumps({'command': ['screenshot-to-file', str(png), 'window'], 'request_id': 42}).encode() + b'\n')
                    response = b''
                    while True:
                        response += connection.recv(65536)
                        messages = [json.loads(line) for line in response.splitlines() if line.endswith(b'}')]
                        matches = [entry for entry in messages if entry.get('request_id') == 42]
                        if matches:
                            assert matches[0]['error'] == 'success'
                            break
                    for index, property_name in enumerate(data['actualProperties'], 100):
                        connection.sendall(json.dumps({'command': ['get_property', property_name], 'request_id': index}).encode() + b'\n')
                        response = b''
                        while True:
                            response += connection.recv(65536)
                            messages = [json.loads(line) for line in response.splitlines() if line.endswith(b'}')]
                            matches = [entry for entry in messages if entry.get('request_id') == index]
                            if matches:
                                properties[property_name] = matches[0].get('data', 'unavailable: ' + matches[0].get('error', 'unknown'))
                                break
                    connection.sendall(b'{"command":["quit"]}\n')
                    reference.wait(timeout=15)
            finally:
                if reference.poll() is None: reference.terminate(); reference.wait(timeout=15)
        # PNG IHDR gives the unmodified pixel size; refuse mismatch before decoding/comparing.
        png_bytes = png.read_bytes()
        reference_size = [int.from_bytes(png_bytes[16:20], 'big'), int.from_bytes(png_bytes[20:24], 'big')]
        assert [width, height] == reference_size == [1280, 720], ([width, height], reference_size)
        assert data['viewportPixels'] == [1280, 720], data['viewportPixels']
        raw = subprocess.check_output([ffmpeg, '-v', 'error', '-i', str(png), '-f', 'rawvideo', '-pix_fmt', 'rgb48le', '-'])
        original = np.frombuffer(raw, dtype='<u2').reshape(height, width, 3).astype(np.float64) / 65535
        delta = np.abs(cgl - original)
        mse = float(np.mean(delta ** 2))
        result = {'file': shader_name, 'nativeExit': native.returncode, 'nativeSize': [width, height],
                  'referenceSize': reference_size, 'validRectangle': [0, 0, width, height],
                  'decoder': 'software on both', 'nativeProperties': data['actualProperties'], 'referenceProperties': properties, 'render': data['render'], 'error': data['error'],
                  'mae': float(np.mean(delta)), 'max': float(np.max(delta)),
                  'psnr': -10 * math.log10(mse) if mse else None,
                  'nativeSHA256': digest(capture), 'referenceSHA256': digest(png)}
        result['actualPropertyParity'] = property_parity(data['actualProperties'], properties)
        native_rect = json.loads(data['actualProperties']['osd-dimensions'])
        assert all(native_rect[key] == 0 for key in ['ml', 'mr', 'mt', 'mb'])
        assert all(properties['osd-dimensions'][key] == 0 for key in ['ml', 'mr', 'mt', 'mb'])
        results.append(result)
        print(json.dumps(result), flush=True)
        (ROOT / 'docs/evidence/artcnn-golden-full-pipeline-fixed.json').write_text(json.dumps(report, indent=2) + '\n')
    report['allEightPipelinesSampled'] = len(results) == 9 and all(r['nativeExit'] == 0 and not r['error'] for r in results)
    (ROOT / 'docs/evidence/artcnn-golden-full-pipeline-fixed.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
