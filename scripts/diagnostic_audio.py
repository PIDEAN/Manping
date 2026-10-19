"""Scalar-only audio and aligned CPU summaries shared by quiet playback runners."""
import math
import re
import statistics


def number(sample, name):
    try:
        value = float(sample.get(name, 'unavailable'))
        return value if math.isfinite(value) else None
    except (TypeError, ValueError):
        return None


def distribution(values):
    values = sorted(values)
    return {'samples': len(values),
            'p95': values[max(0, math.ceil(len(values) * .95) - 1)] if values else None,
            'max': values[-1] if values else None}


def audio_summary(samples):
    eligible = [sample for sample in samples
                if sample.get('advancing') == '1' and sample.get('buffering') == '0'
                and sample.get('error', 'none') == 'none' and number(sample, 'audio_present') == 1
                and sample.get('actual_ao') in ('coreaudio', 'avfoundation', 'other')
                and (number(sample, 'audio_rate_hz') or 0) > 0
                and (number(sample, 'audio_channels') or 0) > 0]
    deviations = [abs(value) for sample in eligible
                  if (value := number(sample, 'avsync_s')) is not None]
    changes = [abs(value) for sample in eligible
               if (value := number(sample, 'total_avsync_change_s')) is not None]
    return {'actual_ao': sorted({sample.get('actual_ao', 'unavailable') for sample in samples}),
            'audio_present_samples': sum(number(sample, 'audio_present') == 1 for sample in samples),
            'eligible_playing_audio_samples': len(eligible),
            'valid_for_audio_cpu_comparison': len(eligible) >= 3,
            'abs_avsync_s': distribution(deviations),
            'abs_total_avsync_change_s': distribution(changes),
            'sample_rates_hz': sorted({value for sample in eligible
                                      if (value := number(sample, 'audio_rate_hz')) is not None}),
            'input_channel_counts': sorted({value for sample in eligible
                                           if (value := number(sample, 'audio_input_channels')) is not None}),
            'output_channel_counts': sorted({value for sample in eligible
                                            if (value := number(sample, 'audio_channels')) is not None}),
            'avsync_policy': 'finite known samples only; advancing, not buffering, actual audio track and non-null output'}


def phased_audio(samples, fault_start, fault_end):
    result = audio_summary(samples)
    result['phases'] = {
        name: audio_summary([sample for sample in samples
                             if (elapsed := number(sample, 'elapsed_s')) is not None and predicate(elapsed)])
        for name, predicate in [('before_fault', lambda t: t < fault_start),
                                ('during_fault', lambda t: fault_start <= t <= fault_end),
                                ('after_fault', lambda t: t > fault_end)]}
    return result


def cpu_summary(rows, app_offset, samples, fault_start=None, fault_end=None):
    def mean(values):
        return {'samples': len(values), 'mean_pct': round(statistics.mean(values), 3) if values else None,
                'max_pct': max(values) if values else None}
    result = {'whole_launch_through_teardown': mean([row[1] for row in rows]),
              'app_start_from_launch_s': app_offset,
              'method': 'ps process CPU sampled once per second; phase labels use App START and origin fault offsets, bounded by the last App sample plus 1.5s; whole mean includes teardown'}
    if app_offset is None:
        return result
    last_sample = max((value for sample in samples if (value := number(sample, 'elapsed_s')) is not None), default=-2)
    aligned = [(row[0] - app_offset, row[1]) for row in rows if 0 <= row[0] - app_offset <= last_sample + 1.5]
    result['app_sample_window'] = mean([cpu for _, cpu in aligned])
    if fault_start is not None and fault_end is not None:
        result.update({name: mean([cpu for elapsed, cpu in aligned if predicate(elapsed)])
                       for name, predicate in [('before_fault', lambda t: t < fault_start),
                                               ('during_fault', lambda t: fault_start <= t <= fault_end),
                                               ('after_fault', lambda t: t > fault_end)]})
    buffering = []
    for elapsed, cpu in aligned:
        near = [sample for sample in samples
                if (stamp := number(sample, 'elapsed_s')) is not None and 0 <= elapsed - stamp <= 1.5]
        if near and near[-1].get('buffering') == '1':
            buffering.append(cpu)
    result['app_reported_buffering'] = mean(buffering)
    return result


def media_isolation_summary(lines):
    samples = [dict(re.findall(r'([a-z_]+)=([^\s]+)', line)) for line in lines
               if line.startswith('PERF media_isolation ')]
    verified = bool(samples) and all(sample.get('requested') == '1' and sample.get('verified') == '1'
        and all(sample.get(name) == 'no' for name in ('ytdl', 'load_scripts', 'cookies')) for sample in samples)
    return {'verified': verified, 'samples': samples,
            'scope': 'mpv creation option read-back only; API audit does not cover all process network traffic'}


def self_test():
    valid = {'elapsed_s': '1', 'advancing': '1', 'buffering': '0', 'error': 'none',
             'actual_ao': 'coreaudio', 'audio_present': '1', 'avsync_s': '-0.025',
             'audio_rate_hz': '48000', 'audio_channels': '6', 'audio_input_channels': '6'}
    samples = [dict(valid, elapsed_s=str(i)) for i in range(5)]
    samples += [dict(valid, avsync_s='unavailable'), dict(valid, avsync_s='nan'),
                dict(valid, avsync_s='50', buffering='1'), dict(valid, avsync_s='50', audio_present='0'),
                dict(valid, avsync_s='50', actual_ao='null')]
    summary = audio_summary(samples)
    assert summary['abs_avsync_s'] == {'samples': 5, 'p95': .025, 'max': .025}
    assert summary['input_channel_counts'] == [6] and summary['output_channel_counts'] == [6]
    assert not audio_summary([dict(valid, audio_present='0')])['valid_for_audio_cpu_comparison']
    assert audio_summary([dict(valid, avsync_s='unavailable')])['abs_avsync_s']['p95'] is None
    cpu = cpu_summary([(0, 90, 0), (2, 20, 0), (3, 30, 0), (4, 40, 0)], 1,
                      [dict(valid, elapsed_s='2', buffering='1')], 1, 2)
    assert cpu['whole_launch_through_teardown']['samples'] == 4
    assert cpu['during_fault']['mean_pct'] == 25
    assert cpu['app_reported_buffering']['mean_pct'] == 35
    assert len(phased_audio(samples, 1, 3)['phases']) == 3
    proof = 'PERF media_isolation requested=1 verified=1 ytdl=no load_scripts=no cookies=no'
    assert media_isolation_summary([proof])['verified']
    assert not media_isolation_summary([])['verified']
    assert not media_isolation_summary([proof.replace('cookies=no', 'cookies=yes')])['verified']
    print('diagnostic_audio self-test: PASS')


if __name__ == '__main__':
    self_test()
