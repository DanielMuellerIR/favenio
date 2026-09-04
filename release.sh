#!/bin/zsh
# Favenio — Release-Workflow: signiertes, notarisiertes DMG für GitHub-Releases.
#
# Ablauf:
#   1. Apps bauen via build-app.sh (signiert dort mit Developer ID + Hardened
#      Runtime + Automation-Entitlement, führt den Headless-Selbsttest aus).
#   2. Beide Bundles notarisieren und das Ticket ANHEFTEN. Das ist dieselbe
#      Notarisierung, die install.sh verwendet — dadurch tragen die Apps ihr
#      Ticket auch dann, wenn jemand sie aus dem DMG herauszieht.
#   3. DMG bauen: beide Apps + /Applications-Alias, Hintergrundbild mit
#      Finder-Icon-Layout, Ausgabe dist/Favenio-<version>.dmg.
#   4. Signaturen im fertigen DMG verifizieren.
#   5. DMG signieren, bei Apple notarisieren (notarytool --wait, typ. 1-10 Min)
#      und das Ticket anheften (stapler) — Gatekeeper akzeptiert dann offline.
#
# Voraussetzungen:
#   - Developer-ID-Zertifikat in der Login-Keychain (oder FAVENIO_SIGN_ID).
#   - Ein notarytool-Keychain-Profil, pro Mac einmalig eingerichtet via:
#       xcrun notarytool store-credentials "<profil>" \
#         --apple-id "<Apple-ID>" --team-id "<Team-ID>"
#     (App-spezifisches Passwort wird interaktiv abgefragt — nie als Argument.)
#     Profilname: kein eingecheckter Default. Er kommt aus NOTARY_PROFILE oder
#     clone-lokal aus `git config --local favenio.notaryProfile <profil>`.
#   - Erwartete Entwickler-Team-ID aus FAVENIO_TEAM_ID oder clone-lokal aus
#     `git config --local favenio.teamId <team-id>`.
#
# Aufruf:
#   NOTARY_PROFILE=<profil> ./release.sh
#   ./release.sh --no-finder-layout   # ohne AppleScript-Finder-Layout (headless);
#                                     # das DMG funktioniert, sieht nur schlichter aus
#
# Letzte Zeile bei Erfolg (maschinenlesbar): "RELEASE OK: <pfad-zum-dmg>"
set -euo pipefail
cd "$(dirname "$0")"
source ./notarize-lib.sh

# Zwei Umgebungsvariablen, die build-app.sh für Sparkle-Tests im
# Projektverzeichnis kennt, dürfen nie in ein Release durchschlagen. Geerbt
# würden sie einfach mitgegeben:
#
#   SPARKLE_FEED_URL          richtete jede ausgelieferte App dauerhaft auf
#                             einen fremden Update-Feed.
#   FAVENIO_SPARKLE_TEST_VERSION  setzt eine gefälschte Build-Nummer; die
#                             ausgelieferte App böte sich danach über
#                             Sparkle sofort selbst ein „Update" an.
#
# Geprüft wird hier VOR dem Bauen, genau wie in install.sh. Die Feed-Prüfung
# in Schritt 4 greift erst nach dem Signieren und Notarisieren und hätte
# einen Notary-Vorgang bei Apple verbraucht; sie bleibt als zweite Linie.
for var in SPARKLE_FEED_URL FAVENIO_SPARKLE_TEST_VERSION; do
    if [ -n "${(P)var:-}" ]; then
        echo "FEHLER: $var ist gesetzt — damit wird kein Release gebaut." >&2
        echo "Diese Variable gehört zum Sparkle-Test im Projektverzeichnis." >&2
        echo "Für ein Release in einer Shell ohne sie starten." >&2
        exit 1
    fi
done

FINDER_LAYOUT=1
for arg in "$@"; do
    case "$arg" in
        --no-finder-layout) FINDER_LAYOUT=0 ;;
        *) echo "Unbekannte Option: $arg" >&2
           echo "Aufruf: ./release.sh [--no-finder-layout]" >&2
           exit 1 ;;
    esac
done

# Früh scheitern statt nach dem Build: Identität und Notary-Profil prüfen.
# Setzt NOTARY_PROFILE, SIGN_ID und FAVENIO_TEAM_ID (siehe notarize-lib.sh).
notarize_require_credentials
favenio_require_team_id

# ---------- Schritt 1: Apps bauen (signiert + Selbsttest) ----------
echo "== Schritt 1/5: Apps bauen =="
./build-app.sh

# ---------- Schritt 2: Bundles notarisieren und stapeln ----------
echo "== Schritt 2/5: Bundles notarisieren =="
notarize_apps

VERSION=$(/usr/bin/python3 -c "import favenio; print(favenio.__version__)")
DIST="dist"
DMG_PATH="$DIST/Favenio-${VERSION}.dmg"
mkdir -p "$DIST"
rm -f "$DMG_PATH"

# ---------- Schritt 3: DMG mit Hintergrundbild bauen ----------
echo "== Schritt 3/5: DMG bauen =="
STAGING=$(mktemp -d)
RW_DMG="$STAGING/favenio_rw.dmg"
VOL_NAME="Favenio"
# Das Arbeits-Image MUSS unter /Volumes/<Volume-Name> hängen. Das Finder-
# Skript weiter unten spricht die Platte als `disk "$VOL_NAME"` an, und der
# Finder führt ein Volume nicht unter seinem Volume-Namen, sondern unter dem
# ORDNERNAMEN seines Mountpoints: Ein Image unter "$STAGING/mnt" heißt für ihn
# `disk "mnt"`, `disk "Favenio"` gibt es dann gar nicht (AppleScript-Fehler
# -1700, verifiziert am 2026-08-19 mit einem Wegwerf-Image). Ein Zwischenstand
# hängte hier nach "$STAGING/mnt" und brach den Standardlauf von release.sh
# damit in Schritt 3 ab.
#
# Die beiden Gefahren dieses festen Pfades sind stattdessen einzeln abgesichert:
# Ein FREMDES Volume gleichen Namens lässt den Lauf unten abbrechen, statt es
# auszuhängen, und ausgehängt wird nur ein nachweislich eigener Attach.
MOUNT_DIR="/Volumes/$VOL_NAME"
BUILD_MOUNTED=0
VERIFY_MOUNT=""
VERIFY_MOUNTED=0
favenio_release_cleanup() {
    if [ "$VERIFY_MOUNTED" = "1" ]; then
        hdiutil detach "$VERIFY_MOUNT" -quiet 2>/dev/null || true
        VERIFY_MOUNTED=0
    fi
    if [ "$BUILD_MOUNTED" = "1" ]; then
        hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
        BUILD_MOUNTED=0
    fi
    # Die leeren Mountpoints gehören uns und dürfen nicht liegen bleiben.
    if [ -n "$VERIFY_MOUNT" ]; then
        rmdir "$VERIFY_MOUNT" 2>/dev/null || true
    fi
    rm -rf "$STAGING"
}
trap favenio_release_cleanup EXIT
# Gemessen am 2026-09-03 mit zsh 5.9 (Signal an die ganze Prozessgruppe): Ein
# EXIT-Trap läuft bei SIGINT und SIGHUP mit, bei SIGTERM aber NICHT. Hier
# wiegt das schwerer als in install.sh, weil MOUNT_DIR ein FESTER Pfad ist:
# Ein liegengebliebenes /Volumes/Favenio lässt jeden weiteren Release-Lauf
# absichtlich abbrechen („gehört nicht diesem Lauf"), bis jemand von Hand
# auswirft. `exit 1` löst den EXIT-Trap aus, sodass die Aufräumung genau
# einmal läuft.
trap 'exit 1' HUP INT TERM

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
# Ein fremdes Volume gleichen Namens wird NICHT ausgehängt: Das Finder-Skript
# unten spricht die Platte über ihren Namen an und träfe sonst die falsche.
# Lieber abbrechen, damit ein Mensch die Abweichung prüfen kann.
if [ -d "$MOUNT_DIR" ]; then
    echo "FEHLER: $MOUNT_DIR ist bereits eingehängt." >&2
    echo "Dieses Volume gehört nicht diesem Lauf. Erst selbst auswerfen," >&2
    echo "dann den Release erneut starten." >&2
    exit 1
fi
hdiutil create -size 100m -fs HFS+ -volname "$VOL_NAME" -ov -quiet "$RW_DMG"
hdiutil attach -readwrite -noverify -noautoopen -quiet \
    -mountpoint "$MOUNT_DIR" "$RW_DMG"
BUILD_MOUNTED=1

# ditto statt cp -R: erhält erweiterte Attribute und das in Schritt 2
# angeheftete Notary-Ticket unverändert.
ditto Favenio.app "$MOUNT_DIR/Favenio.app"
ditto FavenioQuick.app "$MOUNT_DIR/FavenioQuick.app"
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
BUILD_MOUNTED=0
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG_PATH"
echo "DMG gebaut: $DMG_PATH"

# ---------- Schritt 4: Signaturen im DMG verifizieren ----------
echo "== Schritt 4/5: Signaturen verifizieren =="
VERIFY_MOUNT=$(mktemp -d)
hdiutil attach "$DMG_PATH" -mountpoint "$VERIFY_MOUNT" -quiet -nobrowse
VERIFY_MOUNTED=1
for app in "${FAVENIO_APPS[@]}"; do
    # Dieselbe Funktion wie in install.sh: Signatur, Gatekeeper-Urteil und
    # das angeheftete Ticket aus Schritt 2, das die DMG-Erstellung überlebt
    # haben muss — sonst braucht eine herausgezogene App beim ersten Start
    # Netz. Die frühere Kopie hier prüfte nur zwei der drei Punkte und ließ
    # `spctl` weg; ein Release ging damit über eine schwächere Hürde als
    # eine lokale Installation.
    notarize_verify_installed "$VERIFY_MOUNT/$app" || exit 1
    # Ein geerbtes SPARKLE_FEED_URL wäre über build-app.sh in die Bundles
    # gewandert und richtete jede ausgelieferte App dauerhaft auf einen
    # fremden Update-Feed. Ein Release darf das nicht mitnehmen.
    favenio_verify_feed_url "$VERIFY_MOUNT/$app" "$app" || exit 1
    # Die Bundle-ID allein kann ein fremder Entwickler nachbauen. Für einen
    # Release ist deshalb zusätzlich das oben zwingend konfigurierte Apple-
    # Entwickler-Team Teil der Produktidentität.
    favenio_verify_identity "$VERIFY_MOUNT/$app" "$app" || exit 1
done
hdiutil detach "$VERIFY_MOUNT" -quiet
VERIFY_MOUNTED=0
echo "Signaturen, Tickets, Entwickler-Team und Update-Feed im DMG gültig."

# ---------- Schritt 5: DMG signieren, notarisieren, stapeln ----------
echo "== Schritt 5/5: DMG notarisieren (Profil: $NOTARY_PROFILE) =="
# Apple verlangt, dass auch das DMG selbst signiert ist, nicht nur der Inhalt.
codesign --force --timestamp --sign "$SIGN_ID" "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
# Gatekeeper muss genau das fertig signierte und gestapelte Artefakt akzeptieren.
# Erst dieses DMG darf der Nutzer anschließend bewusst nach /Applications
# installieren; Build und Release selbst verändern /Applications nie.
spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"

echo "────────────────────────────────────────────"
echo "RELEASE OK: $DMG_PATH"
