"""Focused CGL pass, metadata, subtitle, geometry and HDR fallback regression probes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

import numpy as np
from verify_full_pipeline import ROOT, digest
from verify_renderer_linear import pfm

OUT = ROOT / '.build/renderer-regressions'
FIXTURE = ROOT / '.build/renderer-work/renderer-fixture'
LIBRARY = ROOT / '.build/mpv-build/libmpv.2.dylib'
OLD = ROOT / 'dist/integration/Manping.app/Contents/Frameworks/libmpv.2.dylib'
STATIC = ROOT / '.build/full-pipeline/static.mp4'
BARS = ROOT / '.build/renderer-linear/sdr-bars.mkv'
RESULTS = []
CACHED = {}


def capture(name, video=STATIC, width=1280, height=720, options=(), library=LIBRARY, seconds=3):
    path, log = OUT / (name + '.pfm'), OUT / (name + '.log')
    if name in CACHED:
        result = CACHED[name]
        assert digest(path) == result['captureSHA256'] and digest(video) == result['inputSHA256']
        assert digest(log) == result['logSHA256']
        RESULTS.append(result)
        return pfm(path), result
    command = [str(FIXTURE), str(library), str(video), str(path), str(width), str(height), str(seconds), *options]
    with log.open('w') as output:
        subprocess.run(command, stdout=output, stderr=output,
                       env=dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin'), check=True, timeout=45)
    content = log.read_text()
    pixels = pfm(path)
    assert pixels.shape == (height, width, 3) and np.all(np.isfinite(pixels))
    stats = re.search(r'^RENDER (.+)$', content, re.M).group(1)
    assert 'linkFailures=0' in stats and 'componentType=0x1406 redBits=16' in stats, stats
    passes = sorted(set(re.findall(r"pass '([^']+)'", content)))
    properties = dict(x[len('PROPERTY '):].split('=', 1) for x in content.splitlines() if x.startswith('PROPERTY '))
    result = {'case': name, 'command': command, 'librarySHA256': digest(library), 'inputSHA256': digest(video),
              'captureSHA256': digest(path), 'logSHA256': digest(log), 'passes': passes, 'properties': properties,
              'render': stats, 'min': float(pixels.min()), 'max': float(pixels.max()),
              'policyMessages': sorted(set(x.split('shader compatibility:', 1)[1].strip()
                                          for x in content.splitlines() if 'shader compatibility:' in x)),
              'shaderLinks': int(re.search(r'shaderLinks=(\d+)', stats)[1]),
              'shaderSourceSHA256': sorted({hashlib.sha256(block.encode()).hexdigest()
                  for block in re.findall(r'(?:vertex|fragment) shader source:\n((?:libmpv_render: \[.*\n)+)', content)})}
    RESULTS.append(result)
    (ROOT / 'docs/evidence/renderer-regressions.json').write_text(json.dumps({'complete': False, 'results': RESULTS}, indent=2) + '\n')
    print(name, stats, flush=True)
    return pixels, result


def ffmpeg(*args):
    if CACHED and Path(args[-1]).exists(): return
    subprocess.run(['/opt/homebrew/bin/ffmpeg', '-v', 'error', '-y', *args], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--resume-at', help='Reuse hash-verified prior captures before this case')
    args = parser.parse_args()
    if args.resume_at:
        prior = json.loads((ROOT / 'docs/evidence/renderer-regressions.json').read_text())['results']
        for item in prior:
            if item['case'] == args.resume_at: break
            CACHED[item['case']] = item
    OUT.mkdir(parents=True, exist_ok=True)
    shader = ROOT / 'Sources/ManpingApp/Resources/Shaders/ArtCNNCompat/AniSD_ArtCNN_C4F32_i4.glsl'
    for name, w, h, opts, direct, prelinear in [
        ('none-noninteger', 960, 540, [], True, False),
        ('none-downscale', 320, 180, [], True, False),
        ('anime-noninteger', 1536, 864, ['glsl-shaders=' + str(shader)], False, True),
        ('anime-post2x-downscale', 960, 540, ['glsl-shaders=' + str(shader)], False, True),
        ('crop', 800, 600, ['panscan=1'], False, True),
        ('rotation', 720, 1280, ['video-rotate=90'], False, True),
        ('lanczos', 960, 540, ['scale=lanczos'], False, True),
    ]:
        _, result = capture(name, width=w, height=h, options=opts)
        assert any('direct bilinear' in p for p in result['passes']) is direct, name
        assert any('(prelinearized)' in p for p in result['passes']) is prelinear, name
    odd = OUT / 'odd.mkv'
    ffmpeg('-f', 'lavfi', '-i', 'testsrc=size=641x361:rate=30', '-t', '6', '-vf',
           'format=yuv444p,setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709',
           '-c:v', 'ffv1', str(odd))
    _, result = capture('odd', video=odd)
    assert not any('direct bilinear' in p for p in result['passes'])

    alpha = OUT / 'alpha.mkv'
    ffmpeg('-f', 'lavfi', '-i', 'color=red@0.5:size=640x360:rate=30,format=rgba',
           '-t', '6', '-c:v', 'ffv1', '-pix_fmt', 'bgra', str(alpha))
    alpha_opts = ['vf=format:gamma=bt.1886:primaries=bt.709']
    old_pixels, _ = capture('alpha-baseline', video=alpha, options=alpha_opts, library=OLD)
    new_pixels, result = capture('alpha', video=alpha, options=alpha_opts)
    assert np.array_equal(old_pixels, new_pixels)
    assert not any('direct bilinear' in p for p in result['passes'])
    assert any('alpha, ICC LUT' in p for p in result['policyMessages'])
    result['rawIdenticalToSealedBaseline'] = True

    linear_hook = OUT / 'linear.hook'
    linear_hook.write_text('//!HOOK LINEAR\n//!BIND HOOKED\n//!DESC LINEAR half-light probe\nvec4 hook() { return vec4(HOOKED_tex(HOOKED_pos).rgb * 0.5, 1.0); }\n')
    opts = ['target-trc=linear', 'target-prim=bt.2020', 'target-peak=406']
    pixels, hook_result = capture('linear-hook', video=BARS, options=[*opts, 'glsl-shaders=' + str(linear_hook)])
    assert any('LINEAR half-light probe' in p for p in hook_result['passes'])
    assert any('(prelinearized)' in p for p in hook_result['passes'])
    assert np.max(np.abs(pixels[360, 1120] - .5)) < .001, pixels[360, 1120]

    sigmoid_hook = OUT / 'sigmoid.hook'
    sigmoid_hook.write_text('//!HOOK SIGMOID\n//!BIND HOOKED\n//!DESC SIGMOID identity probe\nvec4 hook() { return HOOKED_tex(HOOKED_pos); }\n')
    _, result = capture('sigmoid-hook', options=['glsl-shaders=' + str(sigmoid_hook)])
    assert any('SIGMOID identity probe' in p for p in result['passes'])

    subtitle = OUT / 'subtitle.srt'
    subtitle.write_text('1\n00:00:00,000 --> 00:00:10,000\nVisible subtitle regression\n')
    baseline, _ = capture('subtitle-off', video=BARS, options=[*opts, 'glsl-shaders=' + str(linear_hook), 'blend-subtitles=yes'])
    subtitled, result = capture('subtitle-on', video=BARS, options=[*opts, 'glsl-shaders=' + str(linear_hook),
                                    'blend-subtitles=yes', 'sub-files=' + str(subtitle)])
    assert any('blend subs' in p for p in result['passes'])
    assert any('inverse EOTF' in p for p in result['passes'])
    result['changedSubtitlePixels'] = int(np.count_nonzero(np.any(baseline != subtitled, axis=2)))
    assert result['changedSubtitlePixels'] > 100
    assert not any('direct bilinear' in p for p in result['passes'])

    _, baseline = capture('dynamic-baseline', video=BARS, options=opts)
    pixels, result = capture('dynamic-20', video=BARS, options=[*opts, 'target-peak=203', 'fixture-peak-sequence=20'], seconds=4)
    content = (OUT / 'dynamic-20.log').read_text()
    assert len(re.findall(r'^PEAK_UPDATE ', content, re.M)) == 20
    assert result['shaderLinks'] <= baseline['shaderLinks'], (baseline['shaderLinks'], result['shaderLinks'])
    assert np.max(np.abs(pixels[360, 1120] - 1)) < .001
    result['twentyUpdatesWithoutAdditionalShaderLinks'] = True

    _, result = capture('known-black-mismatch', video=BARS, options=[*opts, 'vf=format:min-luma=0.1:max-luma=203', 'target-contrast=1000'])
    assert any('tone or black-point adaptation' in p for p in result['policyMessages'])
    assert 'target-contrast is not applied' in (OUT / 'known-black-mismatch.log').read_text()

    _, paused_baseline = capture('paused-baseline', video=BARS, options=[*opts, 'fixture-pause-at=0.7'], seconds=4)
    pixels, result = capture('paused-dynamic-20', video=BARS, options=[*opts, 'target-peak=203',
                                'fixture-peak-sequence=20', 'fixture-pause-at=0.7'], seconds=4)
    assert result['properties']['pause'] == 'yes'
    assert result['shaderLinks'] <= paused_baseline['shaderLinks'], (paused_baseline['shaderLinks'], result['shaderLinks'])
    assert np.max(np.abs(pixels[360, 160] - .603 / 203)) < 0.000004
    assert result['shaderSourceSHA256'] == paused_baseline['shaderSourceSHA256']
    result['pausedPeakRedrawVerified'] = True
    result['twentyUpdatesWithoutAdditionalShaderLinks'] = True
    pixels, result = capture('source-metadata-change', video=BARS, options=[*opts, 'target-peak=203',
                                'fixture-source-min-step=0.1'], seconds=4)
    assert any('src=0.1/203 dst=0.1/203' in p for p in result['policyMessages'])
    assert np.max(np.abs(pixels[360, 160] - .1 / 203)) < 0.000002
    result['currentFrameMetadataChangeVerified'] = True

    hdr = Path('/tmp/manping-hdr-bars.mp4')
    for name, trc, peak in [('pq-linear-2', 'linear', 406), ('pq-linear-16', 'linear', 3248), ('pq-sdr', 'srgb', 203)]:
        opts_hdr = [f'target-trc={trc}', f'target-peak={peak}', 'target-prim=' + ('bt.2020' if trc == 'linear' else 'bt.709'), 'hwdec=videotoolbox']
        old_pixels, _ = capture(name + '-baseline', video=hdr, options=opts_hdr, library=OLD)
        new_pixels, result = capture(name, video=hdr, options=opts_hdr)
        assert np.array_equal(old_pixels, new_pixels), name
        assert result['properties']['hwdec-current'] == 'videotoolbox'
        assert not any('metadata SDR BT.1886' in p or 'direct bilinear' in p for p in result['passes'])
        result['rawIdenticalToSealedBaseline'] = True

    hlg = OUT / 'hlg.mkv'
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30', '-t', '6', '-vf',
           'loop=loop=-1:size=1:start=0,format=yuv420p10le,setparams=range=limited:color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc',
           '-c:v', 'ffv1', str(hlg))
    hlg_opts = ['target-trc=linear', 'target-prim=bt.2020', 'target-peak=406']
    old_pixels, _ = capture('hlg-baseline', video=hlg, options=hlg_opts, library=OLD)
    new_pixels, result = capture('hlg', video=hlg, options=hlg_opts)
    assert np.array_equal(old_pixels, new_pixels)
    result['rawIdenticalToSealedBaseline'] = True
    report = {'complete': True, 'method': 'Actual CGL RGBA16F full-frame captures and real pass trace. HDR comparisons use untouched sealed integration libmpv; no image corrections.', 'results': RESULTS}
    (ROOT / 'docs/evidence/renderer-regressions.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
