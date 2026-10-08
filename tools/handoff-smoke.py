#!/usr/bin/env python3
"""Notarisierte Favenio→Fastra-Übergabe mit ausschließlich eigenen Fixtures."""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tarfile
import tempfile
import time
import uuid
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--fastra", type=Path, required=True)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    fastra = args.fastra.resolve()
    assert app.parent == fastra.parent == Path("/Applications")
    for bundle in (app, fastra):
        for command in (["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)],
                        ["/usr/sbin/spctl", "--assess", "--type", "execute", str(bundle)],
                        ["/usr/bin/xcrun", "stapler", "validate", str(bundle)]):
            checked = subprocess.run(command, capture_output=True, timeout=30)
            assert checked.returncode == 0, checked.stderr.decode("utf8", "replace")
    assert str(app / "Contents/MacOS/Favenio") not in subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True)
    args.evidence.mkdir(parents=True, exist_ok=True)
    helper = app / "Contents/Helpers/favenio-control"
    editor = fastra / "Contents/Helpers/fastra-control"
    binding = {}
    own_sessions = set()
    report = {"checks": [], "receipts": []}

    def send(binary, operation, target=None, allow_error=False, **fields):
        request = dict(version=1, id=str(uuid.uuid4()), deadline=time.time() + 9, operation=operation)
        request.update(target or {})
        request.update(fields)
        reply = subprocess.run([str(binary), "--no-launch", "--request", "-"],
                               input=json.dumps(request).encode(), capture_output=True, timeout=12)
        value = json.loads(reply.stdout)
        assert allow_error or reply.returncode == 0, value
        return value

    with tempfile.TemporaryDirectory(prefix="favenio-handoff-smoke-") as temporary:
        root = Path(temporary)
        normal_bytes = b"\xef\xbb\xbf" + "😀 vor\r\nHANDOFF_PROBE Original é\r\n".encode()
        (root / "handoff-original.txt").write_bytes(normal_bytes)
        archive_bytes = b"vor\nHANDOFF_PROBE Archiv\n"
        archive = root / "handoff-archive.zip"
        with zipfile.ZipFile(archive, "w") as zipped:
            zipped.writestr("ordner!/handoff-archive.txt", archive_bytes)
        weak_path = root / "handoff-generation.zip"
        small_zip = io.BytesIO()
        with zipfile.ZipFile(small_zip, "w") as zipped:
            zipped.writestr("handoff-generation.txt", archive_bytes)
        with weak_path.open("wb") as output:
            output.seek(67_108_865)
            output.write(small_zip.getvalue())
        tar_path = root / "handoff-bytes.tar"
        tar_contents = {}
        with tarfile.open(tar_path, "w", encoding="utf8", errors="surrogateescape") as tar:
            for byte in (254, 255):
                name_bytes = b"gleich-" + bytes([byte]) + b".txt"
                data = ("HANDOFF_PROBE Bytes %d\n" % byte).encode()
                member = tarfile.TarInfo(name_bytes.decode("utf8", "surrogateescape"))
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
                tar_contents[base64.b64encode(name_bytes).decode()] = data
        log = root / "app.log"
        with log.open("wb") as output:
            child = subprocess.Popen([str(app / "Contents/MacOS/Favenio"), "--control-test-host"],
                                     stdout=output, stderr=output, start_new_session=True)
        try:
            until = time.monotonic() + 10
            while True:
                capabilities = send(helper, "capabilities", allow_error=True)
                if "error" not in capabilities:
                    break
                assert child.poll() is None and time.monotonic() < until, log.read_text()
                time.sleep(.1)
            binding.update(runtimeID=capabilities["runtimeID"], windowID=capabilities["windowID"])
            report["productVersion"] = capabilities["productVersion"]
            configuration = dict(pattern="HANDOFF_PROBE", root=str(root), options=[
                dict(name="mode", value="content"), dict(name="archives", value="1")])
            send(helper, "configure", binding, configuration=configuration)
            run_id = send(helper, "start", binding)["status"]["runID"]
            until = time.monotonic() + 10
            while send(helper, "status")["status"]["state"] == "running":
                assert time.monotonic() < until
                time.sleep(.05)
            page = send(helper, "results", runID=run_id, offset=0, limit=128)
            hits = page["hits"]
            assert len(hits) == 5 and not page["hasMore"], page
            cases = [(next(hit for hit in hits if not hit["archiveMembers"]), normal_bytes, "original")]
            zip_hit = next(hit for hit in hits if hit["filesystemPath"] == str(archive))
            cases.append((zip_hit, archive_bytes, "archive"))
            cases.append((next(hit for hit in hits if hit["filesystemPath"] == str(weak_path)), archive_bytes, "generation"))
            for hit in hits:
                if hit["filesystemPath"] == str(tar_path):
                    cases.append((hit, tar_contents[hit["archiveMemberBytes"][0]], "bytes-" + str(tar_contents[hit["archiveMemberBytes"][0]].split()[-1].decode())))

            def snapshot(pid, title, name):
                target = args.evidence / (name + ".png")
                result = subprocess.run([str(args.capture), str(pid), title, str(target)], capture_output=True, timeout=10)
                assert result.returncode == 0 and target.is_file(), (result.returncode, result.stderr)

            def handoff(hit, data, name):
                identity = {key: hit.get(key, []) for key in ("filesystemPath", "archiveMembers", "archiveMemberBytes")}
                send(helper, "select", binding, runID=run_id, identity=identity)
                started = send(helper, "handoff", binding, runID=run_id, identity=identity)["handoff"]
                until = time.monotonic() + 32
                while True:
                    value = send(helper, "handoffStatus", jobID=started["id"])["handoff"]
                    if value["state"] in ("ready", "failed", "cancelled"):
                        break
                    assert time.monotonic() < until, value
                    time.sleep(.05)
                assert value["state"] == "ready", value
                receipt = value["fastra"]
                own_sessions.add(receipt["sessionID"])
                assert receipt["adopted"] and receipt["sha256"] == hashlib.sha256(data).hexdigest(), receipt
                assert receipt["provenance"]["hitIdentity"] == identity
                assert receipt["provenance"]["positionBinding"] == "exactUTF16"
                expected_binding = "generation" if name == "generation" else ("sha256" if hit["archiveMembers"] else "notApplicable")
                assert receipt["provenance"]["archiveBinding"] == expected_binding
                editor_capabilities = send(editor, "capabilities")
                objects = send(editor, "objects", dict(runtimeID=editor_capabilities["runtimeID"]))["objects"]
                session = next(item for item in objects if item["id"] == receipt["sessionID"])
                document = next(item for item in objects if item["id"] == receipt["documentID"])
                assert session["sha256"] == receipt["sha256"]
                assert document["sha256"] == receipt["sha256"] and document["selection"] == receipt["selection"]
                pids = subprocess.check_output(["/usr/bin/pgrep", "-x", "Fastra"], text=True).split()
                assert len(pids) == 1, pids
                snapshot(int(pids[0]), session["name"], "fastra-" + name)
                snapshot(child.pid, "Favenio", "favenio-" + name)
                report["receipts"].append(value)
                report["checks"].append(name)
                return receipt

            for hit, data, name in cases:
                receipt = handoff(hit, data, name)
                # Gleichnamige TAR-Sitzungen einzeln aufnehmen und schließen.
                if name.startswith("bytes-"):
                    cap = send(editor, "capabilities")
                    send(editor, "close", dict(runtimeID=cap["runtimeID"]), sessionID=receipt["sessionID"])
                    own_sessions.remove(receipt["sessionID"])
            later = b"neu davor\n\nHANDOFF_PROBE Aktuelles Archiv\n"
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("ordner!/handoff-archive.txt", later)
            receipt = handoff(zip_hit, later, "changed-archive")
            assert receipt["selection"]["location"] == 11
            quit_app = subprocess.run([str(args.capture), "--terminate", str(child.pid)], capture_output=True, timeout=2)
            assert quit_app.returncode == 0, quit_app.stderr
            child.wait(timeout=8)
            cap = send(editor, "capabilities")
            objects = send(editor, "objects", dict(runtimeID=cap["runtimeID"]))["objects"]
            for session_id in own_sessions:
                assert any(item["id"] == session_id for item in objects), objects
            pids = subprocess.check_output(["/usr/bin/pgrep", "-x", "Fastra"], text=True).split()
            own = next(item for item in objects if item["id"] == receipt["sessionID"])
            snapshot(int(pids[0]), own["name"], "fastra-after-favenio-exit")
            report["checks"].append("Fastra copy survives Favenio exit")
            (args.evidence / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait()
            for session_id in own_sessions:
                cap = send(editor, "capabilities", allow_error=True)
                if "runtimeID" in cap:
                    send(editor, "close", dict(runtimeID=cap["runtimeID"]), allow_error=True, sessionID=session_id)
    print("HANDOFF SMOKE OK")


if __name__ == "__main__":
    main()
