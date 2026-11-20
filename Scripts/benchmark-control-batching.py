#!/usr/bin/env python3
"""Compare fallback batching locally without changing production defaults or gates."""
import argparse
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import time

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--samples', type=int, default=500)
parser.add_argument('--output', type=Path, default=root / '.build/control-batching.json')
args = parser.parse_args()
if args.samples < 100:
    parser.error('--samples must be at least 100')
subprocess.run([str(root / 'Scripts/bootstrap.sh')], cwd=root, check=True, stdout=subprocess.DEVNULL)
subprocess.run(['xcodebuild', 'build', '-project', 'UniSpace.xcodeproj', '-scheme', 'UniSpaceSimulation',
                '-configuration', 'Release', '-destination', 'platform=macOS,arch=arm64',
                '-derivedDataPath', str(root / '.build/simulation'), 'CODE_SIGNING_ALLOWED=NO'],
               cwd=root, check=True, stdout=subprocess.DEVNULL)
executable = root / '.build/simulation/Build/Products/Release/UniSpaceSimulation'
results = []
for milliseconds in (1, 4, 8, 16):
    environment = dict(os.environ, UNISPACE_POINTER_BATCH_MS=str(milliseconds), UNISPACE_RELIABLE_POINTER_ONLY='1')
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.monotonic()
    process = subprocess.Popen([str(executable), 'run-two', '--samples', str(args.samples)], cwd=root,
                               env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=max(120, args.samples / 3))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
        stderr += '\nBenchmark subprocess exceeded its deadline.'
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    simulation = json.loads(stdout) if stdout.strip() else {'passed': False, 'conditions': [], 'failures': [stderr.strip()]}
    result = {'batchMilliseconds': milliseconds, 'seconds': time.monotonic() - started,
              'childCpuSeconds': (after.ru_utime + after.ru_stime) - (before.ru_utime + before.ru_stime),
              'exitCode': process.returncode, 'simulation': simulation}
    results.append(result)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({'scope': 'local two-process reliable-pointer simulation', 'results': results}, indent=2) + '\n')
    print(f'{milliseconds} ms: passed={result["simulation"]["passed"]}, cpu={result["childCpuSeconds"]:.2f}s', flush=True)
if any(item['exitCode'] or not item['simulation']['passed'] for item in results):
    raise SystemExit(1)
