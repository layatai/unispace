import importlib.util
from pathlib import Path
import unittest

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('verify_live', root / 'Scripts/verify-live-control.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SESSION = '33333333-3333-3333-3333-333333333333'
PEER = '22222222-2222-2222-2222-222222222222'


def recording():
    events = [dict(kind='ready', host=host, observedSeconds=0, build='43',
                   diagnosticsEnabled=True, pids=['123'], deviceID=PEER if host=='receiver' else '11111111-1111-1111-1111-111111111111')
              for host in ('controller','receiver')]
    def log(t, line):
        events.append(dict(kind='log', host='controller', observedSeconds=t, line=line))
    log(2, f'Session {SESSION} is controlling peer {PEER}; mode=probing')
    for index in range(120):
        t=3+index/2
        events.append(dict(kind='cursor', host='receiver', observedSeconds=t, x=index, y=100))
        events.append(dict(kind='cursor', host='controller', observedSeconds=t, x=0, y=100))
        log(t, f'Realtime progress accepted for session {SESSION}; generation=1, sequence={index}')
        log(t, f'heartbeat echo for session {SESSION}; latency=50ms')
    for t in (17,32,47):log(t, 'Seamless window ended: connection closed')
    log(64, f'Ending session; reason=peer crossed boundary right, state=controlling(epoch: example, session: {SESSION}), notifyPeer=true')
    events.extend(dict(kind='done',host=host,observedSeconds=90,observerExitCode=0) for host in ('controller','receiver'))
    return events


class LiveVerifierTests(unittest.TestCase):
    def test_real_motion_progress_and_catalog_cleanup_are_required_for_pass(self):
        report=module.analyze(recording(),43)
        self.assertEqual(report['status'],'PASS')
        self.assertEqual(report['catalogClosuresDuringSession'],3)
        self.assertIn('Not measured',report['cursorLatency'])

    def test_heartbeat_only_cannot_pass(self):
        events=[e for e in recording() if e['kind']!='cursor' and 'Realtime progress' not in e.get('line','')]
        self.assertEqual(module.analyze(events,43)['status'],'INCONCLUSIVE')

    def test_old_catalog_shutdown_bug_fails(self):
        events=recording()
        events.append(dict(kind='log',host='controller',observedSeconds=20,
            line=f'Ending session; reason=manual stop, state=controlling(epoch: example, session: {SESSION}), notifyPeer=true'))
        self.assertEqual(module.analyze(events,43)['status'],'FAIL')

    def test_partial_or_failed_observer_cannot_pass(self):
        events=[e for e in recording() if e['kind']!='done']
        self.assertEqual(module.analyze(events,43)['status'],'INCONCLUSIVE')
        events=recording()
        events[-1]['observerExitCode']=2
        self.assertEqual(module.analyze(events,43)['status'],'FAIL')

    def test_wrong_build_fails(self):
        self.assertEqual(module.analyze(recording(),42)['status'],'FAIL')

    def test_controller_cursor_leak_fails_even_when_remote_delivery_continues(self):
        events=recording()
        for event in events:
            if event['kind']=='cursor' and event['host']=='controller':event['x']=event['observedSeconds']*10
        self.assertEqual(module.analyze(events,43)['status'],'FAIL')

    def test_stationary_os_cursor_cannot_pass(self):
        events=recording()
        for e in events:
            if e['kind']=='cursor':e['x']=100
        self.assertEqual(module.analyze(events,43)['status'],'INCONCLUSIVE')

    def test_unexercised_catalog_cleanup_cannot_pass(self):
        events=[e for e in recording() if 'Seamless window ended' not in e.get('line','')]
        self.assertEqual(module.analyze(events,43)['status'],'INCONCLUSIVE')


if __name__=='__main__':unittest.main()
