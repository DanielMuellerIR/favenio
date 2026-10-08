#!/usr/bin/env python3
"""Sichtbarer Controller-Durchstich mit eigenen Fixtures und bestehendem Bundle."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    assert app.parent == Path('/Applications'), 'Notarisierten installierten Stand prüfen'
    for command in (['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                    ['/usr/sbin/spctl', '--assess', '--type', 'execute', str(app)],
                    ['/usr/bin/xcrun', 'stapler', 'validate', str(app)]):
        checked = subprocess.run(command, capture_output=True, timeout=30)
        assert checked.returncode == 0, checked.stderr.decode('utf8', 'replace')
    listing = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True)
    assert str(app / 'Contents/MacOS/Favenio') not in listing, 'Vorhandene App nicht übernehmen'
    args.evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='favenio-control-smoke-') as temporary:
        root = Path(temporary)
        (root / 'notiz.txt').write_text('Erste Zeile\nCONTROL_PROBE Zweite Zeile\n', encoding='utf8')
        with zipfile.ZipFile(root / 'beispiel.zip', 'w') as archive:
            archive.writestr('ordner/archivnotiz.txt', 'CONTROL_PROBE Archiv\n')
        logfile = root / 'app.log'
        # Nur der eigene Aufklappzustand kann vom Setzen eines Filters geändert
        # werden. Die Probe verwendet keine positiven Filter und keine Vorlagen.
        helper = app / 'Contents/Helpers/favenio-control'
        binding = {}
        report = {}
        offline = subprocess.run([str(helper), '--capabilities', '--json'],
                                 capture_output=True, text=True, timeout=3)
        assert offline.returncode == 0 and json.loads(offline.stdout)['protocolVersion'] == 1
        fifo = root / 'request-fifo'
        os.mkfifo(fifo)
        rejected = subprocess.run([str(helper), '--request', str(fifo)],
                                  capture_output=True, text=True, timeout=3)
        assert rejected.returncode == 1 and json.loads(rejected.stdout)['error']['code'] == 'invalidRequest'
        fifo.unlink()
        oversized = subprocess.run([str(helper), '--request', '-'], input=b' ' * 65_537,
                                   capture_output=True, timeout=3)
        assert oversized.returncode == 1 and json.loads(oversized.stdout)['error']['code'] == 'invalidRequest'
        incomplete = subprocess.Popen([str(helper), '--request', '-'], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            incomplete.wait(timeout=12)
            assert incomplete.returncode == 1 and json.loads(incomplete.stdout.read())['error']['code'] == 'expired'
        finally:
            if incomplete.poll() is None:
                incomplete.kill()
                incomplete.wait()
            incomplete.stdin.close()
            incomplete.stdout.close()
            incomplete.stderr.close()
        with logfile.open('wb') as log:
            child = subprocess.Popen([str(app / 'Contents/MacOS/Favenio'), '--control-test-host'],
                                     stdout=log, stderr=log, start_new_session=True)
        def request(operation, **fields):
            value = dict(version=1, id=str(uuid.uuid4()), deadline=time.time() + 9, operation=operation, **binding)
            value.update(fields)
            return value
        def send(value):
            result = subprocess.run([str(helper), '--no-launch', '--request', '-'],
                                    input=json.dumps(value).encode(), capture_output=True, timeout=12)
            assert result.returncode == 0, result.stdout.decode('utf8', 'replace')
            return json.loads(result.stdout)
        try:
            stop_at = time.monotonic() + 10
            while True:
                result = subprocess.run([str(helper), '--no-launch', '--request', '-'],
                    input=json.dumps(request('capabilities')).encode(), capture_output=True, timeout=12)
                if result.returncode == 0:
                    capabilities = json.loads(result.stdout)
                    break
                assert child.poll() is None and time.monotonic() < stop_at, logfile.read_text()
                time.sleep(.05)
            binding.update(runtimeID=capabilities['runtimeID'], windowID=capabilities['windowID'])
            configuration = dict(pattern='CONTROL_PROBE', root=str(root), options=[
                dict(name='mode', value='content'), dict(name='archives', value='1')])
            assert send(request('configure', configuration=configuration))['configuration']['pattern'] == 'CONTROL_PROBE'
            original_start = request('start')
            started = send(original_start)
            run_id = started['status']['runID']
            assert send(original_start)['status']['runID'] == run_id
            stop_at = time.monotonic() + 10
            while True:
                status = send(request('status'))['status']
                if status['state'] != 'running':
                    break
                assert time.monotonic() < stop_at, status
                time.sleep(.03)
            assert status['state'] == 'completed' and status['complete'], status
            page = send(request('results', runID=run_id, offset=0, limit=1))
            assert len(page['hits']) == 1 and page['count'] == 2 and page['hasMore'], page
            second = send(request('results', runID=run_id, generation=page['generation'], offset=page['nextOffset'], limit=1))
            hits = page['hits'] + second['hits']
            assert {hit['line'] for hit in hits} == {1, 2} and any(hit['archiveMembers'] for hit in hits)
            hit = next(hit for hit in hits if not hit['archiveMembers'])
            identity = {key: hit.get(key, []) for key in ('filesystemPath', 'archiveMembers', 'archiveMemberBytes')}
            send(request('select', runID=run_id, identity=identity))
            selected = send(request('status'))['status']
            assert selected['selection'] == [identity], selected
            # Fenster-ID aus dem echten WindowServer; ausschließlich diesen
            # Prozess abbilden und anschließend sofort wieder ausblenden.
            capture = root / 'capture.swift'
            capture.write_text('''import AppKit
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
guard let app = NSRunningApplication(processIdentifier: pid) else { exit(1) }
app.activate(options: [.activateIgnoringOtherApps])
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let matching = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
guard let window = matching.max(by: {
 let a = $0[kCGWindowBounds as String] as? [String: Double] ?? [:]
 let b = $1[kCGWindowBounds as String] as? [String: Double] ?? [:]
 return (a["Width"] ?? 0) * (a["Height"] ?? 0) < (b["Width"] ?? 0) * (b["Height"] ?? 0)
}), let bounds = window[kCGWindowBounds as String] as? [String: Double],
 let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { app.hide(); exit(1) }
let command = Process()
command.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
command.arguments = ["-R", "\\(Int(x)),\\(Int(y)),\\(Int(width)),\\(Int(height))", "-o", "-x", CommandLine.arguments[2]]
try command.run(); command.waitUntilExit()
app.hide()
let hideDeadline = Date(timeIntervalSinceNow: 1)
while !app.isHidden && Date() < hideDeadline {
 RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
}
print("hidden=\\(app.isHidden) capture=\\(command.terminationStatus)")
exit(command.terminationStatus == 0 && app.isHidden ? 0 : 1)
''')
            def snapshot(name):
                image = args.evidence / name
                captured = subprocess.run(['/usr/bin/swift', str(capture), str(child.pid), str(image)],
                                          capture_output=True, text=True, timeout=30)
                assert captured.returncode == 0 and image.is_file(), captured.stdout + captured.stderr
                return captured.stdout.strip()
            capture_result = snapshot('controller-results.png')
            report.update(productVersion=capabilities['productVersion'], checks=[
                'visible configuration', 'real Python results', 'idempotent start',
                'bounded pages', 'ZIP identity', 'selection by identity',
                'offline capabilities', 'FIFO rejection', 'input byte limit', 'input deadline'], status=selected,
                capture=capture_result)
            # Ein fehlender Ordner muss als fehlgeschlagen erscheinen.
            configuration['root'] = str(root / 'missing')
            send(request('configure', configuration=configuration))
            failed = send(request('start'))['status']
            assert failed['state'] == 'failed' and not failed['complete']
            report['failureCapture'] = snapshot('controller-missing-root.png')
            report['checks'].append('missing-root failure')
            (args.evidence / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
    print('CONTROL SMOKE OK')


if __name__ == '__main__':
    main()
