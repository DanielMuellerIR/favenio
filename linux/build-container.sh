#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:-debug}
[[ "$mode" == debug || "$mode" == release || "$mode" == package || "$mode" == check ]] || { echo 'Aufruf: linux/build-container.sh [debug|release|package|check]' >&2; exit 2; }
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Den Containerbau auf einem Linux-x86-64-Host ausführen.' >&2; exit 2; }
image=favenio-linux-builder:6.2.1-1.99.1
cache=${FAVENIO_BUILD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/favenio-build}
mkdir -p "$cache/cargo" "$cache/target"
docker build --platform linux/amd64 -t "$image" -f "$repo/linux/Dockerfile" "$repo/linux"
case "$mode" in
    package) command=(bash linux/package.sh) ;;
    check) command=(bash -e -c '
        bash linux/build.sh debug
        export FAVENIO_SHARED_LIBRARY="$PWD/.build/linux/libfavenio-shared.so"
        export FAVENIO_ENGINE="$PWD/.build/linux/favenio.py"
        export LD_LIBRARY_PATH="$PWD/.build/linux/swift"
        python3 tests/linux_shared_probe.py
    ') ;;
    *) command=(bash linux/build.sh "$mode") ;;
esac
exec docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" \
    -v "$repo:/src" -v "$cache:/cache" -e CARGO_HOME=/cache/cargo \
    -e CARGO_TARGET_DIR=/cache/target -w /src "$image" "${command[@]}"
