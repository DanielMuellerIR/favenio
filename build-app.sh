#!/bin/zsh
# Baut die beiden macOS-Apps von Favenio:
#   Favenio.app       — große GUI (Trefferliste, Öffnen mit, Drag & Drop)
#   FavenioQuick.app  — Mini-Schnellsuche für die Finder-Toolbar
#
# Beide Bundles bekommen eine Kopie von favenio.py in ihre Resources —
# der Python-Kern ist der einzige Suchmotor, die Apps sind nur Frontends.
# Der Build prüft Produkt-Bundles und separate Selbsttests. Die Apps bleiben im
# Projektverzeichnis: Ein Build ist keine Installation und darf eine
# notarisierten Produktinstallation unter /Applications niemals ersetzen.
#
# Aufruf:  ./build-app.sh
#
# Für den echten Sparkle-E2E-Test darf ausschließlich CFBundleVersion
# vorübergehend kleiner gebaut werden:
#   FAVENIO_SPARKLE_TEST_VERSION=0.13.9 ./build-app.sh
# release.sh verweigert solche Test-Builds ausdrücklich.
set -euo pipefail
cd "$(dirname "$0")"

# Version + Datum aus dem Python-Kern lesen — eine einzige Versions-Quelle.
VERSION=$(/usr/bin/python3 -c "import favenio; print(favenio.__version__)")
DATE=$(/usr/bin/python3 -c "import favenio; print(getattr(favenio, '__date__', ''))")
BUNDLE_VERSION="${FAVENIO_SPARKLE_TEST_VERSION:-$VERSION}"
PRODUCTION_FEED_URL=$(cat common/update-feed-url.txt)
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-$PRODUCTION_FEED_URL}"
SPARKLE_PUBLIC_KEY=$(cat common/update-public-key.txt)
if [[ -z "$PRODUCTION_FEED_URL" || -z "$SPARKLE_PUBLIC_KEY" ]]; then
    echo "FEHLER: Produktions-Update-Kanal ist unvollständig." >&2
    exit 1
fi
echo "Baue Favenio $VERSION ($DATE), Bundle-Version $BUNDLE_VERSION …"

# Sparkle exakt gemäß Package.resolved auflösen. SwiftPM verpackt Binär-Targets
# bei einem handgebauten App-Bundle nicht selbst; das Framework wird unten
# bewusst nach Contents/Frameworks kopiert.
swift package resolve
SPARKLE_SOURCE=$(find .build/artifacts/sparkle -type d \
    -name Sparkle.framework -print -quit 2>/dev/null || true)
SPARKLE_LICENSE=$(find .build/artifacts/sparkle -type f \
    -name LICENSE -print -quit 2>/dev/null || true)
if [ -z "$SPARKLE_SOURCE" ] || [ -z "$SPARKLE_LICENSE" ]; then
    echo "FEHLER: Sparkle-Framework oder Lizenz fehlt nach SwiftPM-Auflösung." >&2
    exit 1
fi
SPARKLE_SEARCH_PATH=$(dirname "$SPARKLE_SOURCE")

# Beides in eine Swift-Konstante gießen (von beiden Apps mitkompiliert),
# damit die Fenstertitel Version + Datum ohne Python-Aufruf zur Laufzeit
# zeigen. Datei ist git-ignoriert (generiert).
cat > common/Version.swift <<EOF
// AUTO-GENERIERT von build-app.sh aus favenio.py — nicht von Hand editieren.
let favenioVersion = "${VERSION}"
let favenioDate = "${DATE}"
let favenioSparklePublicKey = "${SPARKLE_PUBLIC_KEY}"
EOF

# Stabile Code-Signatur wählen. Mit einer Developer-ID-Identität behält
# macOS/TCC die Freigaben (Festplattenvollzugriff, Finder-Automation) über
# Builds hinweg — Ad-hoc (-s -) ändert bei JEDEM Build den cdhash und setzt
# alle Freigaben zurück. Identität automatisch aus der Login-Keychain lesen
# (überschreibbar per FAVENIO_SIGN_ID); ohne Developer-ID Rückfall auf Ad-hoc.
# --options runtime (Hardened Runtime) ist Pflicht für die Notarisierung und
# wird deshalb bei Developer-ID-Builds gesetzt. Ad-hoc-signierte App und
# Framework haben keine gemeinsame Team-ID; mit Hardened Runtime würde macOS
# das Framework beim Start ablehnen. Der lokale/CI-Fallback bleibt deshalb
# bewusst ohne Hardened Runtime und ist nicht für Releases geeignet.
# Das Automation-Entitlement wird in beiden Fällen mitgegeben.
SIGN_ID="${FAVENIO_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    # `|| true`: Ohne Developer-ID (z. B. auf CI-Runnern) findet grep nichts
    # und würde die Pipeline unter `set -euo pipefail` das Skript abbrechen,
    # bevor der Ad-hoc-Fallback unten greifen kann.
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/^[^"]*"([^"]*)".*/\1/' || true)
fi
if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
    NESTED_SIGN=(--force --options runtime --timestamp --sign "$SIGN_ID")
    APP_SIGN=(--force --options runtime --timestamp \
          --entitlements assets/favenio.entitlements --sign "$SIGN_ID")
    echo "Signiere mit stabiler Identität: $SIGN_ID"
else
    NESTED_SIGN=(--force --sign -)
    APP_SIGN=(--force --entitlements assets/favenio.entitlements --sign -)
    echo "WARNUNG: keine Developer-ID gefunden → Ad-hoc-Signatur " \
         "(TCC-Freigaben überleben KEINEN Rebuild)."
fi

# Sparkle enthält eigene Signaturgrenzen. Immer innen nach außen signieren;
# `--deep` wäre zum Erzeugen der Signatur falsch.
sign_sparkle_framework() {
    local framework="$1"
    codesign "${NESTED_SIGN[@]}" \
        "$framework/Versions/B/Autoupdate"
    codesign "${NESTED_SIGN[@]}" \
        "$framework/Versions/B/Updater.app"
    codesign "${NESTED_SIGN[@]}" "$framework"
}

embed_sparkle_and_licenses() {
    local app="$1"
    local framework="$app/Contents/Frameworks/Sparkle.framework"
    ditto "$SPARKLE_SOURCE" "$framework"
    # Favenio ist nicht sandboxed; Sparkles XPC-Dienste sind nicht aktiviert.
    # Ohne sie bleibt das Bundle kleiner und die Signierfläche enger.
    rm -rf "$framework/Versions/B/XPCServices" "$framework/XPCServices"
    cp THIRD-PARTY.md "$app/Contents/Resources/Third-Party.md"
    cp "$SPARKLE_LICENSE" \
        "$app/Contents/Resources/Sparkle-LICENSE.txt"
    sign_sparkle_framework "$framework"
}

set_sparkle_feed_url() {
    local app="$1"
    # Die dokumentiert überschreibbare URL kann XML-Zeichen wie `&`
    # enthalten. plutil serialisiert sie sicher; rohe Interpolation in das
    # Here-Dokument würde eine ungültige Info.plist erzeugen.
    /usr/bin/plutil -replace SUFeedURL -string "$SPARKLE_FEED_URL" \
        "$app/Contents/Info.plist"
}

# Deployment-Target festnageln: Ohne -target erbt das Binary das macOS der
# Build-Maschine als Minimum (LC_BUILD_VERSION minos) und startet auf älteren
# Systemen gar nicht — LSMinimumSystemVersion im Info.plist ändert daran nichts.
# macOS 12 ist das echte Minimum: urlsForApplications(toOpen:) („Öffnen mit"-
# Menü) und die im System enthaltene Swift-Concurrency-Runtime brauchen es.
TARGET="arm64-apple-macos12.0"

MAC_SOURCES=(
    common/DuplicateModel.swift common/ResultFilterModel.swift common/CriteriaModel.swift
    common/SearchModel.swift common/HitPresentation.swift common/SearchConfiguration.swift common/SearchProcess.swift
    common/ContentModel.swift common/ContentPreviewLoad.swift common/DateRangeModel.swift
    common/SearchReportModel.swift common/RegexTemplates.swift common/FavenioCore.swift
    common/UpdateSupport.swift
    common/SearchReport.swift common/ContentPreview.swift common/Thumbnails.swift
    common/DuplicateCheck.swift common/Version.swift common/CriteriaEditor.swift
    common/DateRanges.swift common/FinderMetadata.swift common/FinderScope.swift
)
MAIN_SOURCES=(
    control/ControlProtocol.swift common/ControlModel.swift common/RecordingModel.swift
    common/FastraHandoffModel.swift gui/SearchControl.swift gui/SearchRecording.swift
    gui/FastraHandoff.swift gui/FavenioGUI.swift
)

compile_frontend() {
    local binary="$1"
    shift
    swiftc -target "$TARGET" -F "$SPARKLE_SEARCH_PATH" -framework Sparkle \
        -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
        "${MAC_SOURCES[@]}" "$@" -o "$binary"
}

# ---------- Favenio.app (große GUI) ----------
rm -rf Favenio.app
mkdir -p Favenio.app/Contents/MacOS Favenio.app/Contents/Resources \
    Favenio.app/Contents/Frameworks
compile_frontend Favenio.app/Contents/MacOS/Favenio -O "${MAIN_SOURCES[@]}"
mkdir -p Favenio.app/Contents/Helpers
swiftc -O -target "$TARGET" control/ControlProtocol.swift control/main.swift \
    -o Favenio.app/Contents/Helpers/favenio-control
codesign "${NESTED_SIGN[@]}" Favenio.app/Contents/Helpers/favenio-control
mkdir -p .build
DOCUMENT_LIMITS=.build/DocumentHelperLimits.swift
/usr/bin/python3 -B tools/generate-document-limits.py "$DOCUMENT_LIMITS"
swiftc -O -target "$TARGET" "$DOCUMENT_LIMITS" ocr/DocumentHelperIO.swift ocr/VisionText.swift \
    pdf/main.swift -o .build/favenio-pdf
cp .build/favenio-pdf Favenio.app/Contents/Helpers/favenio-pdf
codesign "${NESTED_SIGN[@]}" Favenio.app/Contents/Helpers/favenio-pdf
swiftc -O -target "$TARGET" "$DOCUMENT_LIMITS" ocr/DocumentHelperIO.swift ocr/VisionText.swift \
    ocr/main.swift -o .build/favenio-ocr
cp .build/favenio-ocr Favenio.app/Contents/Helpers/favenio-ocr
codesign "${NESTED_SIGN[@]}" Favenio.app/Contents/Helpers/favenio-ocr
cp favenio.py Favenio.app/Contents/Resources/
# App-Icon (vorgefertigt eingecheckt; neu erzeugen: swift icons/make-icons.swift
# + iconutil — siehe icons/make-icons.swift).
cp icons/Favenio.icns Favenio.app/Contents/Resources/
cat > Favenio.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Favenio</string>
    <key>CFBundleIdentifier</key><string>local.favenio</string>
    <key>FavenioQuickHandoffVersion</key><integer>9</integer>
    <key>FavenioDateRangeSchemaVersion</key><integer>1</integer>
    <key>FavenioFinderMetadataSchemaVersion</key><integer>1</integer>
    <key>FavenioLocalContentSchemaVersion</key><integer>1</integer>
    <key>FavenioOCRSchemaVersion</key><integer>1</integer>
    <key>FavenioPDFOCRSchemaVersion</key><integer>1</integer>
    <key>FavenioPPTXOCRSchemaVersion</key><integer>1</integer>
    <key>FavenioTextEncodingVersion</key><integer>1</integer>
    <key>CFBundleName</key><string>Favenio</string>
    <key>CFBundleDisplayName</key><string>Favenio</string>
    <key>CFBundleIconFile</key><string>Favenio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Automatisch prüfen, aber nur nach ausdrücklicher Zustimmung
         installieren. Feed und Archiv müssen Sparkle-signiert sein. -->
    <key>SUFeedURL</key><string></string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><false/>
    <key>SUAllowsAutomaticUpdates</key><false/>
    <key>SUEnableSystemProfiling</key><false/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Favenio fragt den Finder nach offenen Ordnern, um dort zu suchen.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>Favenio Suchergebnisse</string>
            <key>CFBundleURLSchemes</key>
            <array><string>favenio</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF
set_sparkle_feed_url Favenio.app
embed_sparkle_and_licenses Favenio.app
codesign "${APP_SIGN[@]}" Favenio.app
codesign --verify --deep --strict Favenio.app

# ---------- FavenioQuick.app (Toolbar-Schnellsuche) ----------
rm -rf FavenioQuick.app
mkdir -p FavenioQuick.app/Contents/MacOS \
    FavenioQuick.app/Contents/Resources \
    FavenioQuick.app/Contents/Frameworks
compile_frontend FavenioQuick.app/Contents/MacOS/FavenioQuick -O quick/FavenioQuick.swift
mkdir -p FavenioQuick.app/Contents/Helpers
cp .build/favenio-pdf FavenioQuick.app/Contents/Helpers/favenio-pdf
codesign "${NESTED_SIGN[@]}" FavenioQuick.app/Contents/Helpers/favenio-pdf
cp .build/favenio-ocr FavenioQuick.app/Contents/Helpers/favenio-ocr
codesign "${NESTED_SIGN[@]}" FavenioQuick.app/Contents/Helpers/favenio-ocr
cp favenio.py FavenioQuick.app/Contents/Resources/
cp icons/FavenioQuick.icns FavenioQuick.app/Contents/Resources/
cat > FavenioQuick.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>FavenioQuick</string>
    <key>CFBundleIdentifier</key><string>local.favenio.quick</string>
    <key>FavenioFinderMetadataSchemaVersion</key><integer>1</integer>
    <key>FavenioLocalContentSchemaVersion</key><integer>1</integer>
    <key>FavenioOCRSchemaVersion</key><integer>1</integer>
    <key>FavenioPDFOCRSchemaVersion</key><integer>1</integer>
    <key>FavenioPPTXOCRSchemaVersion</key><integer>1</integer>
    <key>CFBundleName</key><string>Favenio Schnellsuche</string>
    <key>CFBundleDisplayName</key><string>Favenio Schnellsuche</string>
    <key>CFBundleIconFile</key><string>FavenioQuick</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
    <!-- Eigenes App-Bundle: prüft denselben signierten Produkt-Feed und
         aktualisiert sich aus demselben Release-DMG wie die Haupt-App. -->
    <key>SUFeedURL</key><string></string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><false/>
    <key>SUAllowsAutomaticUpdates</key><false/>
    <key>SUEnableSystemProfiling</key><false/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Favenio fragt den Finder nach dem aktuellen Ordner, um dort zu suchen.</string>
</dict>
</plist>
EOF
set_sparkle_feed_url FavenioQuick.app
embed_sparkle_and_licenses FavenioQuick.app
codesign "${APP_SIGN[@]}" FavenioQuick.app
codesign --verify --deep --strict FavenioQuick.app

# Die lokalen Test-Bundles verwenden dieselben Ressourcen und Helfer. Die
# eigene Bundle-ID trennt Einstellungen auch bei impliziten AppKit-Zugriffen.
SELFTEST_DIR=.build/selftests
MAIN_SELFTEST="$SELFTEST_DIR/FavenioMainSelfTest.app/Contents/MacOS/Favenio"
QUICK_SELFTEST="$SELFTEST_DIR/FavenioQuickSelfTest.app/Contents/MacOS/FavenioQuick"

build_selftest_bundle() {
    local name="$1" target="$2" identifier="$3"
    shift 3
    local app="${target%/Contents/MacOS/*}"
    rm -rf "$app"
    ditto "$name.app" "$app"
    local plist="$app/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleIdentifier -string "$identifier.$(/usr/bin/uuidgen)" "$plist"
    /usr/bin/plutil -replace CFBundleName -string "$name Selbsttest" "$plist"
    /usr/bin/plutil -replace CFBundleDisplayName -string "$name Selbsttest" "$plist"
    if [[ "$name" == "Favenio" ]]; then
        /usr/bin/plutil -remove CFBundleURLTypes "$plist"
    fi
    compile_frontend "$target" -O -D FAVENIO_SELFTEST tests/AppKitSelfTestSupport.swift "$@"
    codesign --force --sign - "$app"
}
mkdir -p "$SELFTEST_DIR"
build_selftest_bundle Favenio "$MAIN_SELFTEST" local.favenio.selftest.main \
    "${MAIN_SOURCES[@]}" gui/FavenioMainSelfTest.swift gui/FastraHandoffSelfTest.swift \
    gui/SearchControlSelfTest.swift gui/CriteriaEditorSelfTest.swift
build_selftest_bundle FavenioQuick "$QUICK_SELFTEST" local.favenio.selftest.quick \
    quick/FavenioQuick.swift quick/FavenioQuickSelfTest.swift

# Der Exit-Status allein beweist nichts: Ein Selbsttest, der sich unterwegs
# über NSApp.terminate beendet, endet mit Status 0 — ohne je eine Prüfung
# fertig gemacht zu haben. Am 2026-09-10 belegt: Mit absichtlich
# zurückgenommenem windowWillClose-Fix der Schnellsuche lief dieser Bau
# vollständig durch und meldete Erfolg, obwohl deren Selbsttest mitten im
# Lauf starb. Deshalb ist die Schlusszeile das Erfolgskriterium.
run_selftest() {
    local binary="$1" output
    if ! output=$("$binary" 2>&1); then
        printf '%s\n' "$output"
        echo "FEHLER: $binary ist gescheitert." >&2
        return 1
    fi
    printf '%s\n' "$output"
    if ! awk '/^SELFTEST OK — / { count++ } NF { last = $0 }
        END { exit !(count == 1 && last ~ /^SELFTEST OK — /) }' <<< "$output"; then
        echo "FEHLER: $binary endete ohne genau eine Schlusszeile 'SELFTEST OK'." >&2
        echo "Ein Selbsttest, der sich über NSApp.terminate beendet, endet" >&2
        echo "ebenfalls mit Status 0 — hier zählt nur die Schlusszeile." >&2
        return 1
    fi
}

run_selftest_failure() {
    local binary="$1" argument="$2" expected="$3" output result=0
    output=$("$binary" "$argument" 2>&1) || result=$?
    printf '%s\n' "$output"
    if [[ "$result" != "1" ]] \
        || ! grep -Fqx -- "SELFTEST FEHLER: $expected" <<< "$output" \
        || [[ "$(printf '%s\n' "$output" | awk 'NF { line = $0 } END { print line }')" != "SELFTEST ISOLATION OK" ]]; then
        echo "FEHLER: $binary $argument erreichte die reguläre Fehlerrückkehr nicht." >&2
        return 1
    fi
}

run_build_selftests() {
    if [[ "${FAVENIO_DEFER_SELFTEST:-0}" == "1" ]]; then
        echo "Selbsttests und Bundle-Prüfungen aufgeschoben."
        return 0
    fi
    echo "== Headless-Selbsttests =="
    run_selftest "$MAIN_SELFTEST"
    run_selftest "$QUICK_SELFTEST"
    run_selftest_failure "$MAIN_SELFTEST" --fail-date "Erzwungener Fehler im Datumstest"
    run_selftest_failure "$QUICK_SELFTEST" --fail-preferences "Erzwungener Fehler nach Änderung der Finder-Spalten"
    run_selftest_failure "$QUICK_SELFTEST" --fail-scope-capture "Bildaufnahme fehlgeschlagen (Status 1)"
    echo "== Produkt-Bundles =="
    FAVENIO_EXPECTED_UPDATE_FEED="${SPARKLE_FEED_URL:-}" Favenio.app/Contents/MacOS/Favenio --check-bundle
    FAVENIO_EXPECTED_UPDATE_FEED="${SPARKLE_FEED_URL:-}" FavenioQuick.app/Contents/MacOS/FavenioQuick --check-bundle
}
run_build_selftests

echo "Fertig: Favenio.app + FavenioQuick.app $VERSION im Projektverzeichnis"
echo "Keine Installation durchgeführt. Releases nur aus dem notarisierten DMG installieren."
# Maschinenlesbare Schlusszeile: Aufrufer (./build.sh, Agenten, CI) lesen die
# Ergebnispfade aus der letzten Zeile statt aus dem Log. $PWD steht bewusst
# unmaskiert darin und kann Leerzeichen enthalten (Clone unter „…/mit
# Leerzeichen/"): Leser trennen die Zeile deshalb nicht an Leerzeichen,
# sondern nehmen zweimal denselben Ordner mit den festen Bundle-Namen.
echo "BUILD OK: $PWD/Favenio.app $PWD/FavenioQuick.app"
