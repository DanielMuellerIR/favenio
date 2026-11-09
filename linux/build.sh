#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
profile=${1:-debug}
[[ "$profile" == debug || "$profile" == release ]] || { echo 'Aufruf: linux/build.sh [debug|release]' >&2; exit 2; }
command -v swiftc >/dev/null || { echo 'Swift 6.2 oder neuer fehlt.' >&2; exit 2; }
pkg-config --atleast-version=4.14 gtk4 || { echo 'GTK4-Entwicklungspakete ab 4.14 fehlen.' >&2; exit 2; }
"$repo/linux/shared/build.sh"
args=()
[[ "$profile" == release ]] && args+=(--release)
cargo build --locked --manifest-path "$repo/linux/Cargo.toml" "${args[@]}"
"$repo/linux/shared/stage-runtime.sh" "$repo/.build/linux"
"$repo/linux/stage-app.sh" "${CARGO_TARGET_DIR:-$repo/linux/target}/$profile/favenio-linux" "$repo/.build/linux"
"$repo/.build/linux/launch" --self-test
printf 'BUILD OK: %s\n' "$repo/.build/linux/launch"
