#!/usr/bin/env python3
"""Zwei Archiv-Optimierungen isoliert vergleichen, ohne den Kern zu ändern."""

import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import resource
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time


REPETITIONS = 3
LARGE_BUDGET = "1000000000"
SUMMARY_NAME = "archive-search-summary.jsonl"
RESULTS_NAME = "archive-search-results.json"
ENVIRONMENT_NAME = "archive-search-environment.json"


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def repository_roots(source):
    """Auch eine per git show gespeicherte Quelle darf nicht ins Repo schreiben."""
    roots = set()
    for start in (source.parent, Path.cwd(), Path(__file__).resolve().parent):
        for candidate in (start, *start.parents):
            if (candidate / ".git").exists():
                roots.add(candidate.resolve())
                break
    return roots


def prepare_output(source, requested):
    """Nur ein neues oder leeres Verzeichnis außerhalb des Repositorys nutzen."""
    if requested is None:
        output = Path(tempfile.mkdtemp(prefix="favenio-archive-bench-"))
    else:
        output = requested.resolve()
    for root in repository_roots(source):
        if os.path.commonpath((str(root), str(output))) == str(root):
            raise ValueError("Das Ausgabeverzeichnis muss außerhalb des Repositorys liegen.")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError("Das Ausgabeverzeichnis muss neu oder leer sein.")
    output.mkdir(parents=True, exist_ok=True)
    return output


def copy_variants(source, output):
    """Je Experiment genau einen Anker ersetzen; bei Codeänderungen klar abbrechen."""
    text = source.read_text(encoding="utf-8")
    tar_anchor = "for member in archive.getmembers():"
    probe_anchor = "if self.content_probe is None:"
    for anchor in (tar_anchor, probe_anchor):
        if text.count(anchor) != 1:
            raise ValueError(
                "Die Quelle passt nicht zum Experiment: genau ein Vorkommen von "
                + repr(anchor) + " erwartet. Die dokumentierte Basis per git show verwenden."
            )
    variants = {
        "base": text,
        "tariter": text.replace(tar_anchor, "for member in archive:"),
        "noprobe": text.replace(probe_anchor, "if True:"),
    }
    for name, content in variants.items():
        (output / (name + ".py")).write_text(content, encoding="utf-8")
    write_json(output / ENVIRONMENT_NAME, {
        "python": sys.version,
        "platform": platform.system(),
        "source_sha256": hashlib.sha256(text.encode()).hexdigest(),
        "repetitions": REPETITIONS,
        "timing": "perf_counter: main entry to first emit / main return; interpreter startup excluded",
        "rss": "ru_maxrss SELF and CHILDREN separately; bytes on macOS",
    })


def short_lines(size):
    line = b"0123456789 abcdefghijklmnopqrstuvwxyz\n"
    return (line * (size // len(line) + 1))[:size]


def write_tar(path, count, size, compressed):
    mode = "w:gz" if compressed else "w"
    with tarfile.open(path, mode) as archive:
        for index in range(count):
            content = short_lines(size)
            if index == 0:
                content = b"EARLY\n" + content[6:]
            if index == count - 1:
                content = content[:-6] + b"\nLATE\n"
            member = tarfile.TarInfo("file-%05d.txt" % index)
            member.size = len(content)
            member.mtime = 1234567890
            archive.addfile(member, io.BytesIO(content))


def make_case(backend, archive, mode, pattern, label, budget=LARGE_BUDGET):
    return {
        "backend": backend,
        "archive": str(archive),
        "mode": mode,
        "pattern": pattern,
        "budget": budget,
        "label": label,
    }


def tar_cases(output):
    cases = []
    for count, size in ((3000, 4096), (200, 262144)):
        for suffix in ("tar", "tar.gz"):
            path = output / ("many-%d-%d.%s" % (count, size, suffix))
            write_tar(path, count, size, compressed=suffix.endswith("gz"))
            label = "%s-%d-%d" % (suffix, count, size)
            for where, pattern in (("early", "EARLY"), ("late", "LATE"), ("missing", "MISSING")):
                cases.append(make_case("tar", path, "content", pattern, label + "-" + where))
            names = (("early", "file-00000.txt"), ("late", "file-%05d.txt" % (count - 1)), ("missing", "absent"))
            for where, pattern in names:
                cases.append(make_case("tar", path, "name", pattern, label + "-name-" + where))
    return cases


def bsdtar_cases(output):
    cases = []
    for size in (4096, 1048576, 16777216):
        for where in ("early", "late", "missing"):
            label = "single-%d-%s" % (size, where)
            folder = output / label
            folder.mkdir()
            content = short_lines(size)
            if where == "early":
                content = b"NEEDLE\n" + content[7:]
            if where == "late":
                content = content[:-8] + b"\nNEEDLE\n"
            (folder / "data.txt").write_bytes(content)
            path = output / (label + ".7z")
            subprocess.run([
                "/usr/bin/tar", "-cf", str(path), "--format", "7zip",
                "-C", str(folder), "data.txt",
            ], check=True)
            cases.append(make_case("bsdtar", path, "content", "NEEDLE", label))
            if size == 1048576:
                cases.append(make_case("bsdtar", path, "content", "NEEDLE", label + "-budget", "65536"))
    return cases


def exceptional_cases(output):
    # Der Folgeteil ist beschädigt, obwohl der erste Eintrag vollständig lesbar ist.
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for name, content in (("first.txt", b"NEEDLE\n"), ("late.txt", b"other\n" * 1000)):
            member = tarfile.TarInfo(name)
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
    path = output / "broken.tar"
    path.write_bytes(buffer.getvalue()[:1600])
    cases = [make_case("tar", path, "content", "NEEDLE", "corrupt-tar")]
    for suffix in ("tar", "tar.gz"):
        path = output / ("many-3000-4096." + suffix)
        for pattern in ("EARLY", "LATE", "MISSING"):
            label = suffix + "-budget-" + pattern.lower()
            cases.append(make_case("tar", path, "content", pattern, label, "65536"))
    return cases


def worker(output, variant, case):
    """Ein frischer Prozess liefert Messwerte und unveränderte Ausgaben."""
    spec = importlib.util.spec_from_file_location("favenio", output / (variant + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    first_hit = None
    started = None
    original_emit = module.Search.emit

    def timed_emit(search, *args, **kwargs):
        nonlocal first_hit
        if first_hit is None:
            first_hit = time.perf_counter() - started
        return original_emit(search, *args, **kwargs)

    module.Search.emit = timed_emit
    arguments = [
        "--json", "--max-archive-member-bytes", LARGE_BUDGET,
        "--max-archive-total-bytes", case["budget"],
        case["pattern"], case["archive"],
    ]
    if case["mode"] == "content":
        arguments.insert(0, "--content")
    stdout = io.StringIO()
    stderr = io.StringIO()
    started = time.perf_counter()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        code = module.main(arguments)
    result = {
        "first": first_hit,
        "total": time.perf_counter() - started,
        "rss": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "childrss": resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
        "code": code,
        "hits": stdout.getvalue().replace(str(output), "$BENCH"),
        "warnings": stderr.getvalue().replace(str(output), "$BENCH"),
    }
    print(json.dumps(result))


def compact_outputs(runs):
    """Erst nach exaktem Vergleich kürzen: Budgetwarnungen sind oft sehr zahlreich."""
    for variant_runs in runs.values():
        for result in variant_runs:
            for field in ("hits", "warnings"):
                value = result.pop(field)
                lines = value.splitlines()
                result[field + "_sha256"] = hashlib.sha256(value.encode()).hexdigest()
                result[field + "_count"] = len(lines)
                result[field + "_sample"] = lines[:2]


def measure_case(output, case):
    variant = "tariter" if case["backend"] == "tar" else "noprobe"
    variants = ("base", variant)
    runs = {name: [] for name in variants}
    for repeat in range(REPETITIONS):
        order = variants if repeat % 2 == 0 else tuple(reversed(variants))
        for name in order:
            process = subprocess.run([
                sys.executable, str(Path(__file__).resolve()), "--worker",
                str(output), name, json.dumps(case),
            ], capture_output=True, text=True, check=True)
            runs[name].append(json.loads(process.stdout))
    signatures = {
        (result["code"], result["hits"], result["warnings"])
        for variant_runs in runs.values() for result in variant_runs
    }
    equivalent = len(signatures) == 1
    summary = {"case": case["label"], "equivalent": equivalent}
    for name, variant_runs in runs.items():
        medians = {}
        for field in ("first", "total", "rss", "childrss"):
            values = [result[field] for result in variant_runs if result[field] is not None]
            medians[field] = statistics.median(values) if values else None
        summary[name] = medians
    compact_outputs(runs)
    return {"case": case["label"], "equivalent": equivalent, "runs": runs}, summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path.cwd() / "favenio.py")
    parser.add_argument("--output-dir", type=Path)
    options = parser.parse_args()
    source = options.source.resolve()
    try:
        output = prepare_output(source, options.output_dir)
        copy_variants(source, output)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print("Benchmark-Ausgaben: " + str(output), file=sys.stderr)
    cases = tar_cases(output) + bsdtar_cases(output) + exceptional_cases(output)
    results = []
    with (output / SUMMARY_NAME).open("w", encoding="utf-8") as summary_file:
        for case in cases:
            result, summary = measure_case(output, case)
            results.append(result)
            line = json.dumps(summary)
            print(line, flush=True)
            summary_file.write(line + "\n")
            summary_file.flush()
            write_json(output / RESULTS_NAME, results)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        worker(Path(sys.argv[2]), sys.argv[3], json.loads(sys.argv[4]))
    else:
        main()
