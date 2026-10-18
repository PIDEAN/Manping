"""Two bounded None-only reference controls; production CGL settings are unchanged."""
import json
import math
import socket
import subprocess
import time

import numpy as np

from verify_full_pipeline import ROOT, OUT, digest


def main():
    baseline = json.loads((ROOT / 'docs/evidence/artcnn-golden-full-pipeline-fixed.json').read_text())
    default = next(result for result in baseline['results'] if result['file'] == 'None')
    with (OUT / 'None.pfm').open('rb') as stream:
        assert stream.readline().strip() == b'PF'
        width, height = map(int, stream.readline().split())
        assert stream.readline().strip() == b'-1.0'
        native = np.frombuffer(stream.read(), dtype='<f4').reshape(height, width, 3)[::-1].astype(np.float64)
    controls = [('piecewise-srgb', ['--treat-srgb-as-power22=no']),
                ('piecewise-srgb-infinite-contrast', ['--treat-srgb-as-power22=no', '--target-contrast=inf'])]
    results = []
    for name, options in controls:
        png, ipc = OUT / (name + '.png'), OUT / 'color-control.sock'
        ipc.unlink(missing_ok=True)
        command = ['/opt/homebrew/bin/mpv', '--no-config', '--vo=gpu-next', '--gpu-api=vulkan',
            '--gpu-context=macvk', '--hwdec=no', '--pause', '--keep-open=yes', '--geometry=1280x720',
            '--hidpi-window-scale=no', '--no-terminal', '--target-colorspace-hint=no', '--target-prim=bt.709',
            '--target-trc=srgb', '--target-peak=203', '--tone-mapping=bt.2390', '--scale=bilinear',
            '--cscale=bilinear', '--dscale=bilinear', '--dither-depth=no', '--screenshot-format=png',
            '--screenshot-high-bit-depth=yes', '--input-ipc-server=' + str(ipc), *options, str(OUT / 'static.mp4')]
        with (OUT / (name + '.log')).open('w') as log:
            process = subprocess.Popen(command, stdout=log, stderr=log)
            try:
                for _ in range(200):
                    if ipc.exists(): break
                    if process.poll() is not None: raise RuntimeError('Reference exited')
                    time.sleep(.05)
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.connect(str(ipc)); connection.settimeout(30)
                    time.sleep(1.5)
                    def request(command, request_id):
                        connection.sendall(json.dumps({'command': command, 'request_id': request_id}).encode() + b'\n')
                        data = b''
                        while True:
                            data += connection.recv(65536)
                            matches = [json.loads(line) for line in data.splitlines() if line.endswith(b'}')]
                            matches = [entry for entry in matches if entry.get('request_id') == request_id]
                            if matches: return matches[0]
                    assert request(['screenshot-to-file', str(png), 'window'], 1)['error'] == 'success'
                    properties = {}
                    for index, key in enumerate(['treat-srgb-as-power22', 'target-contrast', 'target-trc', 'target-prim',
                        'target-peak', 'video-params/gamma', 'video-params/colorlevels', 'icc-profile', 'icc-profile-auto', 'osd-dimensions'], 10):
                        response = request(['get_property', key], index)
                        properties[key] = response.get('data', 'unavailable: ' + response.get('error', 'unknown'))
                    connection.sendall(b'{"command":["quit"]}\n'); process.wait(timeout=15)
            finally:
                if process.poll() is None: process.terminate(); process.wait(timeout=15)
        raw = png.read_bytes()
        size = [int.from_bytes(raw[16:20], 'big'), int.from_bytes(raw[20:24], 'big')]
        assert size == [width, height] == [1280, 720]
        raw = subprocess.check_output([str(ROOT / 'dist/integration/Manping.app/Contents/MacOS/ffmpeg'),
            '-v', 'error', '-i', str(png), '-f', 'rawvideo', '-pix_fmt', 'rgb48le', '-'])
        reference = np.frombuffer(raw, dtype='<u2').reshape(height, width, 3).astype(np.float64) / 65535
        delta = np.abs(native - reference)
        mse = float(np.mean(delta ** 2))
        results.append({'control': name, 'referenceOptions': options, 'actualReferenceProperties': properties,
            'size': size, 'mae': float(np.mean(delta)), 'max': float(np.max(delta)), 'psnr': -10 * math.log10(mse),
            'referenceSHA256': digest(png)})
    source = ROOT / '.build/mpv-clean-recipe-fixture/mpv-0.41.0/video/out/vo_gpu_next.c'
    report = {'buildMode': baseline['buildMode'], 'executableSHA256': baseline['executableSHA256'],
        'nativeSHA256': default['nativeSHA256'], 'defaultBaseline': {key: default[key] for key in ['mae', 'max', 'psnr']},
        'productionSettingsChanged': False, 'shaderWeightsChanged': False, 'results': results,
        'sourceEvidence': {'archiveSHA256': 'ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209',
            'path': 'video/out/vo_gpu_next.c', 'sha256': digest(source),
            'outputTransferMapping': 'PL_COLOR_TRC_SRGB -> PL_COLOR_TRC_GAMMA22 when treat_srgb_as_power22 & 2',
            'infiniteTargetContrast': 'apply_target_contrast maps -1 to min_luma=1e-7'}}
    (ROOT / 'docs/evidence/artcnn-none-color-controls.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
