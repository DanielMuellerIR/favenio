#!/usr/bin/env bash
set -euo pipefail
out=${1:?Ausgabeordner fehlt}
mkdir -p "$out/swift"
ldd "$out/libfavenio-shared.so" | while read -r name arrow resolved rest; do
    case "$resolved" in /usr/lib/swift/linux/*) cp "$resolved" "$out/swift/" ;; esac
done
# libFoundationInternationalization lädt ICU innerhalb der privaten Swift-Laufzeit.
cp /usr/lib/swift/linux/lib_FoundationICU.so "$out/swift/"
