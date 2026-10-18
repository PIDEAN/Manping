"""Local-only release VideoSurface probes with unmodified RGBA16F captures."""
import json
import os
from pathlib import Path
import re
import subprocess

import numpy as np
from verify_full_pipeline import ROOT, digest
from verify_renderer_linear import pfm

APP = ROOT / 'dist/renderer/Manping.app'
OUT = ROOT / '.build/renderer-production'
RESULTS = []


def run(name, video, options=(), seconds=5, capture=False, positions=(.125, .375, .625, .875)):
    report, log, pixels = [OUT / (name + suffix) for suffix in ('.json', '.log', '.pfm')]
    command = [str(APP / 'Contents/MacOS/Manping'), '--diagnose', str(video),
               '--verbose', '--seconds', str(seconds), '--report', str(report), *options]
    env = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin')
    env.pop('MANPING_CAPTURE_PATH', None)
    env.pop('MANPING_MPV_LIBRARY', None)
    if capture:
        pixels.unlink(missing_ok=True)
        env['MANPING_CAPTURE_PATH'] = str(pixels)
    with log.open('w') as stream:
        completed = subprocess.run(command, env=env, stdout=stream, stderr=stream, timeout=60)
    data = json.loads(report.read_text())
    assert completed.returncode == 0 and not data['error'], (name, data)
    assert 'linkFailures=0' in data['render'] and 'redBits=16' in data['render'], data['render']
    counts = dict(re.findall(r'(frames|backgroundFrames)=(\d+)', data['render']))
    # Core Animation may draw once on the initializing thread; sustained progress
    # off the main thread is checked independently by the main-stall probe.
    assert int(counts['backgroundFrames']) > 0
    result = {'case': name, 'command': command, 'inputSHA256': digest(video),
              'reportSHA256': digest(report), 'logSHA256': digest(log), 'report': data}
    if capture:
        result['captureSHA256'] = digest(pixels)
        frame = pfm(pixels)
        assert np.all(np.isfinite(frame))
        result['captureSize'] = list(frame.shape[:2][::-1])
        dims = json.loads(data['actualProperties']['osd-dimensions'])
        width = dims['w'] - dims['ml'] - dims['mr']
        height = dims['h'] - dims['mt'] - dims['mb']
        xs = [int(dims['ml'] + width * p) for p in positions]
        result['neutralBars'] = frame[int(dims['mt'] + height / 2), xs].tolist()
    RESULTS.append(result)
    (ROOT / 'docs/evidence/renderer-production.json').write_text(json.dumps({
        'complete': False, 'executableSHA256': digest(APP / 'Contents/MacOS/Manping'),
        'results': RESULTS}, indent=2) + '\n')
    print(name, data['render'], flush=True)
    return result


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    bars = ROOT / '.build/renderer-linear/sdr-bars.mkv'
    for preset in ['None', 'C4F32Ani4KI2', 'C4F32AniSDI4']:
        for headroom in (1, 2):
            opts = ['--headroom-cap', str(headroom), '--hwdec-mode', 'no']
            if preset != 'None': opts += ['--preset', 'ArtCNN/' + preset]
            result = run(f'{preset}-linear-{headroom}', bars, opts, capture=True)
            props = result['report']['actualProperties']
            assert props['target-trc'] == 'linear' and props['target-prim'] == 'bt.2020'
            assert int(props['target-peak']) == 203 * headroom
            result['whiteMaxErrorFromOne'] = float(np.max(np.abs(np.array(result['neutralBars'])[-1] - 1)))
            result['whiteWithinOneFP16StepBelowOne'] = result['whiteMaxErrorFromOne'] <= 1/2048
            assert any('BT.1886 black map' in s for s in result['report']['shaderEvents'])
    hdr = Path('/tmp/manping-hdr-bars.mp4')
    for label, opts in [('headroom2', ['--headroom-cap', '2']), ('headroom16', ['--headroom-cap', '16']), ('sdr', ['--sdr'])]:
        result = run('hdr-' + label, hdr, opts, capture=True, positions=(1/6, .5, 5/6))
        assert result['report']['hwdec'] == 'videotoolbox'
        assert not any('BT.1886 black map' in s for s in result['report']['shaderEvents'])
    video = Path('/tmp/manping-small-test.mp4')
    result = run('paused', video, ['--pause-probe'], seconds=6)
    paused = result['report']['probes']['pausedAt3']
    frames = lambda text: int(re.search(r'(?<!\w)frames=(\d+)', text)[1])
    assert frames(result['report']['render']) == frames(paused)
    result = run('active-main-stall', video, ['--stall-main'], seconds=7)
    probes = result['report']['probes']
    assert frames(probes['afterMainStall']) > frames(probes['beforeMainStall'])
    result = run('split-aac-seek-reload-destroy', video,
                 ['--audio', '/tmp/manping-audio,part:one.m4a', '--stress', '--preset', 'ArtCNN/C4F16'], seconds=12)
    assert result['report']['media']['audio-codec-name'] == 'aac'
    assert result['report']['time'] >= 8
    evidence = {'complete': True, 'method': 'Actual release VideoSurface, native window, system-only PATH, local fixtures, no corrected captures.',
                'executableSHA256': digest(APP / 'Contents/MacOS/Manping'),
                'mpvSHA256': digest(APP / 'Contents/Frameworks/libmpv.2.dylib'), 'results': RESULTS}
    (ROOT / 'docs/evidence/renderer-production.json').write_text(json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()
