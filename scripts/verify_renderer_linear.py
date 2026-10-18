"""Compare raw CGL neutral SDR bars with independent libplacebo CPU EOTF."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

import numpy as np
from verify_full_pipeline import ROOT, digest

OUT = ROOT / '.build/renderer-linear'
OUT.mkdir(parents=True, exist_ok=True)
VIDEO = OUT / 'sdr-bars.mkv'
FIXTURE = ROOT / '.build/renderer-work/renderer-fixture'
LIBRARY = ROOT / '.build/mpv-build/libmpv.2.dylib'
REFERENCE = ROOT / '.build/renderer-work/color-reference'


def pfm(path):
    with path.open('rb') as stream:
        assert stream.readline().strip() == b'PF'
        w, h = map(int, stream.readline().split())
        assert stream.readline().strip() == b'-1.0'
        return np.frombuffer(stream.read(), '<f4').reshape(h, w, 3)[::-1].astype(np.float64)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, default=ROOT / 'docs/evidence/renderer-linear-final.json')
    args = parser.parse_args()
    y = np.repeat(np.array([16, 64, 128, 235], dtype=np.uint8), 160)[None, :].repeat(360, axis=0)
    raw = y.tobytes() + bytes([128]) * (640 * 360 // 2)
    subprocess.run(['/opt/homebrew/bin/ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pixel_format', 'yuv420p',
                    '-video_size', '640x360', '-framerate', '1', '-i', '-', '-vf', 'setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709,loop=loop=-1:size=1:start=0,setpts=N/30/TB',
                    '-t', '12', '-r', '30', '-c:v', 'ffv1', '-level', '3', '-pix_fmt', 'yuv420p', '-color_primaries', 'bt709',
                    '-color_trc', 'bt709', '-colorspace', 'bt709', str(VIDEO)], input=raw, check=True)
    decoded = subprocess.check_output(['/opt/homebrew/bin/ffmpeg', '-v', 'error', '-i', str(VIDEO), '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-'])
    assert decoded == raw, 'Fixture codec must preserve every input code value'
    results = []
    for name, peak, contrast, source_min in [('auto-1', 203, 0, 0), ('auto-2', 406, 0, 0),
          ('auto-16', 3248, 0, 0), ('inf', 203, -1, 0), ('finite-2000', 203, 2000, 0),
          ('known-source', 203, 0, .1)]:
        capture, log = OUT / (name + '.pfm'), OUT / (name + '.log')
        options = ['target-trc=linear', 'target-prim=bt.2020', f'target-peak={peak}',
                   'target-contrast=' + ('auto' if not contrast else 'inf' if contrast < 0 else str(contrast))]
        if source_min:
            options += [f'vf=format:min-luma={source_min}:max-luma=203']
        command = [str(FIXTURE), str(LIBRARY), str(VIDEO), str(capture), '1280', '720', '3', *options]
        with log.open('w') as output:
            subprocess.run(command, env=dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin'),
                           stdout=output, stderr=output, check=True, timeout=30)
        pixels = pfm(capture)
        actual = pixels[360, [160, 480, 800, 1120], :]
        reference = json.loads(subprocess.check_output([str(REFERENCE), str(peak), str(contrast), str(source_min)]))
        expected = np.array(reference['linearBars'])[:, None]
        delta = np.abs(actual - expected)
        content = log.read_text()
        passes = sorted(set(re.findall(r"pass '([^']+)'", content)))
        assert any('metadata SDR BT.1886 to linear' in x for x in passes), passes
        assert 'linkFailures=0' in content and np.all(np.isfinite(pixels))
        # Quantized 16-bit FBO plus 8-bit YUV decode matrix arithmetic, not a golden gate.
        assert float(delta.max()) < .001, (name, actual.tolist(), reference)
        result = {'case': name, 'command': command, 'captureSHA256': digest(capture), 'logSHA256': digest(log),
                  'reference': reference, 'actualNeutralRGB': actual.tolist(), 'maxNeutralError': float(delta.max()),
                  'actualPasses': passes, 'properties': [x for x in content.splitlines() if x.startswith('PROPERTY')]}
        results.append(result)
        print(name, result['maxNeutralError'], flush=True)
    report = {'method': 'Actual CGL RGBA16F vs linked libplacebo CPU pl_color_space_infer_map/pl_color_linearize; neutral code values only; no corrected captures.',
              'librarySHA256': digest(LIBRARY), 'fixtureSHA256': digest(VIDEO), 'results': results,
              'limitation': 'This is a transfer/white-point unit test, not full-image GPU equivalence or physical display measurement.'}
    args.evidence.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
