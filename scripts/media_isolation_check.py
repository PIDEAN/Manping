#!/usr/bin/env python3
"""Verify fail-closed mpv options and one quiet loopback persistent-403 perf load.

--self-test compiles the real Cbridge against a tiny in-memory fake mpv API. The normal
check uses only the supplied child, a loopback origin, and fake yt-dlp/youtube-dl scripts.
No real extractor is executed. This verifies media options, not all process network I/O.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import uuid

from diagnostic_audio import media_isolation_summary
from diagnostic_privacy import scrub
from net_fault_server import FaultOrigins
from network_stability_check import ROOT, BUILD, ALLOWED, build_path, fields


FAKE_MPV = r'''
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static int mode, initialized, destroyed, sets, reads, ordering_error;
void fake_reset(int value) { mode=value; initialized=destroyed=sets=reads=ordering_error=0; }
int fake_destroyed(void) { return destroyed; }
int fake_initialized(void) { return initialized; }
int fake_sets(void) { return sets; }
int fake_reads(void) { return reads; }
int fake_ordering_error(void) { return ordering_error; }
void *mpv_create(void) { return calloc(1,1); }
int mpv_initialize(void *h) { initialized++; return mode==7?-1:0; }
int mpv_set_option_string(void *h,const char *name,const char *value) {
    const char *names[]={"ytdl","load-scripts","cookies"};
    for(int i=0;i<3;i++) if(strcmp(name,names[i])==0) {
        sets++;
        if(initialized || strcmp(value,"no")!=0) ordering_error++;
        if(mode==i+1) return -1;
    }
    return 0;
}
char *mpv_get_property_string(void *h,const char *name) {
    const char *names[]={"options/ytdl","options/load-scripts","options/cookies"};
    for(int i=0;i<3;i++) if(strcmp(name,names[i])==0) {
        reads++; if(!initialized) ordering_error++;
        if(mode==i+4) return i==1?NULL:strdup("yes");
        return strdup("no");
    }
    return NULL;
}
void mpv_terminate_destroy(void *h) { destroyed++; free(h); }
void mpv_free(void *p) { free(p); }
const char *mpv_error_string(int value) { return "fixture failure"; }
int mpv_set_property_string(void *h,const char *n,const char *v) { return 0; }
int mpv_get_property(void *h,const char *n,int f,void *v) { return -1; }
int mpv_command_node(void *h,void *a,void *b) { return 0; }
int mpv_command(void *h,const char *const *args) { return 0; }
void *mpv_wait_event(void *h,double timeout) { return NULL; }
int mpv_request_log_messages(void *h,const char *level) { return 0; }
void mpv_free_node_contents(void *node) {}
uint64_t mpv_render_context_update(void *ctx) { return 0; }
void mpv_render_context_set_update_callback(void *ctx,void *callback,void *data) {}
int mpv_render_context_create(void **ctx,void *h,void *params) { return 0; }
int mpv_render_context_render(void *ctx,void *params) { return 0; }
void mpv_render_context_report_swap(void *ctx) {}
void mpv_render_context_free(void *ctx) {}
'''


def clean_environment():
    return {key: value for key, value in os.environ.items() if not key.startswith('MANPING_')}


def self_test(output):
    """Exercise the production constructor's pre-init and post-init failure branches."""
    fake_source = output / 'fake-mpv.c'
    fake_source.write_text(FAKE_MPV)
    fake_library = output / 'libfake-mpv.dylib'
    bridge_library = output / 'libbridge-under-test.dylib'
    env = clean_environment()
    commands = [
        ['xcrun', 'clang', '-dynamiclib', '-Wl,-install_name,@rpath/libfake-mpv.dylib',
         str(fake_source), '-o', str(fake_library)],
        ['xcrun', 'clang', '-dynamiclib', '-I', str(ROOT / 'Sources/CMpv/include'),
         '-Wl,-install_name,@rpath/libbridge-under-test.dylib',
         str(ROOT / 'Sources/CMpv/bridge.c'), '-framework', 'OpenGL', '-o', str(bridge_library)],
    ]
    for index, command in enumerate(commands):
        result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (output / f'compile-{index}.log').write_text(scrub(result.stdout))
        if result.returncode:
            raise RuntimeError('fixture compilation failed')
    fake = ctypes.CDLL(str(fake_library))
    bridge = ctypes.CDLL(str(bridge_library))
    bridge.bili_mpv_create.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t]
    bridge.bili_mpv_create.restype = ctypes.c_void_p
    bridge.bili_mpv_isolation_mask.argtypes = [ctypes.c_void_p]
    bridge.bili_mpv_isolation_mask.restype = ctypes.c_int
    bridge.bili_mpv_destroy.argtypes = [ctypes.c_void_p]
    cases = []
    for mode in range(8):
        fake.fake_reset(mode)
        message = ctypes.create_string_buffer(256)
        handle = bridge.bili_mpv_create(os.fsencode(fake_library), 1, message, len(message))
        if mode == 0:
            assert handle and bridge.bili_mpv_isolation_mask(handle) == 7
            assert fake.fake_sets() == 3 and fake.fake_reads() == 3
            bridge.bili_mpv_destroy(handle)
        else:
            assert not handle and fake.fake_destroyed() == 1
            assert fake.fake_initialized() == (0 if mode <= 3 else 1)
        assert fake.fake_ordering_error() == 0 and fake.fake_destroyed() == 1
        cases.append({'mode': mode, 'result': 'PASS'})
    # Ordinary mode must not add option requirements or post-init reads to custom libraries.
    fake.fake_reset(1)
    message = ctypes.create_string_buffer(256)
    handle = bridge.bili_mpv_create(os.fsencode(fake_library), 0, message, len(message))
    assert handle and bridge.bili_mpv_isolation_mask(handle) == 0
    assert fake.fake_sets() == 0 and fake.fake_reads() == 0
    bridge.bili_mpv_destroy(handle)
    assert fake.fake_destroyed() == 1
    cases.append({'mode': 'production_without_isolation_options', 'result': 'PASS'})
    report = {'result': 'PASS', 'cases': cases, 'scope': 'real bridge; fake mpv API; no media or external helpers'}
    (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print('media isolation Cbridge self-test: PASS (9 cases)', flush=True)
    return report


def safe_line(raw):
    line = raw.strip()
    if line.startswith('PERF FAIL'):
        return 'PERF FAIL reason=diagnostic_failure'
    if not ALLOWED.match(line):
        return None
    checked = re.sub(r'\bcookies=no\b', '', line) if line.startswith('PERF media_isolation ') else line
    if re.search(r'(?:https?://|/Users/|/private/|Cookie|Token)', checked, re.I):
        return 'PERF FAIL reason=unsafe_output_omitted'
    return scrub(line)


def run_check(binary, library, output, seconds):
    helper_dir = output / 'fake-bin'
    helper_dir.mkdir()
    marker = output / 'helper-called.marker'
    control = output / 'helper-control.marker'
    helper = ('#!/bin/sh\ncase "${1-}" in\n'
              '  --diagnostic-control) : > "$MANPING_FAKE_HELPER_CONTROL" ;;\n'
              '  *) : > "$MANPING_FAKE_HELPER_MARKER" ;;\nesac\nexit 1\n')
    for name in ['yt-dlp', 'youtube-dl']:
        path = helper_dir / name
        path.write_text(helper); path.chmod(0o700)
    env = clean_environment()
    env.update({'PATH': str(helper_dir) + os.pathsep + env.get('PATH', ''),
                'MANPING_MPV_LIBRARY': str(library),
                'MANPING_FAKE_HELPER_MARKER': str(marker), 'MANPING_FAKE_HELPER_CONTROL': str(control)})
    # Execute only our harmless script as a control, using a different marker from the load.
    subprocess.run([str(helper_dir / 'yt-dlp'), '--diagnostic-control'], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    assert control.is_file() and not marker.exists()
    media = output / 'synthetic.bin'
    media.write_bytes(bytes(range(256)) * 16)
    origin = FaultOrigins(media, '403', False, fault_start=0, fault_end=90)
    args = [str(binary), '--perf-fixture', '--skip-auth', '--perf-network', origin.primary_url,
            '--perf-network-seconds', str(seconds)]
    process = None
    lines = []
    timed_out = False
    try:
        process = subprocess.Popen(args, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True, errors='replace')
        def read_lines():
            with (output / 'app.log').open('w') as log:
                for raw in process.stdout:
                    line = safe_line(raw)
                    if line is None: continue
                    lines.append(line); log.write(line + '\n'); log.flush()
        reader = threading.Thread(target=read_lines, daemon=True)
        reader.start()
        started = time.monotonic()
        while process.poll() is None:
            if time.monotonic() - started > seconds + 35:
                timed_out = True
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
                break
            time.sleep(.25)
        process.wait(); reader.join(timeout=5)
        isolation = media_isolation_summary(lines)
        samples = [fields(line) for line in lines if line.startswith('PERF network SAMPLE')]
        final = samples[-1] if samples else {}
        counters = origin.snapshot()
        failed_media = (counters.get('fault_responses', 0) > 0 and final.get('error') == 'present'
                        and final.get('buffering') == '0')
        complete = process.returncode == 0 and not timed_out and 'PERF complete' in lines and not any(
            line.startswith('PERF FAIL') for line in lines)
        report = {'result': 'PASS' if complete and failed_media and isolation['verified'] and not marker.exists() else 'FAIL',
                  'exit_code': process.returncode, 'timed_out': timed_out,
                  'media_isolation': isolation, 'persistent_403_seen': counters.get('fault_responses', 0) > 0,
                  'terminal_media_error_seen': failed_media, 'helper_control_pass': control.exists(),
                  'helper_invoked_during_load': marker.exists(), 'origin': counters,
                  'scope': 'one loopback persistent403 perf load; fake helpers only; not a whole-process network audit'}
        (output / 'summary.json').write_text(scrub(json.dumps(report, indent=2)) + '\n')
        print(json.dumps(report), flush=True)
        return report
    finally:
        if process is not None and process.poll() is None:
            process.kill(); process.wait()
        origin.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--app', type=Path)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--seconds', type=int, default=35)
    args = parser.parse_args()
    if not 30 <= args.seconds <= 60: parser.error('--seconds must be between 30 and 60')
    if args.output is None:
        if not args.self_test: parser.error('--output is required')
        args.output = ROOT / '.build' / ('media-isolation-selftest-' + uuid.uuid4().hex)
    try:
        output = build_path(args.output)
        output.mkdir(parents=True, exist_ok=False)
    except (ValueError, FileExistsError):
        parser.error('output must be a new directory inside .build')
    if args.self_test:
        self_test(output); return
    if args.app is None or args.library is None: parser.error('--app and --library are required')
    binary = args.app / 'Contents/MacOS/Manping' if args.app.is_dir() else args.app
    library = args.library.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK) or not library.is_file() or BUILD not in library.parents:
        parser.error('App executable and a built .build libmpv must exist')
    report = run_check(binary.resolve(), library, output, args.seconds)
    raise SystemExit(0 if report['result'] == 'PASS' else 1)


if __name__ == '__main__':
    main()
