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
# Exit-Codes: 0 = installiert (bzw. Prüfung bestanden),
#             2 = Fehler ohne Änderung am installierten Stand,
#             3 = Rollback unvollständig; verbleibender Zustand auf stderr.
# Letzte Zeile bei Erfolg (maschinenlesbar):
#   "INSTALL OK: <version> → /Applications"  bzw.  "VERIFY OK: <quelle>"
set -euo pipefail
cd "$(dirname "$0")"
source ./notarize-lib.sh

DEST="/Applications"
DMG=""
VERIFY_ONLY=0
MOUNT=""
INSTALLED=0

# Zwei Umgebungsvariablen, die build-app.sh für Sparkle-Tests im
# Projektverzeichnis kennt, dürfen NIE in eine Installation nach
# /Applications durchschlagen. Geerbt würden sie einfach mitgegeben:
#
#   SPARKLE_FEED_URL          richtete die installierte App dauerhaft auf
#                             einen fremden Update-Feed.
#   FAVENIO_SPARKLE_TEST_VERSION  setzt eine gefälschte Build-Nummer. Die
#                             Gleichheitsprüfung weiter unten vergleicht nur
#                             die BEIDEN Bundles gegeneinander und ginge
#                             durch; die installierte App böte sich danach
#                             über Sparkle sofort selbst ein „Update" an.
#
# Abgelehnt statt stillschweigend entfernt: Wer sie gesetzt hat, wollte
# etwas anderes als eine Installation, und soll das merken. Geprüft wird
# hier VOR dem Bauen — die nachgelagerte Feed-Prüfung greift erst nach der
# Notarisierung und hätte einen Notary-Vorgang verbraucht.
for var in SPARKLE_FEED_URL FAVENIO_SPARKLE_TEST_VERSION; do
    if [ -n "${(P)var:-}" ]; then
        echo "FEHLER: $var ist gesetzt — damit wird nicht installiert." >&2
        echo "Diese Variable gehört zum Sparkle-Test im Projektverzeichnis." >&2
        echo "Zum Installieren in einer Shell ohne sie starten." >&2
        exit 2
    fi
done

# Aufräumen UND fremde Werkzeug-Status auf den zugesagten Fehlercode 2 bringen.
# Der eigene Status 3 bleibt erhalten: Er meldet ausdrücklich, dass die
# Rückholung des alten Installationsstands selbst unvollständig war.
cleanup() {
    local exit_status=$?
    if [ -n "$MOUNT" ]; then
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
        rmdir "$MOUNT" 2>/dev/null || true
    fi
    # Eine Installationssperre dieses Laufs nie liegen lassen: Sonst blockiert
    # ein Ctrl-C mitten im Austausch jede weitere Installation, bis jemand den
    # Ordner von Hand entfernt (siehe notarize-lib.sh).
    if [ -n "${FAVENIO_INSTALL_LOCK:-}" ]; then
        rm -rf "$FAVENIO_INSTALL_LOCK" 2>/dev/null || true
    fi
    case "$exit_status" in
        0) ;;
        3) exit 3 ;;
        *)
            # Exit 2 verspricht: installierter Stand UNVERÄNDERT. Nach dem
            # Austausch stimmt das nicht mehr. Erreichbar ist der Fall über
            # `install.sh | head`: Die abschließenden echo-Zeilen enden dann
            # mit SIGPIPE, und der Lauf meldete fälschlich, nichts geändert
            # zu haben. Hinter dem Austausch steht deshalb nur noch Ausgabe;
            # ein neuer Schritt, der scheitern kann, gehört DAVOR.
            [ "$INSTALLED" = "1" ] && exit 0
            exit 2 ;;
    esac
}
trap cleanup EXIT
# Gemessen am 2026-09-03: In zsh läuft ein EXIT-Trap bei SIGINT (Ctrl-C) und
# bei SIGHUP mit, bei SIGTERM aber NICHT — dann blieben das eingehängte DMG
# und die Installationssperre liegen. `exit 2` löst den EXIT-Trap aus, sodass
# cleanup genau einmal läuft. Der Austausch selbst hat eigene, feinere
# Handler (notarize-lib.sh) und wird davon nicht berührt: Sie sind lokal und
# gelten, solange favenio_install_bundles läuft.
trap 'exit 2' HUP INT TERM

while [ $# -gt 0 ]; do
    case "$1" in
        --dmg)
            [ $# -ge 2 ] || { echo "FEHLER: --dmg braucht einen Pfad." >&2; exit 2; }
            DMG="$2"; shift 2 ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        -h|--help)
            # Den GANZEN Kopfkommentar ausgeben: ab Zeile 2 bis zur ersten
            # Zeile, die kein Kommentar mehr ist. Vorher stand hier eine feste
            # Endzeile — als der Kopf um die Exit-Code-Erklärung wuchs, fiel
            # der Hinweis auf die maschinenlesbare Erfolgszeile stillschweigend
            # aus der Hilfe.
            awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
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
    # Signatur, Gatekeeper-Urteil und angeheftetes Ticket kommen aus EINER
    # Funktion (notarize-lib.sh) — dieselbe, die nach dem Austausch das
    # eingesetzte Bundle prüft. Vorher standen die drei Prüfungen hier ein
    # zweites Mal ausgeschrieben. Früh geprüft, damit auch --verify-only
    # sie beantwortet.
    notarize_verify_installed "$SOURCE_DIR/$app" || exit 2
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
# jedem Fehler den alten Stand zurückholen (siehe notarize-lib.sh). Exit 2
# garantiert den unveränderten alten Stand; Exit 3 meldet einen unvollständigen
# Rollback samt verbleibenden Pfaden, statt dieselbe Garantie fälschlich zu
# geben.
if favenio_install_bundles "$SOURCE_DIR" "$DEST"; then
    :
else
    install_status=$?
    exit "$install_status"
fi

INSTALLED=1
echo "────────────────────────────────────────────"
echo "INSTALL OK: $VERSION → $DEST"
