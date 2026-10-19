"""Terminal recovery gate shared by the network runner and regression samples."""
import math


def terminal_outcome(samples, fault_start, budget):
    """Require an observed, settled policy failure within budget that stays stopped.

    A transient Player error is not a policy failure. Resource cancellation may
    settle after policy failure, so the deadline uses the first quiet sample.
    Require another sample afterwards to observe that the terminal state holds.
    """
    entered = None
    settled_index = None
    settled_counts = None
    valid = True
    for index, sample in enumerate(samples):
        terminal = sample.get('terminal') == '1'
        if entered is not None and not terminal:
            valid = False
        if not terminal:
            continue
        elapsed = float(sample['elapsed_s'])
        terminal_at = float(sample.get('terminal_elapsed_s', -1))
        if terminal_at < 0 or terminal_at > elapsed:
            valid = False
        if entered is None:
            entered = terminal_at
        elif terminal_at != entered:
            valid = False
        if (sample['error'] != 'present' or sample['buffering'] != '0'
                or sample['advancing'] != '0'):
            valid = False
        raw_activity = (sample.get('raw_advancing') != '0'
                        or sample.get('raw_render_advancing') != '0'
                        or sample.get('raw_engine_advancing') != '0')
        observed = float(sample.get('observed_elapsed_s', -1))
        origin_counts = tuple(int(sample.get(key, -1)) for key in ('origin_requests', 'origin_bytes'))
        quiet = (not raw_activity and sample['error'] == 'present'
                 and sample['buffering'] == '0' and sample['advancing'] == '0'
                 and sample.get('engine_idle') == '1'
                 and int(sample.get('origin_active_requests', -1)) == 0
                 and min(origin_counts) >= 0 and math.isfinite(observed) and observed >= 0
                 and int(sample['relay_inflight']) == 0
                 and int(sample['relay_connections']) == 0)
        if settled_index is not None and (not quiet or origin_counts != settled_counts):
            valid = False
        if quiet and settled_index is None:
            settled_index = index
            settled_counts = origin_counts

    settled_at = (max(float(samples[settled_index]['elapsed_s']), float(samples[settled_index]['observed_elapsed_s']))
                  if settled_index is not None else None)
    from_fault = settled_at - fault_start if settled_at is not None else None
    held = valid and settled_index is not None and settled_index < len(samples) - 1
    return {
        'terminal_entered_s': entered,
        'terminal_settled_s': settled_at,
        'terminal_settled_from_fault_s': from_fault,
        'terminal_settled': bool(held),
        'bounded_error': bool(held and 0 <= from_fault <= budget),
    }
