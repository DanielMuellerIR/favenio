#!/bin/zsh
# Favenio — Installation nach /Applications, ausschließlich aus einem
# notarisierten Release-DMG.
#
# Die drei Skripte des Projekts trennen bewusst:
#   ./build-app.sh   baut und testet beide Apps IM Projektverzeichnis
#   ./release.sh     baut daraus das DMG, notarisiert und stapelt es
#   ./install.sh     installiert genau so ein geprüftes DMG (dieses Skript)
#
# Warum die Trennung: Ein Build im Projektverzeichnis darf ad-hoc signiert sein.
# In /Applications gehören nur Bundles, deren Notary-Ticket angeheftet ist und
# die Gatekeeper akzeptiert. Dieses Skript prüft das VOR jedem Kopiervorgang und
# bricht sonst ab — es baut und notarisiert selbst nichts.
#
# Aufruf:
#   ./install.sh                    # neuestes DMG zur aktuellen Version
#   ./install.sh --dmg <pfad>       # bestimmtes DMG
#   ./install.sh --verify-only      # nur prüfen, nichts installieren
#
# Exit-Codes: 0 = installiert (bzw. Prüfung bestanden), 2 = Fehler.
# Letzte Zeile bei Erfolg (maschinenlesbar):
#   "INSTALL OK: <version> → /Applications"  bzw.  "VERIFY OK: <dmg>"
set -euo pipefail
cd "$(dirname "$0")"

APPS=("Favenio.app" "FavenioQuick.app")
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
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2
           echo "Aufruf: ./install.sh [--dmg <pfad>] [--verify-only]" >&2
           exit 2 ;;
    esac
done

# ---------- DMG bestimmen ----------
if [ -z "$DMG" ]; then
    VERSION=$(/usr/bin/python3 -c "import favenio; print(favenio.__version__)")
    DMG="dist/Favenio-${VERSION}.dmg"
    if [ ! -f "$DMG" ]; then
        echo "FEHLER: $DMG fehlt." >&2
        echo "Zuerst ./release.sh ausführen (baut, notarisiert und stapelt)." >&2
        exit 2
    fi
fi
if [ ! -f "$DMG" ]; then
    echo "FEHLER: DMG nicht gefunden: $DMG" >&2
    exit 2
fi

echo "== Schritt 1/4: Notarisierung des DMG prüfen =="
# stapler validate beweist das ANGEHEFTETE Ticket — das funktioniert auch ohne
# Netz. spctl fragt zusätzlich, ob Gatekeeper das Artefakt wirklich öffnen würde.
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    echo "FEHLER: $DMG trägt kein angeheftetes Notary-Ticket." >&2
    echo "Nur notarisierte und gestapelte DMGs dürfen nach $DEST." >&2
    exit 2
fi
if ! spctl --assess --type open --context context:primary-signature \
        "$DMG" >/dev/null 2>&1; then
    echo "FEHLER: Gatekeeper akzeptiert $DMG nicht." >&2
    exit 2
fi
echo "DMG notarisiert, gestapelt und von Gatekeeper akzeptiert."

# ---------- DMG einhängen ----------
MOUNT=$(mktemp -d)
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
hdiutil attach "$DMG" -mountpoint "$MOUNT" -quiet -nobrowse -readonly

echo "== Schritt 2/4: App-Bundles im DMG prüfen =="
for app in "${APPS[@]}"; do
    [ -d "$MOUNT/$app" ] || { echo "FEHLER: $app fehlt im DMG." >&2; exit 2; }
    codesign --verify --strict "$MOUNT/$app" \
        || { echo "FEHLER: Signatur von $app ungültig." >&2; exit 2; }
    # --type execute bewertet die App so, wie das System sie beim Start
    # bewertet; das Ticket liegt am umgebenden DMG bzw. bei Apple.
    spctl --assess --type execute "$MOUNT/$app" >/dev/null 2>&1 \
        || { echo "FEHLER: Gatekeeper akzeptiert $app nicht." >&2; exit 2; }
    echo "  $app: Signatur gültig, von Gatekeeper akzeptiert."
done

DMG_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$MOUNT/Favenio.app/Contents/Info.plist" 2>/dev/null || echo "?")

if [ "$VERIFY_ONLY" = "1" ]; then
    echo "────────────────────────────────────────────"
    echo "VERIFY OK: $DMG (Version $DMG_VERSION)"
    exit 0
fi

# ---------- Laufende Instanzen beenden ----------
echo "== Schritt 3/4: laufende Favenio-Apps beenden =="
for app in "${APPS[@]}"; do
    name="${app%.app}"
    if pgrep -x "$name" >/dev/null 2>&1; then
        # Freundlich beenden, nicht abschießen: Die Schnellsuche räumt beim
        # Beenden ihre materialisierten Archivtreffer selbst auf.
        osascript -e "tell application id \"$( \
            /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$MOUNT/$app/Contents/Info.plist")\" to quit" >/dev/null 2>&1 || true
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

# ---------- Kopieren und erneut prüfen ----------
echo "== Schritt 4/4: nach $DEST kopieren =="
for app in "${APPS[@]}"; do
    if [ ! -w "$DEST" ]; then
        echo "FEHLER: keine Schreibrechte auf $DEST." >&2
        exit 2
    fi
    rm -rf "$DEST/$app.installing"
    # Erst vollständig danebenlegen, dann tauschen: Ein Abbruch mittendrin
    # darf keine halbe App in /Applications hinterlassen.
    ditto "$MOUNT/$app" "$DEST/$app.installing"
    rm -rf "$DEST/$app"
    mv "$DEST/$app.installing" "$DEST/$app"
    # Nach dem Kopieren zählt nur noch, was WIRKLICH in /Applications liegt.
    codesign --verify --strict "$DEST/$app" \
        || { echo "FEHLER: installierte $app ist nicht gültig signiert." >&2; exit 2; }
    spctl --assess --type execute "$DEST/$app" >/dev/null 2>&1 \
        || { echo "FEHLER: Gatekeeper akzeptiert die installierte $app nicht." >&2
             exit 2; }
    echo "  $app installiert und geprüft."
done

echo "────────────────────────────────────────────"
echo "INSTALL OK: $DMG_VERSION → $DEST"
