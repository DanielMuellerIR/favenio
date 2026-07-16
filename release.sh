#!/bin/zsh
# Favenio — Release-Workflow: signiertes, notarisiertes DMG für GitHub-Releases.
#
# Ablauf:
#   1. Apps bauen via build-app.sh (signiert dort mit Developer ID + Hardened
#      Runtime + Automation-Entitlement, führt den Headless-Selbsttest aus).
#   2. DMG bauen: beide Apps + /Applications-Alias, Hintergrundbild mit
#      Finder-Icon-Layout, Ausgabe dist/Favenio-<version>.dmg.
#   3. Signaturen im fertigen DMG verifizieren.
#   4. DMG signieren, bei Apple notarisieren (notarytool --wait, typ. 1-10 Min)
#      und das Ticket anheften (stapler) — Gatekeeper akzeptiert dann offline.
#
# Voraussetzungen:
#   - Developer-ID-Zertifikat in der Login-Keychain (oder FAVENIO_SIGN_ID).
#   - Ein notarytool-Keychain-Profil, pro Mac einmalig eingerichtet via:
#       xcrun notarytool store-credentials "<profil>" \
#         --apple-id "<Apple-ID>" --team-id "<Team-ID>"
#     (App-spezifisches Passwort wird interaktiv abgefragt — nie als Argument.)
#     Profilname: Default "notary", überschreibbar per NOTARY_PROFILE.
#
# Aufruf:
#   NOTARY_PROFILE=<profil> ./release.sh
#   ./release.sh --no-finder-layout   # ohne AppleScript-Finder-Layout (headless);
#                                     # das DMG funktioniert, sieht nur schlichter aus
#
# Letzte Zeile bei Erfolg (maschinenlesbar): "RELEASE OK: <pfad-zum-dmg>"
set -euo pipefail
cd "$(dirname "$0")"

FINDER_LAYOUT=1
for arg in "$@"; do
    case "$arg" in
        --no-finder-layout) FINDER_LAYOUT=0 ;;
        *) echo "Unbekannte Option: $arg" >&2
           echo "Aufruf: ./release.sh [--no-finder-layout]" >&2
           exit 1 ;;
    esac
done

NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"

# Früh scheitern statt nach dem Build: Identität und Notary-Profil prüfen.
SIGN_ID="${FAVENIO_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/^[^"]*"([^"]*)".*/\1/' || true)
fi
if [ -z "$SIGN_ID" ]; then
    echo "FEHLER: keine Developer-ID gefunden — ohne echte Signatur ist keine" >&2
    echo "Notarisierung möglich (FAVENIO_SIGN_ID setzen oder Zertifikat installieren)." >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "FEHLER: notarytool-Keychain-Profil '$NOTARY_PROFILE' nicht verwendbar." >&2
    echo "Einrichten (einmalig pro Mac) oder NOTARY_PROFILE korrekt setzen." >&2
    exit 1
fi

# ---------- Schritt 1: Apps bauen (signiert + Selbsttest) ----------
echo "== Schritt 1/4: Apps bauen =="
./build-app.sh

VERSION=$(/usr/bin/python3 -c "import favenio; print(favenio.__version__)")
DIST="dist"
DMG_PATH="$DIST/Favenio-${VERSION}.dmg"
mkdir -p "$DIST"
rm -f "$DMG_PATH"

# ---------- Schritt 2: DMG mit Hintergrundbild bauen ----------
echo "== Schritt 2/4: DMG bauen =="
STAGING=$(mktemp -d)
RW_DMG="$STAGING/favenio_rw.dmg"
VOL_NAME="Favenio"
MOUNT_DIR="/Volumes/$VOL_NAME"
# Aufräumen auch bei Fehlern: Volume aushängen, Arbeitsverzeichnis löschen.
trap 'hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true; rm -rf "$STAGING"' EXIT

# Hintergrundbild reproduzierbar erzeugen und als HiDPI-TIFF aufbereiten:
# Retina-scharf zeigt der Finder es nur, wenn das TIFF 1x UND 2x enthält.
xcrun swift assets/generate-dmg-background.swift "$STAGING/DmgBackground.png"
sips -s format png -s dpiWidth 72  -s dpiHeight 72  -z 420 600 \
    "$STAGING/DmgBackground.png" --out "$STAGING/DmgBg_1x.png" >/dev/null
sips -s format png -s dpiWidth 144 -s dpiHeight 144 -z 840 1200 \
    "$STAGING/DmgBackground.png" --out "$STAGING/DmgBg_2x.png" >/dev/null
tiffutil -cathidpicheck "$STAGING/DmgBg_1x.png" "$STAGING/DmgBg_2x.png" \
    -out "$STAGING/DmgBackground.tiff"

# HFS+ statt APFS: AppleScript-Fenster-Bounds sind in APFS-DMGs auf älteren
# macOS-Versionen unzuverlässig. Größe großzügig; UDZO komprimiert später.
if [ -d "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
fi
hdiutil create -size 100m -fs HFS+ -volname "$VOL_NAME" -ov -quiet "$RW_DMG"
hdiutil attach -readwrite -noverify -noautoopen -quiet \
    -mountpoint "$MOUNT_DIR" "$RW_DMG"

cp -R Favenio.app "$MOUNT_DIR/Favenio.app"
cp -R FavenioQuick.app "$MOUNT_DIR/FavenioQuick.app"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir "$MOUNT_DIR/.background"
cp "$STAGING/DmgBackground.tiff" "$MOUNT_DIR/.background/DmgBackground.tiff"

# Finder-Layout: Icon-Ansicht, Inhaltsfläche 600×420 Punkte. Seit macOS 26
# braucht der Finder-Chrome ~68 Punkte extra → äußeres Fenster 600×488.
# Der Finder übernimmt ein einmaliges "set bounds" nicht zuverlässig, deshalb
# setzen, zurücklesen und wiederholen, bis die Zielgröße wirklich anliegt.
if [ "$FINDER_LAYOUT" = "1" ]; then
    osascript <<EOF
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set background picture of viewOptions to file ".background:DmgBackground.tiff"
        set position of item "Favenio.app" of container window to {110, 300}
        set position of item "FavenioQuick.app" of container window to {270, 300}
        set position of item "Applications" of container window to {480, 300}
        repeat with i from 1 to 5
            set the bounds of container window to {200, 120, 800, 608}
            delay 1
            if (bounds of container window) = {200, 120, 800, 608} then exit repeat
        end repeat
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF
else
    echo "--no-finder-layout gesetzt → Finder-Layout übersprungen"
fi

# Kurze Pause: der Finder muss die .DS_Store fertig schreiben, bevor das
# Volume ausgehängt und eingefroren wird.
sleep 2
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach -force "$MOUNT_DIR"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG_PATH"
echo "DMG gebaut: $DMG_PATH"

# ---------- Schritt 3: Signaturen im DMG verifizieren ----------
echo "== Schritt 3/4: Signaturen verifizieren =="
VERIFY_MOUNT=$(mktemp -d)
trap 'hdiutil detach "$VERIFY_MOUNT" -quiet 2>/dev/null || true; \
      hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true; rm -rf "$STAGING"' EXIT
hdiutil attach "$DMG_PATH" -mountpoint "$VERIFY_MOUNT" -quiet -nobrowse
codesign --verify --strict "$VERIFY_MOUNT/Favenio.app"
codesign --verify --strict "$VERIFY_MOUNT/FavenioQuick.app"
hdiutil detach "$VERIFY_MOUNT" -quiet
echo "Signaturen im DMG gültig."

# ---------- Schritt 4: DMG signieren, notarisieren, stapeln ----------
echo "== Schritt 4/4: Notarisierung (Profil: $NOTARY_PROFILE) =="
# Apple verlangt, dass auch das DMG selbst signiert ist, nicht nur der Inhalt.
codesign --force --timestamp --sign "$SIGN_ID" "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "────────────────────────────────────────────"
echo "RELEASE OK: $DMG_PATH"
