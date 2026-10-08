#!/usr/bin/env python3
"""Native Wiederöffnung und Neusuche mit begrenzten eigenen Testdateien."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--tool', type=Path, required=True)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    assert app.parent == Path('/Applications')
    for command in (['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                    ['/usr/sbin/spctl', '--assess', '--type', 'execute', str(app)],
                    ['/usr/bin/xcrun', 'stapler', 'validate', str(app)]):
        result = subprocess.run(command, capture_output=True, timeout=30)
        assert result.returncode == 0, result.stderr.decode('utf8', 'replace')
    assert str(app / 'Contents/MacOS/Favenio') not in subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True)
    args.evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='favenio-recording-smoke-') as temporary:
        root = Path(temporary)
        first = root / 'recording-first.txt'
        second = root / 'recording-second.txt'
        first.write_text('RECORDING_PROBE Erste Datei\n')
        second.write_text('RECORDING_PROBE Zweite Datei\n')
        helper = app / 'Contents/Helpers/favenio-control'
        binding = {}
        def send(operation, allow_error=False, **fields):
            value = dict(version=1, id=str(uuid.uuid4()), deadline=time.time() + 9,
                         operation=operation, **binding, **fields)
            result = subprocess.run([str(helper), '--no-launch', '--request', '-'],
                                    input=json.dumps(value).encode(), capture_output=True, timeout=12)
            reply = json.loads(result.stdout)
            assert allow_error or result.returncode == 0, reply
            return reply
        def tool(command, file, *extra, success=True):
            result = subprocess.run(['/usr/bin/python3', str(args.tool), '--helper', str(helper),
                                     command, str(file), *map(str, extra)], capture_output=True, timeout=70)
            assert (result.returncode == 0) == success, result.stderr.decode('utf8', 'replace')
            return result
        def wait(run_id):
            stop = time.monotonic() + 15
            while True:
                status = send('status')['status']
                assert status['runID'] == run_id
                if status['state'] != 'running':
                    return status
                assert time.monotonic() < stop
                time.sleep(.1)
        with (root / 'app.log').open('wb') as output:
            child = subprocess.Popen([str(app / 'Contents/MacOS/Favenio'), '--control-test-host'],
                                     stdout=output, stderr=output, start_new_session=True)
        try:
            stop = time.monotonic() + 15
            while True:
                try:
                    caps = send('capabilities')
                    break
                except (AssertionError, json.JSONDecodeError):
                    assert child.poll() is None and time.monotonic() < stop
                    time.sleep(.1)
            binding.update({key: caps[key] for key in ('runtimeID', 'windowID')})
            configuration = dict(pattern='RECORDING_PROBE', root=str(root), options=[dict(name='mode', value='content')])
            send('configure', configuration=configuration)
            run_id = send('start')['status']['runID']
            assert wait(run_id)['count'] == 2
            rows = send('results', runID=run_id, offset=0, limit=128)['hits']
            hit = next(h for h in rows if h['filesystemPath'] == str(second))
            identity = {key: hit.get(key, []) for key in ('filesystemPath', 'archiveMembers', 'archiveMemberBytes')}
            send('select', runID=run_id, identity=identity)
            saved = args.evidence / 'recording.json'
            tool('record', saved)
            identity_file = root / 'identity.json'
            identity_file.write_text(json.dumps(identity))
            tool('append-action', saved, 'select', identity_file)
            original_bytes = saved.read_bytes()
            second.unlink()
            tool('open', saved, '--actions')
            opened = send('status')['status']
            assert opened['count'] == 2 and opened['origin'] == 'recording' and opened['runID'] != run_id
            assert opened['selection'] == [identity] and opened['recordedSource']['runID'] == run_id
            assert send('select', allow_error=True, runID=run_id, identity=identity)['error']['code'] == 'stale'
            subprocess.run([str(args.capture), str(child.pid), 'Favenio', str(args.evidence / 'recorded.png')], check=True, timeout=15)
            tool('rerun', saved)
            fresh = send('status')['status']
            assert fresh['count'] == 1 and fresh['origin'] == 'live' and fresh['runID'] != opened['runID']
            assert fresh['startedAt'] > opened['recordedSource']['startedAt']
            assert saved.read_bytes() == original_bytes
            assert send('select', allow_error=True, runID=fresh['runID'], identity=identity)['error']['code'] == 'missingHit'
            subprocess.run([str(args.capture), str(child.pid), 'Favenio', str(args.evidence / 'rerun.png')], check=True, timeout=15)
            tool('rerun', saved, '--actions', success=False)
            assert saved.read_bytes() == original_bytes
            (args.evidence / 'result.json').write_text(json.dumps(dict(version=caps['productVersion'],
                checks=['record full state', 'record selection action', 'open without new search', 'preserve historical missing file',
                        'invalidate old run', 'rerun with new run/time', 'missing replay hit fails', 'recording remains unchanged'],
                opened=opened, rerun=fresh), ensure_ascii=False, indent=2) + '\n')
            print('RECORDING SMOKE OK')
        finally:
            if child.poll() is None:
                subprocess.run([str(args.capture), '--terminate', str(child.pid)], check=True, timeout=15)
                try:
                    child.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGTERM)
                    child.wait(timeout=5)


if __name__ == '__main__':
    main()
