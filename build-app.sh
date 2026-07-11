#!/bin/zsh
# Baut die beiden macOS-Apps von Favenio:
#   Favenio.app       — große GUI (Trefferliste, Öffnen mit, Drag & Drop)
#   FavenioQuick.app  — Mini-Schnellsuche für die Finder-Toolbar
#
# Beide Bundles bekommen eine Kopie von favenio.py in ihre Resources —
# der Python-Kern ist der einzige Suchmotor, die Apps sind nur Frontends.
# Am Ende läuft der Headless-Selbsttest (Suche + Archiv-Extraktion).
#
# Aufruf:  ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

# Version aus dem Python-Kern lesen — eine einzige Versions-Quelle.
VERSION=$(/usr/bin/python3 -c "import favenio; print(favenio.__version__)")
echo "Baue Favenio $VERSION …"

# ---------- Favenio.app (große GUI) ----------
rm -rf Favenio.app
mkdir -p Favenio.app/Contents/MacOS Favenio.app/Contents/Resources
swiftc -O common/FavenioCore.swift gui/FavenioGUI.swift \
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
codesign --force -s - Favenio.app

# ---------- FavenioQuick.app (Toolbar-Schnellsuche) ----------
rm -rf FavenioQuick.app
mkdir -p FavenioQuick.app/Contents/MacOS FavenioQuick.app/Contents/Resources
swiftc -O common/FavenioCore.swift quick/FavenioQuick.swift \
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
codesign --force -s - FavenioQuick.app

# Favenio.app bei LaunchServices anmelden, damit das favenio://-Schema
# (Übergabe Schnellsuche → GUI) sofort funktioniert, ohne dass die App
# erst einmal von Hand gestartet werden muss.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f Favenio.app || true

echo "== Headless-Selbsttest =="
Favenio.app/Contents/MacOS/Favenio --selftest
echo "Fertig: Favenio.app + FavenioQuick.app (Version $VERSION)"
