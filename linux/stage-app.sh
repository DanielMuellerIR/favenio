#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
binary=${1:?Rust-Programmdatei fehlt}
out=${2:?Ausgabeordner fehlt}
python3 -B "$repo/linux/extract-icons.py" "$repo/icons" "$out/icons"
mkdir -p "$out/helpers" "$out/update" "$out/integration" "$out/licenses"
cp "$binary" "$out/favenio"
cp "$repo/favenio.py" "$repo/linux/launch" "$repo/linux/install.py" "$repo/linux/uninstall.py" "$out/"
cp "$repo/linux/helpers/"* "$out/helpers/"
cp "$repo/linux/update/coordinator.py" "$out/update/"
cp "$repo/common/update-public-key.txt" "$out/update/public-key.txt"
cp "$repo/linux/integration/"* "$out/integration/"
cp "$repo/LICENSE" "$out/licenses/Favenio-MIT.txt"
cp "$repo/linux/licenses/"* "$out/licenses/"
python3 -B "$repo/favenio.py" --version | awk '{print $2}' > "$out/VERSION"
