#!/bin/zsh
# Favenio — Installation nach /Applications.
#
# Die drei Skripte des Projekts trennen bewusst:
#   ./build-app.sh   baut und testet beide Apps IM Projektverzeichnis
#   ./install.sh     baut, notarisiert und installiert nach /Applications
#   ./release.sh     baut, notarisiert und packt das Release-DMG (installiert nie)
#
# Warum die Trennung: Ein Build im Projektverzeichnis darf ad-hoc signiert sein.
# In /Applications gehören nur Bundles, deren Notary-Ticket ANGEHEFTET ist und
# die Gatekeeper akzeptiert. Dieses Skript stellt genau das her und prüft es vor
# UND nach dem Kopieren.
#
# Aufruf:
#   ./install.sh                    # bauen, notarisieren, installieren
#   ./install.sh --dmg <pfad>       # stattdessen aus einem fertigen DMG
#                                   # installieren (z. B. exakt dem Release-Stand)
#   ./install.sh --verify-only      # nur prüfen, nichts installieren
#
# Exit-Codes: 0 = installiert (bzw. Prüfung bestanden), 2 = Fehler.
# Letzte Zeile bei Erfolg (maschinenlesbar):
#   "INSTALL OK: <version> → /Applications"  bzw.  "VERIFY OK: <quelle>"
set -euo pipefail
cd "$(dirname "$0")"
source ./notarize-lib.sh

DEST="/Applications"
DMG=""
VERIFY_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dmg)
            [ $# -ge 2 ] || { echo "FEHLER: --dmg braucht einen Pfad." >&2; exit 2; }
            DMG="$2"; shift 2 ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2
           echo "Aufruf: ./install.sh [--dmg <pfad>] [--verify-only]" >&2
           exit 2 ;;
    esac
done

# ---------- Quelle A: fertiges DMG ----------
# Bewusst nur auf Wunsch: So lässt sich exakt der ausgelieferte Release-Stand
# installieren, ohne ihn neu zu bauen.
if [ -n "$DMG" ]; then
    [ -f "$DMG" ] || { echo "FEHLER: DMG nicht gefunden: $DMG" >&2; exit 2; }

    echo "== Schritt 1/3: Notarisierung des DMG prüfen =="
    # stapler validate beweist das ANGEHEFTETE Ticket — auch ohne Netz.
    # spctl fragt zusätzlich, ob Gatekeeper das Artefakt öffnen würde.
    xcrun stapler validate "$DMG" >/dev/null 2>&1 || {
        echo "FEHLER: $DMG trägt kein angeheftetes Notary-Ticket." >&2
        echo "Nur notarisierte und gestapelte DMGs dürfen nach $DEST." >&2
        exit 2; }
    spctl --assess --type open --context context:primary-signature \
        "$DMG" >/dev/null 2>&1 || {
        echo "FEHLER: Gatekeeper akzeptiert $DMG nicht." >&2; exit 2; }
    echo "DMG notarisiert, gestapelt und von Gatekeeper akzeptiert."

    MOUNT=$(mktemp -d)
    trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; \
          rmdir "$MOUNT" 2>/dev/null || true' EXIT
    hdiutil attach "$DMG" -mountpoint "$MOUNT" -quiet -nobrowse -readonly
    SOURCE_DIR="$MOUNT"
    SOURCE_LABEL="$DMG"
    TICKET_REQUIRED=""      # bei älteren DMGs hängt das Ticket am Image
else
    # ---------- Quelle B (Default): frisch bauen und notarisieren ----------
    notarize_require_credentials
    echo "== Schritt 1/3: bauen und notarisieren =="
    ./build-app.sh
    notarize_apps
    SOURCE_DIR="."
    SOURCE_LABEL="frischer Build"
    TICKET_REQUIRED="ticket"
fi

echo "== Schritt 2/3: Bundles prüfen =="
for app in "${FAVENIO_APPS[@]}"; do
    [ -d "$SOURCE_DIR/$app" ] || { echo "FEHLER: $app fehlt." >&2; exit 2; }
    codesign --verify --strict "$SOURCE_DIR/$app" \
        || { echo "FEHLER: Signatur von $app ungültig." >&2; exit 2; }
    # Im DMG hängt das Ticket am Image, im frischen Build am Bundle selbst —
    # entscheidend ist beide Male das Gatekeeper-Urteil.
    spctl --assess --type execute "$SOURCE_DIR/$app" >/dev/null 2>&1 \
        || { echo "FEHLER: Gatekeeper akzeptiert $app nicht." >&2; exit 2; }
    echo "  $app: Signatur gültig, von Gatekeeper akzeptiert."
done

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$SOURCE_DIR/Favenio.app/Contents/Info.plist" 2>/dev/null || echo "?")

if [ "$VERIFY_ONLY" = "1" ]; then
    echo "────────────────────────────────────────────"
    echo "VERIFY OK: $SOURCE_LABEL (Version $VERSION)"
    exit 0
fi

# ---------- Laufende Instanzen beenden ----------
echo "== Schritt 3/3: installieren =="
for app in "${FAVENIO_APPS[@]}"; do
    name="${app%.app}"
    if pgrep -x "$name" >/dev/null 2>&1; then
        # Freundlich beenden, nicht abschießen: Die Schnellsuche räumt beim
        # Beenden ihre materialisierten Archivtreffer selbst auf.
        bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$SOURCE_DIR/$app/Contents/Info.plist")
        osascript -e "tell application id \"$bundle_id\" to quit" \
            >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -x "$name" >/dev/null 2>&1 || break
            sleep 0.5
        done
        if pgrep -x "$name" >/dev/null 2>&1; then
            echo "FEHLER: $name läuft noch und lässt sich nicht beenden." >&2
            echo "App schließen und erneut installieren." >&2
            exit 2
        fi
        echo "  $name beendet."
    fi
done

[ -w "$DEST" ] || { echo "FEHLER: keine Schreibrechte auf $DEST." >&2; exit 2; }
for app in "${FAVENIO_APPS[@]}"; do
    rm -rf "$DEST/$app.installing"
    # Erst vollständig danebenlegen, dann tauschen: Ein Abbruch mittendrin
    # darf keine halbe App in /Applications hinterlassen.
    ditto "$SOURCE_DIR/$app" "$DEST/$app.installing"
    rm -rf "$DEST/$app"
    mv "$DEST/$app.installing" "$DEST/$app"
    # Nach dem Kopieren zählt nur noch, was WIRKLICH in /Applications liegt —
    # inklusive angeheftetem Ticket, damit die App auch offline startet.
    notarize_verify_installed "$DEST/$app" "$TICKET_REQUIRED" \
        || { echo "FEHLER: installierte $app ist nicht notarisiert/gültig." >&2
             exit 2; }
    echo "  $app installiert und geprüft."
done

echo "────────────────────────────────────────────"
echo "INSTALL OK: $VERSION → $DEST"
