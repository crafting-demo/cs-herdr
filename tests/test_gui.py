"""Transport and readiness regressions; no network, GUI, or real core state.

Run with: python3 -m unittest discover -s tests -v
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CS = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps(['cs'] + args) + '\n')
if 'show' in args:
    if os.environ.get('MISSING'):
        sys.exit(1)
    print(json.dumps({'meta': {'id': 'unique-id'},
        'spec': {'op_state': {'state': os.environ.get('STATE', 'RUNNING')},
                 'workloads': [{'name': 'dev', 'workspace': {}}]}}))
elif 'resume' in args:
    print('resuming')
    sys.exit(int(os.environ.get('RESUME_FAIL', '0')))
elif 'wait' in args:
    print('readiness progress')
    sys.exit(int(os.environ.get('WAIT_FAIL', '0')))
elif 'ssh' in args:
    sys.stdout.buffer.write(sys.stdin.buffer.read())
else:
    sys.exit('unexpected cs invocation: ' + repr(args))
'''
HC = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps(['hc'] + args) + '\n')
state = os.environ['MACHINES']
if args[:2] == ['machine', 'ls']:
    value = json.loads(open(state).read())
    if os.environ.get('HC_STATE') and value['machines']:
        from pathlib import Path
        counter = Path(state + '.polls')
        n = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(n))
        for m in value['machines']:
            m['state'] = os.environ['HC_STATE']
            if n >= int(os.environ.get('HC_CONNECT_AFTER_POLLS', '99999')):
                m['state'] = 'connected'
    print(json.dumps(value))
elif args[:2] == ['machine', 'add']:
    name, via = args[args.index('--name')+1], args[args.index('--via')+1]
    m = {'name': name, 'via': True, 'target': via, 'session': None, 'state': 'connected'}
    with open(state, 'w') as f:
        json.dump({'machines': [m]}, f)
    print(json.dumps(m))
else:
    sys.exit('unexpected hc invocation: ' + repr(args))
'''


class GuiTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="herdr gui's ")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        for name, script in [('cs', CS), ('hc', HC)]:
            path = self.home / name
            path.write_text(script)
            path.chmod(0o755)
        self.calls = self.home / 'calls.jsonl'
        self.machines = self.home / 'machines.json'
        self.machines.write_text('{"machines": []}')
        self.env = dict(os.environ, CS_BIN=str(self.home / 'cs'),
                        CS_HERDR_HC_BIN=str(self.home / 'hc'),
                        CS_HERDR_HOME=str(self.home / 'state'),
                        CS_HERDR_CONF=str(self.home / 'missing.conf'),
                        CS_HERDR_ORG='default-org', CS_HERDR_FOLDER='default-folder',
                        CALLS=str(self.calls), MACHINES=str(self.machines))

    def run_gui(self, *extra, **env):
        return subprocess.run(['bash', str(ROOT / 'bin/cs-herdr'), 'gui',
                               'sample-app/dev', '--org', 'sample-org', '--folder', 'team-folder',
                               '--no-open', *extra],
                              env=dict(self.env, **env), capture_output=True, timeout=10)

    def history(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_suspended_stale_workload_resumes_and_waits_before_add(self):
        r = self.run_gui('--install', STATE='SUSPENDED')
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = self.history()
        resume = next(i for i, c in enumerate(calls) if 'resume' in c)
        wait = next(i for i, c in enumerate(calls) if 'wait' in c)
        add = next(i for i, c in enumerate(calls) if 'add' in c)
        self.assertLess(resume, wait)
        self.assertLess(wait, add)
        self.assertIn('--wait=false', calls[resume])
        self.assertEqual(calls[wait][-2:], ['--timeout', '90s'])
        self.assertIn('--install', calls[add])
        self.assertNotIn('--temp', calls[add])  # Herdr GUI hides temporary machines.
        self.assertNotIn(b'readiness progress', r.stdout)

    def test_readiness_failure_never_registers_or_installs(self):
        r = self.run_gui('--install', WAIT_FAIL='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(c[0] == 'hc' for c in self.history()))

    def test_resume_failure_never_waits_or_registers(self):
        r = self.run_gui(STATE='SUSPENDED', RESUME_FAIL='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any('wait' in c or c[0] == 'hc' for c in self.history()))

    def test_missing_workspace_never_waits_or_registers(self):
        r = subprocess.run(['bash', str(ROOT / 'bin/cs-herdr'), 'gui',
                            'sample-app/missing', '--no-open'], env=self.env,
                           capture_output=True, timeout=10)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(b'no SSH workspace', r.stderr)
        self.assertEqual(len(self.history()), 1)

    def test_missing_sandbox_never_creates(self):
        r = self.run_gui(MISSING='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(self.history()), 1)

    def test_transport_preserves_scope_remote_line_and_binary_stdio(self):
        folder = "team's tools;$(touch SHOULD_NOT_EXIST)"
        r = self.run_gui('--folder', folder)
        self.assertEqual(r.returncode, 0, r.stderr)
        via = json.loads(self.machines.read_text())['machines'][0]['target']
        data = bytes(range(256)) * 32
        remote = '''sh -c 'printf "$HOME"; echo "quotes \\" and spaces"' '''
        # Same invocation as core, with changed defaults to model a later GUI
        # launch whose environment/config no longer selects this sandbox.
        result = subprocess.run(['sh', '-c', via + ' "$1"', 'sh', remote],
                                input=data, capture_output=True,
                                env=dict(self.env, CS_HERDR_ORG='other-org',
                                         CS_HERDR_FOLDER='other-folder'), timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, data)
        self.assertEqual(result.stderr, b'')
        call = self.history()[-1]
        self.assertEqual(call[:8], ['cs', '-O', 'sample-org', '--folder', folder,
                                   'ssh', '-W', 'sample-app/dev'])
        self.assertEqual(call[-1], remote)
        self.assertIn('-T', call)
        self.assertNotIn('-t', call)
        self.assertIn('BatchMode=yes', call)

    def test_repeat_is_idempotent_and_collision_fails(self):
        self.assertEqual(self.run_gui().returncode, 0)
        self.assertEqual(self.run_gui().returncode, 0)
        self.assertEqual(sum('add' in c for c in self.history()), 1)
        m = json.loads(self.machines.read_text())
        m['machines'][0]['target'] = 'somewhere else'
        self.machines.write_text(json.dumps(m))
        r = self.run_gui()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(b'already points elsewhere', r.stderr)

    def test_invalid_timeout_does_not_contact_sandbox(self):
        r = self.run_gui(CS_HERDR_READY_TIMEOUT='0')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_existing_machine_waits_for_core_reconnect(self):
        self.assertEqual(self.run_gui().returncode, 0)
        r = self.run_gui(HC_STATE='unreachable', HC_CONNECT_AFTER_POLLS='3')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(b'Connected Herdr GUI machine', r.stderr)
        self.assertGreaterEqual(int(Path(str(self.machines) + '.polls').read_text()), 3)
        self.assertEqual(sum('add' in c for c in self.history()), 1)

    def test_existing_unreachable_machine_cannot_report_success(self):
        self.assertEqual(self.run_gui().returncode, 0)
        r = self.run_gui(HC_STATE='unreachable', CS_HERDR_CONNECT_TIMEOUT='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(b'did not connect within 1s', r.stderr)
        self.assertNotIn(b'Connected Herdr GUI machine', r.stderr)

    def test_machine_needing_login_fails_without_waiting_for_timeout(self):
        self.assertEqual(self.run_gui().returncode, 0)
        r = self.run_gui(HC_STATE='needs_login')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(b'needs_login', r.stderr)


if __name__ == '__main__':
    unittest.main()
