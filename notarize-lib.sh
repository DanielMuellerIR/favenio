# Favenio — gemeinsame Notarisierungsschritte für install.sh und release.sh.
#
# Diese Datei wird per `source` eingebunden und NICHT selbst ausgeführt. Sie
# liegt getrennt, damit Installation und Release exakt denselben Weg gehen: Was
# nach /Applications wandert, ist genau das, was auch im Release-DMG landet.
#
# Erwartet ein bereits eingestelltes `set -euo pipefail` und das Repo-Root als
# Arbeitsverzeichnis.

# Die beiden Bundles des Projekts — eine Liste, damit ein drittes Bundle nur
# hier ergänzt werden müsste.
FAVENIO_APPS=("Favenio.app" "FavenioQuick.app")

# Sperrverzeichnis des laufenden Austauschs, solange eines gehalten wird (siehe
# _favenio_install_lock). Der Aufräum-Trap von install.sh liest es, damit ein
# Abbruch die Sperre nicht im Zielordner liegen lässt.
FAVENIO_INSTALL_LOCK=""

# Die erwartete Produktidentität je Bundle. Der Dateiname beweist nichts: Ein
# beliebiges fremdes, ebenfalls notarisiertes Bundle unter dem Namen
# "Favenio.app" käme durch Signatur- und Gatekeeper-Prüfung und ersetzte die
# echte App. Die Bundle-ID ist der Teil der Identität, der im Projekt selbst
# festgeschrieben ist (build-app.sh erzeugt sie).
typeset -A FAVENIO_BUNDLE_IDS
FAVENIO_BUNDLE_IDS=(
    "Favenio.app"      "local.favenio"
    "FavenioQuick.app" "local.favenio.quick"
)

# Der Produktions-Update-Feed. Quelle ist der Default in build-app.sh; hier
# steht die Kopie, gegen die install.sh und release.sh prüfen. Ein Test
# (tests/test_build_safety.py) hält beide Stellen zusammen.
FAVENIO_FEED_URL="https://danielmuellerir.github.io/favenio/appcast.xml"

# Signier-Identität und Notary-Profil FRÜH prüfen: lieber vor dem Build
# scheitern als nach mehreren Minuten Arbeit.
# Setzt die globale Variable SIGN_ID.
notarize_require_credentials() {
    # Profilnamen bestimmen: Umgebung schlägt clone-lokale Git-Konfiguration.
    # Kein eingecheckter Default — ein fester Name existiert auf einem fremden
    # Mac nicht und ließe den Lauf erst nach dem Bauen scheitern. Keychain-
    # Profile sind ohnehin pro Mac lokal und werden nicht synchronisiert, der
    # Name gehört daher nicht ins öffentliche Repo.
    if [ -z "${NOTARY_PROFILE:-}" ]; then
        NOTARY_PROFILE="$(git config --local --get favenio.notaryProfile 2>/dev/null || true)"
    fi
    if [ -z "${NOTARY_PROFILE:-}" ]; then
        echo "FEHLER: Kein Notary-Profil bekannt." >&2
        echo "Entweder NOTARY_PROFILE setzen oder einmalig für diesen Clone:" >&2
        echo "  git config --local favenio.notaryProfile <profil>" >&2
        echo "Das Profil selbst einmal pro Mac anlegen:" >&2
        echo "  xcrun notarytool store-credentials <profil> --apple-id <apple-id> --team-id <team-id>" >&2
        return 2
    fi
    export NOTARY_PROFILE

    SIGN_ID="${FAVENIO_SIGN_ID:-}"
    if [ -z "$SIGN_ID" ]; then
        SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep "Developer ID Application" | head -1 \
            | sed -E 's/^[^"]*"([^"]*)".*/\1/' || true)
    fi
    if [ -z "$SIGN_ID" ]; then
        echo "FEHLER: keine Developer-ID gefunden — ohne echte Signatur ist" >&2
        echo "keine Notarisierung möglich (FAVENIO_SIGN_ID setzen oder" >&2
        echo "Zertifikat installieren)." >&2
        return 2
    fi
    # Fünf Versuche statt einem: `notarytool history` meldet gelegentlich
    # fälschlich „No Keychain password item found", obwohl das Profil da ist
    # (2026-07-26 auf M3 belegt — Versuch 1 fehlgeschlagen, Versuch 2 sofort ok).
    # Ein einzelner Fehlversuch würde sonst einen ganzen Lauf grundlos abbrechen;
    # ein wirklich fehlendes Profil scheitert auch nach fünf Versuchen.
    local attempt
    for attempt in 1 2 3 4 5; do
        xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
            >/dev/null 2>&1 && return 0
        sleep 3
    done
    echo "FEHLER: notarytool-Keychain-Profil '$NOTARY_PROFILE' nicht" >&2
    echo "verwendbar. Einmalig einrichten oder NOTARY_PROFILE setzen." >&2
    return 2
}

# Beide App-Bundles bei Apple notarisieren und das Ticket ANHEFTEN.
#
# notarytool nimmt kein nacktes .app entgegen, deshalb wandern beide Bundles in
# EIN Zip — ein Upload statt zwei, und Apple notarisiert den gesamten Inhalt.
# Gestapelt wird anschließend jedes Bundle einzeln: Nur ein angeheftetes Ticket
# überzeugt Gatekeeper auch ohne Netz, und genau das braucht eine App, die unter
# /Applications liegt oder aus einem DMG herausgezogen wird.
notarize_apps() {
    echo "== Bundles notarisieren (Profil: $NOTARY_PROFILE) =="
    local stage zip app
    stage=$(mktemp -d)
    mkdir "$stage/Favenio"
    for app in "${FAVENIO_APPS[@]}"; do
        [ -d "$app" ] || { echo "FEHLER: $app fehlt — zuerst bauen." >&2
                           rm -rf "$stage"; return 2; }
        ditto "$app" "$stage/Favenio/$app"
    done
    zip="$stage/favenio-apps.zip"
    # --keepParent behält den Ordner „Favenio" im Archiv; --sequesterRsrc legt
    # erweiterte Attribute normgerecht ab, sonst meckert die Notarisierung.
    ditto -c -k --keepParent --sequesterRsrc "$stage/Favenio" "$zip"

    if ! xcrun notarytool submit "$zip" \
            --keychain-profile "$NOTARY_PROFILE" --wait; then
        echo "FEHLER: Notarisierung der Bundles fehlgeschlagen." >&2
        rm -rf "$stage"
        return 2
    fi
    rm -rf "$stage"

    for app in "${FAVENIO_APPS[@]}"; do
        xcrun stapler staple "$app"
        # Beweis statt Vertrauen: angeheftetes Ticket UND Gatekeeper-Urteil.
        xcrun stapler validate "$app"
        spctl --assess --type execute -v "$app"
    done
    echo "Beide Bundles notarisiert und gestapelt."
}

# Prüft ein Bundle so, wie das System es beim Start prüft. Nach dem Kopieren
# zählt nur noch, was wirklich am Zielort liegt.
#
# Das angeheftete Ticket ist ohne Ausnahme Pflicht. Früher galt das nur für
# frisch notarisierte Bundles: Bei sehr alten DMGs hing das Ticket am Image
# statt am Bundle, und ein solches Bundle kam mit einem bloßen Hinweis durch.
# Das widersprach der Zusage im Kopf von install.sh und in beiden READMEs.
# Entschieden am 2026-08-03: In /Applications gehören nur notarisierte und
# gestapelte Builds; Ad-hoc-Builds bleiben im Projektverzeichnis, und ein
# altes DMG ohne angeheftetes Ticket wird abgelehnt.
notarize_verify_installed() {
    local app="$1"
    codesign --verify --strict "$app" || return 2
    spctl --assess --type execute "$app" >/dev/null 2>&1 || return 2
    if ! xcrun stapler validate "$app" >/dev/null 2>&1; then
        echo "FEHLER: $app trägt kein angeheftetes Notary-Ticket." >&2
        return 2
    fi
}

# Prüft, ob ein Bundle wirklich das Favenio-Bundle dieses Namens ist.
#
# Gatekeeper und `codesign --verify` beantworten nur „gültig signiert und
# notarisiert", nicht „von diesem Produkt". Deshalb hier zusätzlich die
# Bundle-ID gegen FAVENIO_BUNDLE_IDS und — wenn ein Team bekannt ist — den
# Herausgeber gegen dieses Team.
#
# Das Entwickler-Team steht bewusst nicht im öffentlichen Repo (wie schon der
# Notary-Profilname): Es kommt aus FAVENIO_TEAM_ID oder clone-lokal aus
# `git config --local favenio.teamId`. Ohne Angabe entfällt nur diese eine
# zusätzliche Prüfung; alle anderen bleiben.
#
# Argumente: <bundlepfad> <bundlename, z. B. Favenio.app>
# Rückgabe: 0 = passt, 2 = fremdes Bundle.
favenio_verify_identity() {
    local path="$1" app="$2"
    local expected="${FAVENIO_BUNDLE_IDS[$app]:-}"
    if [ -z "$expected" ]; then
        echo "FEHLER: keine erwartete Bundle-ID für $app hinterlegt." >&2
        return 2
    fi
    local actual
    actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$path/Contents/Info.plist" 2>/dev/null || true)
    if [ "$actual" != "$expected" ]; then
        echo "FEHLER: $app trägt die Bundle-ID '${actual:-keine}' statt" \
             "'$expected' — das ist nicht Favenio." >&2
        return 2
    fi
    local team="${FAVENIO_TEAM_ID:-}"
    if [ -z "$team" ]; then
        team="$(git config --local --get favenio.teamId 2>/dev/null || true)"
    fi
    if [ -n "$team" ]; then
        if ! codesign --verify \
            -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\"" \
            "$path" 2>/dev/null; then
            echo "FEHLER: $app stammt nicht vom erwarteten Entwickler-Team." >&2
            return 2
        fi
    fi
    return 0
}

# Prüft, auf welchen Update-Feed ein Bundle zeigt.
#
# build-app.sh erlaubt über die Umgebungsvariable SPARKLE_FEED_URL bewusst
# einen anderen Feed — das braucht der Sparkle-E2E-Test. install.sh und
# release.sh reichen die Umgebung aber unverändert an build-app.sh weiter,
# und eine geerbte Variable würde eine notarisiert installierte oder
# ausgelieferte App dauerhaft auf einen fremden Feed richten. Das wäre nicht
# nur ein Testartefakt, sondern ein Update-Kanal, den nicht mehr wir
# bestimmen. Deshalb hier fail-closed: Abweichung = Abbruch. Zum Testen bleibt
# build-app.sh, dessen Bundles im Projektverzeichnis liegen.
#
# Argumente: <bundlepfad> <bundlename, z. B. Favenio.app>
# Rückgabe: 0 = Produktions-Feed, 2 = fremder oder fehlender Feed.
favenio_verify_feed_url() {
    local path="$1" app="$2"
    local actual
    actual=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' \
        "$path/Contents/Info.plist" 2>/dev/null || true)
    if [ "$actual" != "$FAVENIO_FEED_URL" ]; then
        echo "FEHLER: $app sucht Updates unter '${actual:-keiner URL}' statt" >&2
        echo "'$FAVENIO_FEED_URL' — vermutlich ein geerbtes SPARKLE_FEED_URL." >&2
        return 2
    fi
    return 0
}

# Kennung eines Verzeichniseintrags: Gerätenummer und Inode.
#
# Der Name eines Bundles beweist nichts darüber, WELCHES Bundle gerade unter
# diesem Namen liegt. Diese Kennung schon: Sie bleibt beim Umbenennen erhalten
# und ändert sich, sobald ein anderer Ordner an denselben Platz kommt.
# Leere Ausgabe heißt: Da liegt (nichts mehr) — der Aufrufer entscheidet.
_favenio_dir_id() {
    /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null || true
}

# Den Zielordner für die Dauer des Austauschs für andere Läufe sperren.
#
# `mkdir` ist der klassische atomare Test-und-Setz-Schritt: Entweder legt genau
# ein Lauf das Verzeichnis an, oder er weiß sicher, dass schon einer arbeitet.
# Ohne diese Sperre könnten zwei gleichzeitige Installationen ineinander
# laufen — der Rollback des ersten träfe dann das frisch eingesetzte Bundle des
# zweiten. Absichtlich keine automatische Übernahme einer liegen gebliebenen
# Sperre: Das wäre selbst wieder ein Rennen. install.sh räumt seine eigene
# Sperre auch bei Abbruch weg (Aufräum-Trap); bleibt sie nach einem harten
# Abschuss liegen, nennt die Meldung den Weg von Hand.
#
# Argumente: <sperrverzeichnis>
# Rückgabe: 0 = Sperre gehört uns, 2 = ein anderer Lauf arbeitet dort.
_favenio_install_lock() {
    local lock="$1"
    if mkdir "$lock" 2>/dev/null; then
        echo $$ >"$lock/pid" 2>/dev/null || true
        return 0
    fi
    # mkdir kann auch an fehlenden Schreibrechten scheitern — dann läuft dort
    # kein zweiter Lauf, und die Meldung darf das nicht behaupten.
    if [ ! -d "$lock" ]; then
        echo "FEHLER: Sperrverzeichnis $lock nicht anlegbar." >&2
        return 2
    fi
    local owner
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    echo "FEHLER: Es läuft bereits eine Favenio-Installation in denselben" >&2
    echo "Zielordner${owner:+ (Prozess $owner)} — deren Ende abwarten." >&2
    echo "Sperre: $lock (nach hartem Abbruch von Hand entfernen)." >&2
    return 2
}

# Sperre wieder abnehmen. Ein Fehler dabei kostet keine Installation, blockiert
# aber den nächsten Lauf — deshalb wird er gemeldet und nicht verschluckt.
_favenio_install_unlock() {
    local lock="$1"
    [ -n "$lock" ] || return 0
    if ! rm -rf "$lock"; then
        echo "WARNUNG: Sperre $lock ließ sich nicht abnehmen." >&2
    fi
    # Der Aufräum-Trap von install.sh darf sie später nicht noch einmal
    # entfernen — dann träfe er womöglich die Sperre eines anderen Laufs.
    FAVENIO_INSTALL_LOCK=""
}

# Beide Bundles als EINE Transaktion nach <zielordner> bringen.
#
# Ablauf: erst BEIDE Bundles vollständig daneben kopieren und dort prüfen,
# dann die alten Stände zur Seite sichern, tauschen und am Zielort erneut
# prüfen. Scheitert irgendein Schritt, kommen beide alten Stände zurück.
# Vorher wurde jedes Bundle einzeln gelöscht und ersetzt: Ein Fehler beim
# zweiten Bundle hinterließ dann eine halb aktualisierte oder fehlende
# Installation, obwohl install.sh für jeden Fehler „nichts installiert"
# verspricht.
#
# Der ganze Austausch läuft unter einer Sperre auf den Zielordner, damit zwei
# Läufe sich nicht abwechselnd dasselbe Bundle wegnehmen.
#
# Argumente: <quellordner> <zielordner>
# Rückgabe: 0 = beide installiert und geprüft, 2 = alter Stand wiederhergestellt.
favenio_install_bundles() {
    local source_dir="$1" dest="$2"
    local app
    # Was dieser Lauf schon eingesetzt hat, je Eintrag "Name|Kennung". Diese
    # Bundles müssen beim Zurückrollen weg — auch wenn es gar keinen alten
    # Stand gibt: Bei einer ERSTinstallation existiert kein Backup, und ohne
    # diese Liste blieben die neuen Bundles trotz Fehler und Exit 2 liegen.
    # Die Kennung gehört dazu, weil der Name allein nicht beweist, dass dort
    # noch UNSER Bundle liegt.
    local installed=()
    # Ablage- und Sicherungsordner tragen die Prozessnummer, damit zwei Läufe
    # sich nicht ins Gehege kommen. Sie liegen IM Zielordner, denn nur dann
    # ist das spätere Umbenennen ein Vorgang innerhalb desselben Dateisystems.
    local stage="$dest/.favenio-install.$$"
    local backup="$dest/.favenio-previous.$$"
    local lock="$dest/.favenio-install.lock"
    _favenio_install_lock "$lock" || return 2
    # Damit der Aufräum-Trap von install.sh die Sperre auch bei Ctrl-C wieder
    # abnimmt; die Funktion selbst räumt sie auf jedem eigenen Weg weg.
    FAVENIO_INSTALL_LOCK="$lock"
    rm -rf "$stage" "$backup"
    if ! mkdir -p "$stage" "$backup"; then
        echo "FEHLER: Ablageordner in $dest nicht anlegbar." >&2
        _favenio_install_restore "$dest" "$stage" "$backup" "$lock"
        return 2
    fi

    # 1. Danebenlegen und dort schon prüfen: Vor dem ersten Eingriff steht
    #    fest, dass beide Kopien vollständig und gültig sind.
    for app in "${FAVENIO_APPS[@]}"; do
        if ! ditto "$source_dir/$app" "$stage/$app"; then
            echo "FEHLER: $app ließ sich nicht nach $dest kopieren." >&2
            _favenio_install_restore "$dest" "$stage" "$backup" "$lock" \
                "${installed[@]}"
            return 2
        fi
        if ! notarize_verify_installed "$stage/$app"; then
            echo "FEHLER: kopierte $app ist nicht notarisiert/gültig." >&2
            _favenio_install_restore "$dest" "$stage" "$backup" "$lock" \
                "${installed[@]}"
            return 2
        fi
    done

    # 2. Alten Stand sichern und tauschen. Beides sind Umbenennungen im
    #    selben Ordner — kein Zeitfenster, in dem gar keine App da ist.
    for app in "${FAVENIO_APPS[@]}"; do
        if [ -d "$dest/$app" ] && ! mv "$dest/$app" "$backup/$app"; then
            echo "FEHLER: alte $app ließ sich nicht sichern." >&2
            _favenio_install_restore "$dest" "$stage" "$backup" "$lock" \
                "${installed[@]}"
            return 2
        fi
        if ! mv "$stage/$app" "$dest/$app"; then
            echo "FEHLER: neue $app ließ sich nicht einsetzen." >&2
            _favenio_install_restore "$dest" "$stage" "$backup" "$lock" \
                "${installed[@]}"
            return 2
        fi
        # Ab hier liegt das neue Bundle am Zielort und gehört ins Rollback —
        # samt Kennung des eingesetzten Verzeichniseintrags.
        installed+=("$app|$(_favenio_dir_id "$dest/$app")")
        # Nach dem Tausch zählt nur noch, was WIRKLICH im Zielordner liegt.
        if ! notarize_verify_installed "$dest/$app"; then
            echo "FEHLER: installierte $app ist nicht notarisiert/gültig." >&2
            _favenio_install_restore "$dest" "$stage" "$backup" "$lock" \
                "${installed[@]}"
            return 2
        fi
        echo "  $app installiert und geprüft."
    done

    rm -rf "$stage" "$backup"
    _favenio_install_unlock "$lock"
    return 0
}

# Alten Stand zurückholen und die Zwischenordner aufräumen. Wird nur aus
# favenio_install_bundles gerufen (Unterstrich = intern).
#
# Argumente: <zielordner> <ablageordner> <sicherungsordner> <sperre>
#            [schon eingesetzte Bundles als "Name|Kennung" …]
# Rückgabe: 0 = alter Stand steht wieder, 2 = Rollback unvollständig. Der
# Aufrufer meldet ohnehin Exit 2; der Status ist für Tests und künftige
# Aufrufer da, die Begründung steht auf stderr.
_favenio_install_restore() {
    local dest="$1" stage="$2" backup="$3" lock="$4"
    shift 4
    local installed=("$@")
    local app entry expected current
    local failed=0
    # Zuerst alles wegräumen, was dieser Lauf schon eingesetzt hat. Das gilt
    # auch für Bundles ohne alten Stand: Bei einer Erstinstallation gibt es
    # kein Backup, und die Sicherungsschleife unten würde sie überspringen —
    # dann läge trotz Fehler und Exit 2 ein halb installierter Stand da.
    for entry in "${installed[@]}"; do
        app="${entry%%|*}"
        expected="${entry#*|}"
        current=$(_favenio_dir_id "$dest/$app")
        # Da liegt nichts mehr — nichts zurückzunehmen.
        [ -n "$current" ] || continue
        # Nach dem NAMEN zu löschen wäre falsch: Hat ein zweiter Lauf den
        # Zielpfad inzwischen ersetzt, nähmen wir ihm sein frisches Bundle weg.
        if [ "$current" != "$expected" ]; then
            echo "FEHLER: $dest/$app ist nicht mehr das Bundle dieses Laufs" \
                 "— vermutlich hat eine zweite Installation es ersetzt." \
                 "Es bleibt unangetastet." >&2
            failed=2
            continue
        fi
        # Geprüftes Umbenennen statt ungeprüftem `rm -rf`: Umbenennen im
        # selben Ordner gelingt ganz oder gar nicht, und ein Fehlschlag wird
        # hier gemeldet. `set -e` fängt ihn nicht auf — install.sh ruft
        # favenio_install_bundles in einer ||-Liste, dort ist errexit aus und
        # gilt auch in allen von dort gerufenen Funktionen nicht.
        if ! mv "$dest/$app" "$stage/rollback-$app"; then
            echo "FEHLER: eingesetzte $app ließ sich nicht wieder aus $dest" \
                 "entfernen — die Installation ist NICHT sauber" \
                 "zurückgenommen." >&2
            failed=2
        fi
    done
    for app in "${FAVENIO_APPS[@]}"; do
        [ -d "$backup/$app" ] || continue
        # Der Platz muss frei sein. Ist er belegt, gehört er nicht mehr uns
        # (oder das Wegräumen oben ist gescheitert) — dann lieber melden als
        # etwas Fremdes überschreiben.
        if [ -e "$dest/$app" ]; then
            echo "FEHLER: alte $app kann nicht zurück, weil $dest/$app belegt" \
                 "ist. Sie liegt weiter unter $backup." >&2
            failed=2
            continue
        fi
        if ! mv "$backup/$app" "$dest/$app"; then
            echo "FEHLER: $app ließ sich nicht zurückholen und liegt noch" \
                 "unter $backup." >&2
            failed=2
        fi
    done
    rm -rf "$stage"
    # rmdir statt rm -rf: Was hier noch liegt, ist ein nicht zurückgeholter
    # alter Stand — der darf nicht auch noch verschwinden.
    rmdir "$backup" 2>/dev/null || true
    _favenio_install_unlock "$lock"
    return $failed
}
