#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$repo/.build/linux}
mkdir -p "$out"
exec swiftc -swift-version 5 ${FAVENIO_SWIFT_OPTIMIZATION:--O} -emit-library -I "$repo/linux/shared" \
  "$repo"/common/{RegexTemplates,FastraHandoffModel,ControlModel,RecordingModel,DuplicateModel,ResultFilterModel,CriteriaModel,SearchModel,SearchConfiguration,SearchProcess,ContentPreviewLoad,ContentModel,DateRangeModel,SearchReportModel,FinderMetadata}.swift \
  "$repo/linux/shared/Platform.swift" "$repo/linux/shared/FastraTransport.swift" "$repo/linux/shared/Bridge.swift" \
  "$repo/control/ControlProtocol.swift" -Xlinker -l:libcrypto.so.3 -o "$out/libfavenio-shared.so"
