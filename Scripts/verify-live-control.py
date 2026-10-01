#!/usr/bin/env python3
"""Observe real UniSpace apps during physical mouse input; never synthesize input."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
MONITOR = r'''
import json,os,plistlib,subprocess,sys,threading,time
from pathlib import Path
duration=float(sys.argv[1]); observer=Path(sys.argv[2]).expanduser()
root=Path.home()/'Library/Containers/com.layatai.unispace/Data/Library'
log=root/'Application Support/UniSpace/Logs/diagnostics.log'
info=plistlib.loads(Path('/Applications/UniSpace.app/Contents/Info.plist').read_bytes())
workspace=json.loads((root/'Application Support/UniSpace/workspace.json').read_text())
prefs=plistlib.loads((root/'Preferences/com.layatai.unispace.plist').read_bytes())
lock=threading.Lock()
def emit(value):
 with lock: print(json.dumps(value),flush=True)
offset=log.stat().st_size if log.exists() else 0
process=subprocess.Popen([str(observer),str(duration)],stdout=subprocess.PIPE,text=True)
def cursor():
 for line in process.stdout:
  emit(json.loads(line))
thread=threading.Thread(target=cursor);thread.start()
emit({'kind':'ready','build':info['CFBundleVersion'],'version':info['CFBundleShortVersionString'],
      'deviceID':workspace['localDeviceID']['rawValue'],'diagnosticsEnabled':prefs.get('DiagnosticLoggingEnabled',False),
      'pids':subprocess.check_output(['pgrep','-f',r'^/Applications/UniSpace[.]app/Contents/MacOS/UniSpace([[:space:]]|$)'],text=True).split()})
started=time.monotonic()
try:
 while time.monotonic()-started<duration:
  if log.exists():
   if log.stat().st_size<offset:offset=0
   with log.open() as stream:
    stream.seek(offset)
    for line in stream:
     emit({'kind':'log','line':line.rstrip(),'monotonicNanos':time.monotonic_ns()})
    offset=stream.tell()
  time.sleep(.1)
finally:
 if process.poll() is None: process.terminate()
 process.wait(timeout=5);thread.join(timeout=5)
emit({'kind':'done'})
'''


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered)-1, int((len(ordered)-1)*fraction))] if ordered else None


def analyze(events, expected_build, minimum_active=45):
    metadata = {event['host']: event for event in events if event['kind'] == 'ready'}
    failures, missing = [], []
    for host in ('controller', 'receiver'):
        meta = metadata.get(host)
        if not meta:
            missing.append(f'{host}: no live recorder metadata')
        elif meta['build'] != str(expected_build) or not meta['diagnosticsEnabled'] or not meta['pids']:
            failures.append(f'{host}: wrong build, disabled diagnostics, or app not running')
    peer = metadata.get('receiver', {}).get('deviceID', '')
    sessions, starts, ends, bad_stops = {}, {}, {}, []
    latencies, reliable, realtime, catalog_closes = [], [], [], []
    for event in events:
        if event['host'] != 'controller' or event['kind'] != 'log':
            continue
        line = event['line']; stamp = event['observedSeconds']
        match = re.search(r'Session ([A-F0-9-]+) is controlling peer ([A-F0-9-]+)', line)
        if match and match[2] == peer:
            starts[match[1]] = stamp
        match = re.search(r'Ending session; reason=(.*?), state=(?:controlling|recoveringController)\(.*?session: ([A-F0-9-]+)\)', line)
        if match and match[2] in starts:
            ends[match[2]] = stamp
            if not match[1].startswith('peer crossed boundary'):
                bad_stops.append({'session': match[2], 'reason': match[1], 'atSeconds': stamp})
        if 'Input injected through sequence' in line: reliable.append(stamp)
        if 'Realtime progress accepted' in line or 'Realtime progress established' in line: realtime.append(stamp)
        if 'Seamless window ended: connection closed' in line: catalog_closes.append(stamp)
        match = re.search(r'heartbeat echo.*latency=(\d+)ms', line)
        if match: latencies.append(int(match[1]))
    last = max((event['observedSeconds'] for event in events), default=0)
    for session, start in starts.items():
        sessions[session] = {'start': start, 'end': ends.get(session, last), 'seconds': ends.get(session, last)-start}
    best = max(sessions.values(), key=lambda value: value['seconds'], default={'start':0,'end':0,'seconds':0})
    if best['seconds'] < minimum_active:
        missing.append(f'No continuous remote session lasting {minimum_active} seconds')
    cursor = [event for event in events if event['host']=='receiver' and event['kind']=='cursor'
              and best['start']+1 <= event['observedSeconds'] <= best['end']-1]
    changed = sum(math.hypot(b['x']-a['x'], b['y']-a['y']) >= 0.5 for a,b in zip(cursor,cursor[1:]))
    if changed < 100: missing.append('Fewer than 100 actual receiver cursor-position changes during remote control')
    inside = lambda values: sum(best['start'] <= value <= best['end'] for value in values)
    reliable_count, realtime_count = inside(reliable), inside(realtime)
    if reliable_count+realtime_count < 100: missing.append('Insufficient application input-progress acknowledgments')
    closes = inside(catalog_closes)
    if closes < 2: missing.append('Catalog connection cleanup was not exercised twice during active control')
    if bad_stops: failures.append('Remote control ended unexpectedly')
    if latencies and percentile(latencies,.95)>250: failures.append('Heartbeat RTT p95 exceeded 250 ms')
    if not latencies: missing.append('No active-session heartbeat RTT samples')
    return {'status':'FAIL' if failures else 'INCONCLUSIVE' if missing else 'PASS',
            'scope':'Live session stability and OS cursor delivery; not physical end-to-end cursor latency',
            'metadata':metadata,'longestSessionSeconds':round(best['seconds'],2),
            'receiverCursorChanges':changed,'receiverCursorSamples':len(cursor),
            'reliableProgressEvents':reliable_count,'realtimeProgressEvents':realtime_count,
            'catalogClosuresDuringSession':closes,'heartbeatRTTp95Milliseconds':percentile(latencies,.95),
            'unexpectedStops':bad_stops,'failures':failures,'missingEvidence':missing,
            'cursorLatency':'Not measured: requires correlated capture and receiver observation timestamps'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--peer', required=True, help='SSH identity for the receiving Mac')
    parser.add_argument('--expected-build', required=True)
    parser.add_argument('--duration',type=int,default=90)
    parser.add_argument('--minimum-active',type=int,default=45)
    parser.add_argument('--output',type=Path,default=ROOT/'.build/live-verification/latest')
    args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    observer=ROOT/'.build/live-verification/CursorObserver'
    subprocess.run(['swiftc','-O',str(ROOT/'Tools/LiveControlObserver/main.swift'),'-o',str(observer)],check=True)
    ssh=['ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10',args.peer]
    subprocess.run(ssh+['mkdir -p .unispace-live-verification/build'],check=True)
    subprocess.run(['scp','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',str(observer),
                    args.peer+':.unispace-live-verification/build/CursorObserver'],check=True)
    commands={
        'controller':[sys.executable,'-u','-c',MONITOR,str(args.duration),str(observer)],
        'receiver':ssh+[shlex.join(['python3','-u','-c',MONITOR,str(args.duration),'~/.unispace-live-verification/build/CursorObserver'])],
    }
    started=time.monotonic(); events=[]; lock=threading.Lock(); processes=[]; threads=[]
    stream=(args.output/'events.jsonl').open('w')
    def consume(host,process):
        for line in process.stdout:
            value=json.loads(line);value['host']=host;value['observedSeconds']=time.monotonic()-started
            with lock:
                events.append(value);stream.write(json.dumps(value)+'\n');stream.flush()
            if value['kind']=='ready':print(f'READY {host}: build {value["build"]}, PID {value["pids"]}',flush=True)
    try:
        for host,command in commands.items():
            process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=(args.output/(host+'-stderr.log')).open('w'),text=True)
            processes.append(process)
            thread=threading.Thread(target=consume,args=(host,process));thread.start();threads.append(thread)
        while any(process.poll() is None for process in processes):
            with lock: report=analyze(list(events),args.expected_build,args.minimum_active)
            (args.output/'progress.json').write_text(json.dumps(report,indent=2)+'\n')
            if time.monotonic()-started>args.duration+15: raise TimeoutError('Live recorders did not finish')
            time.sleep(1)
        for thread in threads:thread.join(timeout=5)
    finally:
        for process in processes:
            if process.poll() is None:process.terminate()
        stream.close()
    report=analyze(events,args.expected_build,args.minimum_active)
    (args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2),flush=True)
    return 0 if report['status']=='PASS' else 1


if __name__=='__main__':
    raise SystemExit(main())
