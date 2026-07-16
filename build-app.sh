#!/bin/zsh
# Baut die beiden macOS-Apps von Favenio:
#   Favenio.app       — große GUI (Trefferliste, Öffnen mit, Drag & Drop)
#   FavenioQuick.app  — Mini-Schnellsuche für die Finder-Toolbar
#
# Beide Bundles bekommen eine Kopie von favenio.py in ihre Resources —
# der Python-Kern ist der einzige Suchmotor, die Apps sind nur Frontends.
# Am Ende laufen der Headless-Selbsttest und die Installation beider Apps
# nach /Applications. So aktualisiert jedes abgeschlossene App-Todo auch
# automatisch die tatsächlich gestarteten Bundles.
#
# Aufruf:  ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

# Version + Datum aus dem Python-Kern lesen — eine einzige Versions-Quelle.
VERSION=$(/usr/bin/python3 -c "import favenio; print(favenio.__version__)")
DATE=$(/usr/bin/python3 -c "import favenio; print(getattr(favenio, '__date__', ''))")
echo "Baue Favenio $VERSION ($DATE) …"

# Beides in eine Swift-Konstante gießen (von beiden Apps mitkompiliert),
# damit die Fenstertitel Version + Datum ohne Python-Aufruf zur Laufzeit
# zeigen. Datei ist git-ignoriert (generiert).
cat > common/Version.swift <<EOF
// AUTO-GENERIERT von build-app.sh aus favenio.py — nicht von Hand editieren.
let favenioVersion = "${VERSION}"
let favenioDate = "${DATE}"
EOF

# Stabile Code-Signatur wählen. Mit einer Developer-ID-Identität behält
# macOS/TCC die Freigaben (Festplattenvollzugriff, Finder-Automation) über
# Builds hinweg — Ad-hoc (-s -) ändert bei JEDEM Build den cdhash und setzt
# alle Freigaben zurück. Identität automatisch aus der Login-Keychain lesen
# (überschreibbar per FAVENIO_SIGN_ID); ohne Developer-ID Rückfall auf Ad-hoc.
# Kein --options runtime (Hardened Runtime): ohne Automation-Entitlement würde
# das die Finder-AppleScripts blockieren; für lokale Nutzung nicht nötig.
SIGN_ID="${FAVENIO_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    # `|| true`: Ohne Developer-ID (z. B. auf CI-Runnern) findet grep nichts
    # und würde die Pipeline unter `set -euo pipefail` das Skript abbrechen,
    # bevor der Ad-hoc-Fallback unten greifen kann.
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/^[^"]*"([^"]*)".*/\1/' || true)
fi
if [ -n "$SIGN_ID" ]; then
    SIGN=(--force --sign "$SIGN_ID")
    echo "Signiere mit stabiler Identität: $SIGN_ID"
else
    SIGN=(--force --sign -)
    echo "WARNUNG: keine Developer-ID gefunden → Ad-hoc-Signatur " \
         "(TCC-Freigaben überleben KEINEN Rebuild)."
fi

# Deployment-Target festnageln: Ohne -target erbt das Binary das macOS der
# Build-Maschine als Minimum (LC_BUILD_VERSION minos) und startet auf älteren
# Systemen gar nicht — LSMinimumSystemVersion im Info.plist ändert daran nichts.
# macOS 12 ist das echte Minimum: urlsForApplications(toOpen:) („Öffnen mit"-
# Menü) und die im System enthaltene Swift-Concurrency-Runtime brauchen es.
TARGET="arm64-apple-macos12.0"

# ---------- Favenio.app (große GUI) ----------
rm -rf Favenio.app
mkdir -p Favenio.app/Contents/MacOS Favenio.app/Contents/Resources
swiftc -O -target "$TARGET" \
    common/FavenioCore.swift common/Version.swift gui/FavenioGUI.swift \
    -o Favenio.app/Contents/MacOS/Favenio
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
    <key>CFBundleName</key><string>Favenio</string>
    <key>CFBundleDisplayName</key><string>Favenio</string>
    <key>CFBundleIconFile</key><string>Favenio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
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
codesign "${SIGN[@]}" Favenio.app

# ---------- FavenioQuick.app (Toolbar-Schnellsuche) ----------
rm -rf FavenioQuick.app
mkdir -p FavenioQuick.app/Contents/MacOS FavenioQuick.app/Contents/Resources
swiftc -O -target "$TARGET" \
    common/FavenioCore.swift common/Version.swift quick/FavenioQuick.swift \
    -o FavenioQuick.app/Contents/MacOS/FavenioQuick
cp favenio.py FavenioQuick.app/Contents/Resources/
cp icons/FavenioQuick.icns FavenioQuick.app/Contents/Resources/
cat > FavenioQuick.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>FavenioQuick</string>
    <key>CFBundleIdentifier</key><string>local.favenio.quick</string>
    <key>CFBundleName</key><string>Favenio Schnellsuche</string>
    <key>CFBundleDisplayName</key><string>Favenio Schnellsuche</string>
    <key>CFBundleIconFile</key><string>FavenioQuick</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Favenio fragt den Finder nach dem aktuellen Ordner, um dort zu suchen.</string>
</dict>
</plist>
EOF
codesign "${SIGN[@]}" FavenioQuick.app

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "== Headless-Selbsttest =="
Favenio.app/Contents/MacOS/Favenio --selftest

echo "== Installation nach /Applications =="
# ditto ersetzt vorhandene Bundles vollständig und erhält die für macOS
# erforderliche Bundle-Struktur. Vorher laufende Instanzen werden beendet,
# damit beim nächsten Klick sicher die neue Version startet.
pkill -x Favenio 2>/dev/null || true
pkill -x FavenioQuick 2>/dev/null || true
rm -rf /Applications/Favenio.app /Applications/FavenioQuick.app
ditto Favenio.app /Applications/Favenio.app
ditto FavenioQuick.app /Applications/FavenioQuick.app
"$LSREGISTER" -f /Applications/Favenio.app || true
"$LSREGISTER" -f /Applications/FavenioQuick.app || true

echo "Fertig: Favenio.app + FavenioQuick.app $VERSION in /Applications"
