#!/usr/bin/env python3
"""Macの単一CLIを直接wait4で計測する。期限と子孫停止は外側Supervisorが担う。"""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import time

ROOT = Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
RUN = ROOT/'tmp/mac-canterbury-reference-20261026'


def validate_environment(value):
    if (type(value) is not dict or set(value) != {'schema', 'cpu_ticks', 'logical_cpus',
            'thermal_state', 'ac_power'} or type(value['schema']) is not int or value['schema'] != 1
            or type(value['logical_cpus']) is not int or value['logical_cpus'] != 14
            or type(value['thermal_state']) is not int or not 0 <= value['thermal_state'] <= 3
            or type(value['ac_power']) is not bool or type(value['cpu_ticks']) is not list
            or len(value['cpu_ticks']) != 4
            or any(type(n) is not int or not 0 <= n < 2**32 for n in value['cpu_ticks'])):
        raise ValueError('invalid native environment observation')
    return value


def cpu_percent(before, after):
    validate_environment(before)
    validate_environment(after)
    delta = [(b-a) % 2**32 for a, b in zip(before['cpu_ticks'], after['cpu_ticks'])]
    if sum(delta) == 0:
        raise ValueError('CPU observation unavailable: zero tick interval')
    return 100*(sum(delta)-delta[2])/sum(delta)


def exit_state(status):
    if os.WIFEXITED(status):
        return True, os.WEXITSTATUS(status), None
    if os.WIFSIGNALED(status):
        return False, None, os.WTERMSIG(status)
    raise ValueError('wait4 did not return a terminal child status')


def observe(executable):
    raw = subprocess.run([str(executable)], check=True, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, timeout=5)
    if raw.stderr or len(raw.stdout) > 4096:
        raise ValueError('unexpected native metrics output')
    return validate_environment(json.loads(raw.stdout))


def checked(path, directory=False):
    p = Path(path)
    if not p.is_absolute() or ROOT not in p.parents or p != Path(os.path.normpath(str(p))):
        raise ValueError('path outside dedicated root')
    for parent in [p] + list(p.parents):
        if parent.is_symlink():
            raise ValueError('symlink path')
    if directory and not p.is_dir():
        raise ValueError('missing directory')
    return p


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--metrics', required=True)
    parser.add_argument('--cwd', required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('native Mac ARM64 measurement only')
    output, cwd = checked(args.output), checked(args.cwd, True)
    metrics = checked(args.metrics)
    if (RUN not in output.parents or RUN not in cwd.parents or output.exists()
            or not output.parent.is_dir() or metrics != ROOT/'tools/mac-native-system-metrics'):
        raise ValueError('unexpected measurement paths')
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or command[0] not in (str(ROOT/'cargo-target/aarch64-apple-darwin/release/unlhare-cli'),
                                        str(ROOT/'tools/7zip/7zz')):
        raise ValueError('unexpected measured executable')
    checked(command[0])
    os.umask(0o077)
    os.chdir(cwd)
    before = observe(metrics)
    actions = [(os.POSIX_SPAWN_OPEN, n, '/dev/null', os.O_RDONLY if n == 0 else os.O_WRONLY, 0)
               for n in range(3)]
    start = time.perf_counter_ns()
    pid = os.posix_spawn(command[0], command, dict(os.environ), file_actions=actions)
    waited, status, usage = os.wait4(pid, 0)
    elapsed = time.perf_counter_ns()-start
    if waited != pid or elapsed <= 0:
        raise ValueError('invalid wait4 result')
    after = observe(metrics)
    normal, code, sig = exit_state(status)
    result = dict(elapsed_ns=elapsed, user_seconds=usage.ru_utime, system_seconds=usage.ru_stime,
                  peak_rss_bytes=usage.ru_maxrss,
                  cpu_per_wall=(usage.ru_utime+usage.ru_stime)/(elapsed/1e9),
                  normal_exit=normal, exit_code=code, signal=sig,
                  cpu_interval_percent=cpu_percent(before, after),
                  environment_before=before, environment_after=after)
    if usage.ru_maxrss <= 0 or any(not math.isfinite(result[k]) or result[k] < 0
            for k in ('user_seconds', 'system_seconds', 'cpu_per_wall')):
        raise ValueError('invalid native resource usage')
    with output.open('x', encoding='utf-8') as stream:
        stream.write(json.dumps(result, allow_nan=False, separators=(',', ':'))+'\n')


if __name__ == '__main__':
    main()
