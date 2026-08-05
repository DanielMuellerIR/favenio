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
#                                   # installieren (z. B. exakt dem Release-Stand);
#                                   # beide Bundles darin brauchen ein eigenes
#                                   # angeheftetes Ticket
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
MOUNT=""

# Aufräumen UND den Exit-Code auf den zugesagten Wert bringen. Ohne das käme
# der fremde Status des ausgelösten Werkzeugs durch (`hdiutil`, `ditto`, `mv`,
# `build-app.sh` …, meist 1) und Aufrufer könnten die im Kopf dokumentierte
# Schnittstelle „0 oder 2" nicht auswerten.
cleanup() {
    local exit_status=$?
    if [ -n "$MOUNT" ]; then
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
        rmdir "$MOUNT" 2>/dev/null || true
    fi
    [ "$exit_status" -eq 0 ] || exit 2
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --dmg)
            [ $# -ge 2 ] || { echo "FEHLER: --dmg braucht einen Pfad." >&2; exit 2; }
            DMG="$2"; shift 2 ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        -h|--help)
            sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
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

    # MOUNT ist gesetzt, sobald das Abbild eingehängt ist; cleanup() oben
    # hängt es in jedem Fall wieder aus.
    MOUNT=$(mktemp -d)
    hdiutil attach "$DMG" -mountpoint "$MOUNT" -quiet -nobrowse -readonly
    SOURCE_DIR="$MOUNT"
    SOURCE_LABEL="$DMG"
else
    # ---------- Quelle B (Default): frisch bauen und notarisieren ----------
    notarize_require_credentials
    echo "== Schritt 1/3: bauen und notarisieren =="
    ./build-app.sh
    notarize_apps
    SOURCE_DIR="."
    SOURCE_LABEL="frischer Build"
fi

echo "== Schritt 2/3: Bundles prüfen =="
VERSION=""
BUILD=""
for app in "${FAVENIO_APPS[@]}"; do
    [ -d "$SOURCE_DIR/$app" ] || { echo "FEHLER: $app fehlt." >&2; exit 2; }
    codesign --verify --strict "$SOURCE_DIR/$app" \
        || { echo "FEHLER: Signatur von $app ungültig." >&2; exit 2; }
    spctl --assess --type execute "$SOURCE_DIR/$app" >/dev/null 2>&1 \
        || { echo "FEHLER: Gatekeeper akzeptiert $app nicht." >&2; exit 2; }
    # Das ANGEHEFTETE Ticket ist Pflicht, auch aus einem DMG. Nur damit
    # startet die App offline ohne Gatekeeper-Rückfrage. Sehr alte DMGs
    # tragen das Ticket bloß am Image; solche Bundles werden bewusst
    # abgelehnt (Entscheidung 2026-08-03), statt sie mit einem Hinweis
    # durchzulassen. Früh geprüft, damit auch --verify-only es beantwortet.
    xcrun stapler validate "$SOURCE_DIR/$app" >/dev/null 2>&1 \
        || { echo "FEHLER: $app trägt kein angeheftetes Notary-Ticket." >&2
             echo "Nur notarisierte und gestapelte Bundles dürfen nach $DEST." >&2
             echo "Ein aktuelles Release-DMG verwenden oder ohne --dmg neu" >&2
             echo "bauen und notarisieren." >&2
             exit 2; }
    # Gültig signiert heißt noch nicht „unser Produkt": Ohne diese Prüfung
    # könnte ein fremdes, ebenfalls notarisiertes Bundle unter demselben
    # Dateinamen die echte App ersetzen.
    favenio_verify_identity "$SOURCE_DIR/$app" "$app" || exit 2
    # Und auf welchen Update-Feed die App danach hört: Ein geerbtes
    # SPARKLE_FEED_URL aus der Umgebung würde build-app.sh mitgegeben und
    # richtete die installierte App dauerhaft auf einen fremden Feed.
    favenio_verify_feed_url "$SOURCE_DIR/$app" "$app" || exit 2
    app_version=$(/usr/libexec/PlistBuddy -c \
        "Print :CFBundleShortVersionString" \
        "$SOURCE_DIR/$app/Contents/Info.plist" 2>/dev/null || true)
    # Auch die Build-Nummer lesen: Sparkle entscheidet über Updates nach
    # CFBundleVersion, nicht nach der angezeigten Kurzversion. Zwei Bundles
    # mit gleicher Kurzversion, aber verschiedener Build-Nummer stammen aus
    # zwei Ständen — und die kleinere Build-Nummer böte sich sofort selbst
    # ein „Update" an.
    app_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
        "$SOURCE_DIR/$app/Contents/Info.plist" 2>/dev/null || true)
    [ -n "$app_version" ] && [ -n "$app_build" ] \
        || { echo "FEHLER: $app nennt keine Version." >&2; exit 2; }
    # Beide Apps gehören zum selben Stand — sonst stammen sie aus zwei
    # verschiedenen Quellen und dürfen nicht zusammen installiert werden.
    if [ -z "$VERSION" ]; then
        VERSION="$app_version"
        BUILD="$app_build"
    elif [ "$VERSION" != "$app_version" ] || [ "$BUILD" != "$app_build" ]; then
        echo "FEHLER: $app hat Version $app_version (Build $app_build)," \
             "erwartet war $VERSION (Build $BUILD)." >&2
        exit 2
    fi
    echo "  $app: Signatur gültig, Ticket angeheftet, Bundle-ID, Feed und" \
         "Version geprüft, von Gatekeeper akzeptiert."
done

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
# Beide Bundles zusammen: erst danebenlegen und prüfen, dann tauschen, und bei
# jedem Fehler den alten Stand zurückholen (siehe notarize-lib.sh). Ein Lauf
# mit Exit 2 hinterlässt damit nie eine halb aktualisierte Installation.
favenio_install_bundles "$SOURCE_DIR" "$DEST" || exit 2

echo "────────────────────────────────────────────"
echo "INSTALL OK: $VERSION → $DEST"
