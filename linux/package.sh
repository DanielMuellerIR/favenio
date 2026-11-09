#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Auf Linux x86_64 bauen.' >&2; exit 2; }
version=$(python3 -B "$repo/favenio.py" --version | awk '{print $2}')
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
out="$repo/dist/linux/favenio-$version"
mkdir -p "$out/helpers" "$out/update" "$out/integration" "$out/licenses"
"$repo/linux/shared/build.sh" "$out"
"$repo/linux/shared/stage-runtime.sh" "$out"
cargo build --manifest-path "$repo/linux/Cargo.toml" --locked --release
"$repo/linux/stage-app.sh" "${CARGO_TARGET_DIR:-$repo/linux/target}/release/favenio-linux" "$out"
python3 -B "$repo/linux/collect-licenses.py" "$out/licenses/rust"
"$out/launch" --self-test
python3 -B - "$repo" "$out" <<'PY'
import gzip, os, pathlib, sys, tarfile
repo, output = map(pathlib.Path,sys.argv[1:])
def portable(member):
    if '__pycache__' in member.name or member.name.endswith('.pyc'): return None
    member.uid = member.gid = 0
    member.uname = member.gname = ''
    member.mtime = 0
    return member
with open(str(output)+'.tar.gz','wb') as target, gzip.GzipFile(filename='', mode='wb', fileobj=target, mtime=0) as compressed:
    with tarfile.open(fileobj=compressed,mode='w',dereference=True) as archive:
        archive.add(output,arcname=output.name,filter=portable)
print('PACKAGE OK: '+str(pathlib.Path(str(output)+'.tar.gz')))
PY
