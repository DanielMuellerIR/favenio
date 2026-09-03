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
# Der öffentliche Sparkle-Schlüssel, gegen den die App den Appcast prüft, und
# die Pflicht zur Feed-Signatur. Beide gehören zum Update-Kanal genauso dazu wie
# die Feed-URL: Ein gültig signiertes DMG mit falschem Schlüssel oder
# abgeschalteter Signaturpflicht würde Updates ablehnen bzw. einen unsignierten
# Feed akzeptieren (Review-Fund 2026-08-17). Muss zu SPARKLE_PUBLIC_KEY in
# build-app.sh passen.
FAVENIO_SPARKLE_PUBLIC_KEY="H504COadHZVAKo+/XD0jzXT5PJzghkS2t/DDYmuHPDg="

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
    # (2026-07-26 in einem realen Lauf belegt: Versuch 1 fehlgeschlagen,
    # Versuch 2 war sofort erfolgreich).
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
    # Ein funktionslokaler EXIT-Trap läuft in zsh beim Verlassen der
    # Funktion — auch auf dem errexit-Pfad. Das ist hier nötig: Die
    # Funktion wird aus install.sh und release.sh NACKT aufgerufen, ein
    # scheiterndes `stapler staple` oder ein Abbruch während
    # `notarytool submit --wait` (typisch 1–10 Minuten) beendete das
    # Skript also sofort, und rund 40 MB Bundle-Kopien plus Zip blieben
    # unter /var/folders liegen — bei jedem Versuch aufs Neue.
    setopt localoptions localtraps
    local stage zip app
    stage=$(mktemp -d)
    # Der Pfad wird HIER eingesetzt, nicht erst beim Auslösen: `stage` ist
    # `local`, und wenn der EXIT-Trap läuft, ist die Funktion schon
    # verlassen — unter `set -u` scheiterte er dann an „parameter not set"
    # und riss den ganzen Lauf mit. `${(q)…}` maskiert den Pfad zsh-sicher.
    trap "rm -rf ${(q)stage}" EXIT HUP INT TERM
    mkdir "$stage/Favenio"
    for app in "${FAVENIO_APPS[@]}"; do
        [ -d "$app" ] || { echo "FEHLER: $app fehlt — zuerst bauen." >&2
                           return 2; }
        ditto "$app" "$stage/Favenio/$app"
    done
    zip="$stage/favenio-apps.zip"
    # --keepParent behält den Ordner „Favenio" im Archiv; --sequesterRsrc legt
    # erweiterte Attribute normgerecht ab, sonst meckert die Notarisierung.
    ditto -c -k --keepParent --sequesterRsrc "$stage/Favenio" "$zip"

    if ! xcrun notarytool submit "$zip" \
            --keychain-profile "$NOTARY_PROFILE" --wait; then
        echo "FEHLER: Notarisierung der Bundles fehlgeschlagen." >&2
        return 2
    fi

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
    # Die drei Pflichtprüfungen an EINER Stelle — vorher standen sie
    # zusätzlich ausgeschrieben in install.sh, und die Kopien waren schon
    # ungleich. Jede Prüfung nennt beim Scheitern sich selbst; ein bloßes
    # „ungültig" ließe offen, woran es lag.
    local app="$1"
    if ! codesign --verify --strict "$app"; then
        echo "FEHLER: Signatur von $app ungültig." >&2
        return 2
    fi
    if ! spctl --assess --type execute "$app" >/dev/null 2>&1; then
        echo "FEHLER: Gatekeeper akzeptiert $app nicht." >&2
        return 2
    fi
    # Das ANGEHEFTETE Ticket ist Pflicht, auch aus einem DMG. Nur damit
    # startet die App offline ohne Gatekeeper-Rückfrage. Sehr alte DMGs
    # tragen das Ticket bloß am Image; solche Bundles werden bewusst
    # abgelehnt (Entscheidung 2026-08-03), statt sie mit einem Hinweis
    # durchzulassen.
    if ! xcrun stapler validate "$app" >/dev/null 2>&1; then
        echo "FEHLER: $app trägt kein angeheftetes Notary-Ticket." >&2
        echo "Nur notarisierte und gestapelte Bundles dürfen installiert" >&2
        echo "werden. Ein aktuelles Release-DMG verwenden oder ohne --dmg" >&2
        echo "neu bauen und notarisieren." >&2
        return 2
    fi
}

# Liest die erwartete Entwickler-Team-ID aus Umgebung oder Clone. Die
# Installationsprüfung verwendet sie weiterhin optional; ein Release ruft
# favenio_require_team_id auf und macht sie damit zum harten Tor.
favenio_configured_team_id() {
    local team="${FAVENIO_TEAM_ID:-}"
    if [ -z "$team" ]; then
        team="$(git config --local --get favenio.teamId 2>/dev/null || true)"
    fi
    printf '%s\n' "$team"
}

favenio_team_id_is_valid() {
    local team="$1"
    [ "${#team}" -eq 10 ] && [[ "$team" != *[^A-Z0-9]* ]]
}

favenio_require_team_id() {
    local team
    team="$(favenio_configured_team_id)"
    if [ -z "$team" ]; then
        echo "FEHLER: Keine Entwickler-Team-ID für den Release bekannt." >&2
        echo "Entweder FAVENIO_TEAM_ID setzen oder einmalig für diesen Clone:" >&2
        echo "  git config --local favenio.teamId <team-id>" >&2
        return 2
    fi
    if ! favenio_team_id_is_valid "$team"; then
        echo "FEHLER: Die Entwickler-Team-ID muss aus genau zehn" >&2
        echo "Großbuchstaben oder Ziffern bestehen." >&2
        return 2
    fi
    FAVENIO_TEAM_ID="$team"
    export FAVENIO_TEAM_ID
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
    # `path` ist in zsh ein Spezialparameter und an PATH gekoppelt. Deshalb
    # hier ein ausdrücklicher Name: Sonst würde die lokale Variable genau das
    # anschließend benötigte `codesign` aus dem Suchpfad entfernen.
    local bundle_path="$1" app="$2"
    local expected="${FAVENIO_BUNDLE_IDS[$app]:-}"
    if [ -z "$expected" ]; then
        echo "FEHLER: keine erwartete Bundle-ID für $app hinterlegt." >&2
        return 2
    fi
    local actual
    actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$bundle_path/Contents/Info.plist" 2>/dev/null || true)
    if [ "$actual" != "$expected" ]; then
        echo "FEHLER: $app trägt die Bundle-ID '${actual:-keine}' statt" \
             "'$expected' — das ist nicht Favenio." >&2
        return 2
    fi
    local team
    team="$(favenio_configured_team_id)"
    if [ -n "$team" ]; then
        if ! favenio_team_id_is_valid "$team"; then
            echo "FEHLER: Ungültige Entwickler-Team-ID konfiguriert." >&2
            return 2
        fi
        if ! codesign --verify \
            -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\"" \
            "$bundle_path" 2>/dev/null; then
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
# Geprüft wird der GESAMTE Update-Kanal: Feed-URL, öffentlicher Schlüssel und
# die Pflicht zur Feed-Signatur. Die drei Werte ergeben nur zusammen einen
# Update-Weg, den wir bestimmen.
#
# Argumente: <bundlepfad> <bundlename, z. B. Favenio.app>
# Rückgabe: 0 = Produktions-Kanal, 2 = abweichender oder fehlender Wert.
favenio_verify_feed_url() {
    local bundle_path="$1" app="$2"
    local plist="$bundle_path/Contents/Info.plist"
    local actual key signed
    actual=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' \
        "$plist" 2>/dev/null || true)
    if [ "$actual" != "$FAVENIO_FEED_URL" ]; then
        echo "FEHLER: $app sucht Updates unter '${actual:-keiner URL}' statt" >&2
        echo "'$FAVENIO_FEED_URL' — vermutlich ein geerbtes SPARKLE_FEED_URL." >&2
        return 2
    fi
    key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
        "$plist" 2>/dev/null || true)
    if [ "$key" != "$FAVENIO_SPARKLE_PUBLIC_KEY" ]; then
        echo "FEHLER: $app prüft den Appcast mit '${key:-keinem Schlüssel}'" >&2
        echo "statt mit dem Produktionsschlüssel — Updates würden abgelehnt." >&2
        return 2
    fi
    # PlistBuddy schreibt einen Boolean als "true"/"false".
    signed=$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' \
        "$plist" 2>/dev/null || true)
    if [ "$signed" != "true" ]; then
        echo "FEHLER: $app verlangt keine signierte Appcast-Datei" >&2
        echo "(SURequireSignedFeed = '${signed:-fehlt}') — ein unsignierter" >&2
        echo "Feed wäre damit akzeptabel." >&2
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

# Eine für diesen Lauf eindeutige Kennung für Ablage- und Sicherungsordner.
#
# Die Prozessnummer allein reicht nicht: macOS vergibt PIDs wieder, und ein
# liegen gebliebener Ordner aus einem hart abgebrochenen Lauf kann denselben
# Namen tragen (Review-Fund 2026-08-17). Mit Zeitstempel und Zufallsanteil
# kollidiert ein neuer Lauf praktisch nie — und wenn doch, scheitert `mkdir`
# und der alte Stand bleibt unangetastet.
_favenio_install_token() {
    printf '%s-%s-%s' "$$" "$(/bin/date +%s)" \
        "$(/usr/bin/hexdump -n 4 -e '"%08x"' /dev/urandom)"
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
# --- Kritische Abschnitte: Abbruch merken statt verwerfen ---
#
# In den wenigen Befehlen, in denen Sperr- oder Ordnerbesitz noch nicht
# eindeutig ist, darf ein Abbruchsignal nicht ZUGESTELLT werden. Es darf aber
# auch nicht verlorengehen: `trap '' HUP INT TERM` verwarf es ersatzlos, die
# Installation lief danach trotz Abbruchwunsch weiter und konnte beide Apps
# ersetzen (Review-Fund 2026-08-21). Stattdessen merkt ein Handler das Signal
# nur, und sobald der Besitz feststeht, führt der Code den passenden
# Abbruchhandler selbst aus.
#
# Die drei `trap`-Zeilen stehen deshalb ÜBERALL AUSGESCHRIEBEN und nicht in
# einer gemeinsamen Hilfsfunktion: Unter `localtraps` — und das ist hier
# durchgehend gesetzt — gilt ein in einer Funktion gesetzter Trap nur bis zu
# deren Rückkehr. Eine Hilfsfunktion `set_traps; …` hinterließe also gar keinen
# aktiven Handler mehr; nachgemessen mit zsh, das Signal ging dabei komplett
# verloren.
#
#     FAVENIO_INSTALL_PENDING_SIGNAL=""
#     trap 'FAVENIO_INSTALL_PENDING_SIGNAL=HUP' HUP
#     trap 'FAVENIO_INSTALL_PENDING_SIGNAL=INT' INT
#     trap 'FAVENIO_INSTALL_PENDING_SIGNAL=TERM' TERM
#
# Danach jeweils `_favenio_install_signal_pending` prüfen.

# Wahr, wenn während eines kritischen Abschnitts ein Abbruch angefordert wurde.
_favenio_install_signal_pending() {
    [ -n "${FAVENIO_INSTALL_PENDING_SIGNAL:-}" ]
}

# mkdir für die kritischen Abschnitte: Die Merk-Traps oben halten nur die
# zsh selbst am Leben. Der gestartete mkdir-Prozess bekommt HUP, INT und TERM
# mit Standardverhalten — ein Ctrl-C im Terminal geht an die ganze
# Prozessgruppe. Legt mkdir den Ordner an und stirbt danach am Signal, meldet
# es Status 130 bis 143, und die eigene Sperre gälte als fremd beziehungsweise
# der eigene Ablageordner als nicht erworben (Review-Fund 2026-09-02).
# Deshalb läuft mkdir in einer Unterschale, die diese Signale ignoriert; das
# Ignorieren erbt der Kindprozess. Die aufrufende zsh merkt sich das Signal
# weiterhin und führt es nach dem kritischen Abschnitt aus.
_favenio_install_mkdir_shielded() {
    ( trap '' HUP INT TERM; mkdir "$1" )
}

_favenio_install_lock() {
    # Zwischen dem erfolgreichen mkdir und dem Merken des Besitzes darf kein
    # weiches Signal zugestellt werden: Der Signal-Handler könnte die gerade
    # erworbene Sperre sonst noch nicht als unsere erkennen. Die wenigen
    # Befehle dieses atomaren Erwerbs laufen deshalb als kritischer Abschnitt.
    # Die Merkvariable ist bewusst NICHT lokal — der Aufrufer wertet sie nach
    # der Rückkehr aus. Traps ausgeschrieben, siehe Erklärung oben.
    setopt localoptions localtraps
    FAVENIO_INSTALL_PENDING_SIGNAL=""
    trap 'FAVENIO_INSTALL_PENDING_SIGNAL=HUP' HUP
    trap 'FAVENIO_INSTALL_PENDING_SIGNAL=INT' INT
    trap 'FAVENIO_INSTALL_PENDING_SIGNAL=TERM' TERM
    local lock="$1"
    if _favenio_install_mkdir_shielded "$lock" 2>/dev/null; then
        FAVENIO_INSTALL_LOCK="$lock"
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
    # Entfernen und Besitzfreigabe gehören zusammen. Sonst könnte zwischen
    # `rm` und dem Leeren der Variablen ein spätes Signal die inzwischen neu
    # angelegte Sperre eines zweiten Laufs unter demselben Namen löschen.
    setopt localoptions localtraps
    trap '' HUP INT TERM
    local lock="$1"
    [ -n "$lock" ] || return 0
    [ "${FAVENIO_INSTALL_LOCK:-}" = "$lock" ] || return 0
    if ! rm -rf "$lock"; then
        echo "WARNUNG: Sperre $lock ließ sich nicht abnehmen." >&2
    fi
    # Der Aufräum-Trap von install.sh darf sie später nicht noch einmal
    # entfernen — dann träfe er womöglich die Sperre eines anderen Laufs.
    FAVENIO_INSTALL_LOCK=""
}

# Ein weiches Abbruchsignal darf die Transaktion nicht zwischen den beiden
# Bundles stehen lassen. Die lokalen Werte aus favenio_install_bundles sind in
# zsh auch für diesen dynamisch aufgerufenen Handler sichtbar. Nach dem
# Rollback endet der ganze Installationsprozess mit dem passenden
# Vertragsstatus; ein bloßes `return` aus einem zsh-Trap würde den Aufrufer
# dagegen mit Status 0 weiterlaufen lassen.
#
# Der frühe Handler gilt für das kurze Stück zwischen dem erfolgreichen
# Sperren und dem Anlegen von Ablage- und Sicherungsordner. Dort ist noch
# nichts angefasst worden, es gibt also nichts zurückzuholen — aber die Sperre
# gehört bereits uns. Ohne eigenen Handler stirbt die Shell am Signal, und der
# EXIT-Trap von install.sh läuft dann gar nicht mehr; die Sperre blieb liegen
# und blockierte jede weitere Installation (Review-Fund 2026-08-20, mit einem
# Signaltest nachgemessen).
_favenio_install_interrupted_early() {
    local lock="${FAVENIO_INSTALL_LOCK:-}"
    echo "FEHLER: Installation abgebrochen; es wurde nichts installiert." >&2
    # Leer heißt: Die Sperre wurde noch nicht erworben oder bereits sauber
    # freigegeben. Dann gehört ein gleichnamiger Pfad womöglich einem neuen
    # Lauf und bleibt unangetastet.
    [ -n "$lock" ] && _favenio_install_unlock "$lock"
    exit 2
}

# Nach dem Anlegen des eigenen Ablageordners, aber vor dem erfolgreichen
# Anlegen des Sicherungsordners darf der volle Rollback noch NICHT laufen:
# Der Sicherungspfad könnte bei einem mkdir-Fehler einem fremden Lauf gehören.
# In dieser Phase gehören uns nachweislich nur Ablageordner und Sperre.
_favenio_install_interrupted_stage() {
    local stage="$1" lock="$2"
    if [ "${FAVENIO_INSTALL_LOCK:-}" != "$lock" ]; then
        exit 2
    fi
    echo "FEHLER: Installation abgebrochen; es wurde nichts installiert." >&2
    setopt localoptions localtraps
    trap '' HUP INT TERM
    if ! rmdir "$stage" 2>/dev/null; then
        echo "WARNUNG: Ablageordner $stage blieb stehen." >&2
    fi
    _favenio_install_unlock "$lock"
    exit 2
}

_favenio_install_interrupted() {
    local dest="$1" stage="$2" backup="$3" lock="$4"
    shift 4
    # Nach einem bereits abgeschlossenen Rollback ist die globale Sperre leer.
    # In diesem winzigen Rückkehrfenster darf ein spätes Signal keine Sperre
    # entfernen, die inzwischen schon einem neuen Lauf gehört.
    if [ "${FAVENIO_INSTALL_LOCK:-}" != "$lock" ]; then
        # Der alte Stand kam zuvor vollständig zurück — das ist Exit 2
        # („nichts geändert"), nicht Exit 3. Exit 3 verspricht auf stderr
        # verbliebene Pfade, und die gibt es hier gerade nicht
        # (Review-Fund 2026-08-17).
        if [ "${FAVENIO_INSTALL_ROLLED_BACK:-}" = "$lock" ]; then
            echo "FEHLER: Installation abgebrochen; alter Stand ist" \
                 "vollständig zurückgeholt." >&2
            exit 2
        fi
        exit 3
    fi
    echo "FEHLER: Installation abgebrochen; alter Stand wird zurückgeholt." >&2
    if _favenio_install_restore "$dest" "$stage" "$backup" "$lock" "$@"; then
        exit 2
    fi
    exit 3
}

# Einheitliche Fehlerantwort nach einem begonnenen Installationsversuch:
# 2, wenn der alte Stand vollständig zurückkam; 3, wenn die Rückholung selbst
# scheiterte und der auf stderr genannte verbleibende Zustand manuell geklärt
# werden muss. So kann Exit 2 weiterhin zuverlässig „nichts geändert" bedeuten.
_favenio_install_failure() {
    if _favenio_install_restore "$@"; then
        return 2
    fi
    return 3
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
# Rückgabe: 0 = beide installiert und geprüft, 2 = alter Stand wiederhergestellt,
#           3 = Rollback unvollständig (verbleibende Pfade auf stderr).
favenio_install_bundles() {
    # Signal-Traps gelten nur für diesen Funktionsaufruf. Ein aufrufendes
    # Skript behält danach seine eigenen Handler.
    setopt localoptions localtraps
    local source_dir="$1" dest="$2"
    local app staged_id
    # Was dieser Lauf schon eingesetzt hat, je Eintrag "Name|Kennung". Diese
    # Bundles müssen beim Zurückrollen weg — auch wenn es gar keinen alten
    # Stand gibt: Bei einer ERSTinstallation existiert kein Backup, und ohne
    # diese Liste blieben die neuen Bundles trotz Fehler und Exit 2 liegen.
    # Die Kennung gehört dazu, weil der Name allein nicht beweist, dass dort
    # noch UNSER Bundle liegt.
    local installed=()
    # Ablage- und Sicherungsordner liegen IM Zielordner, denn nur dann ist das
    # spätere Umbenennen ein Vorgang innerhalb desselben Dateisystems.
    #
    # Ihr Name kam früher allein aus der Prozessnummer, und vorhandene
    # gleichnamige Pfade wurden blind gelöscht. Nach einem harten Abbruch, dem
    # dokumentierten manuellen Entfernen der Sperre und einer später
    # wiederverwendeten PID konnte dort noch der NICHT zurückgeholte alte Stand
    # liegen — ein neuer Lauf hätte ihn gelöscht (Review-Fund 2026-08-17).
    # Deshalb: exklusiv erzeugte, zufällig benannte Ordner. `mkdir` scheitert,
    # wenn der Name schon existiert; ein unbekannter Altpfad wird nie
    # automatisch entfernt.
    local lock="$dest/.favenio-install.lock"
    # Der Handler steht schon VOR dem Sperrversuch. Den eigentlichen atomaren
    # Erwerb schützt _favenio_install_lock als kurzen signalarmen Abschnitt
    # und trägt den Besitz dort direkt in FAVENIO_INSTALL_LOCK ein.
    FAVENIO_INSTALL_LOCK=""
    trap '_favenio_install_interrupted_early' HUP INT TERM
    _favenio_install_lock "$lock" || return 2
    # Kam während des Sperrerwerbs ein Abbruchsignal? Der Besitz ist jetzt
    # eindeutig, also wird der Wunsch hier ausgeführt statt verworfen.
    if _favenio_install_signal_pending; then
        _favenio_install_interrupted_early
    fi
    local token stage backup
    token=$(_favenio_install_token)
    stage="$dest/.favenio-install.$token"
    backup="$dest/.favenio-previous.$token"
    # KEIN `rm -rf` vorweg: `mkdir` ohne -p scheitert, wenn der Pfad schon da
    # ist, und genau das ist hier die gewünschte Antwort.
    #
    # Und einzeln statt `mkdir "$stage" "$backup"`: Zwei Operanden bearbeitet
    # `mkdir` UNABHÄNGIG voneinander. Existierte einer der beiden Pfade schon,
    # legte es den anderen trotzdem an und meldete danach nur einen Fehler —
    # der gemeinsame Rollback bekam so einen FREMDEN Pfad in die Hand, löschte
    # ihn rekursiv und hätte Bundles aus einer fremden Sicherung sogar nach
    # $dest geschoben (Review-Fund 2026-08-20, reproduziert). Aufgeräumt wird
    # hier deshalb nur, was dieser Lauf nachweislich selbst erzeugt hat.
    # mkdir und der dazu passende Handler-Wechsel sind jeweils EIN kritischer
    # Abschnitt. Ein dort eintreffendes weiches Signal wird für diese wenigen
    # Befehle ignoriert; danach ist immer ein Handler aktiv, der exakt die bis
    # dahin nachweislich eigenen Pfade kennt.
    FAVENIO_INSTALL_PENDING_SIGNAL=""
    trap 'FAVENIO_INSTALL_PENDING_SIGNAL=HUP' HUP
    trap 'FAVENIO_INSTALL_PENDING_SIGNAL=INT' INT
    trap 'FAVENIO_INSTALL_PENDING_SIGNAL=TERM' TERM
    if ! _favenio_install_mkdir_shielded "$stage"; then
        trap '_favenio_install_interrupted_early' HUP INT TERM
        echo "FEHLER: Ablageordner $stage nicht anlegbar." >&2
        _favenio_install_unlock "$lock"
        return 2
    fi
    trap '_favenio_install_interrupted_stage "$stage" "$lock"' HUP INT TERM
    if _favenio_install_signal_pending; then
        _favenio_install_interrupted_stage "$stage" "$lock"
    fi
    FAVENIO_INSTALL_PENDING_SIGNAL=""
    trap 'FAVENIO_INSTALL_PENDING_SIGNAL=HUP' HUP
    trap 'FAVENIO_INSTALL_PENDING_SIGNAL=INT' INT
    trap 'FAVENIO_INSTALL_PENDING_SIGNAL=TERM' TERM
    if ! _favenio_install_mkdir_shielded "$backup"; then
        trap '_favenio_install_interrupted_stage "$stage" "$lock"' HUP INT TERM
        echo "FEHLER: Sicherungsordner $backup nicht anlegbar." >&2
        # `rmdir` statt `rm -rf`: Der eigene Ablageordner ist gerade erst
        # entstanden und leer; ist er es wider Erwarten nicht, bleibt er
        # lieber stehen.
        if ! rmdir "$stage" 2>/dev/null; then
            echo "WARNUNG: Ablageordner $stage blieb stehen." >&2
        fi
        _favenio_install_unlock "$lock"
        return 2
    fi
    # Ab hier räumen INT, TERM und HUP Ablage, Sicherung und eingesetzte
    # Bundles gemeinsam auf; die Variablen sehen beim Signal die aktuelle
    # Liste. Beide Ordner gehören jetzt sicher diesem Lauf.
    trap '_favenio_install_interrupted "$dest" "$stage" "$backup" "$lock" "${installed[@]}"' \
        HUP INT TERM
    if _favenio_install_signal_pending; then
        _favenio_install_interrupted "$dest" "$stage" "$backup" "$lock" \
            "${installed[@]}"
    fi

    # 1. Danebenlegen und dort schon prüfen: Vor dem ersten Eingriff steht
    #    fest, dass beide Kopien vollständig und gültig sind.
    for app in "${FAVENIO_APPS[@]}"; do
        if ! ditto "$source_dir/$app" "$stage/$app"; then
            echo "FEHLER: $app ließ sich nicht nach $dest kopieren." >&2
            _favenio_install_failure "$dest" "$stage" "$backup" "$lock" \
                "${installed[@]}"
            return $?
        fi
        if ! notarize_verify_installed "$stage/$app"; then
            echo "FEHLER: kopierte $app ist nicht notarisiert/gültig." >&2
            _favenio_install_failure "$dest" "$stage" "$backup" "$lock" \
                "${installed[@]}"
            return $?
        fi
    done

    # 2. Alten Stand sichern und tauschen. Beides sind Umbenennungen im
    #    selben Ordner — kein Zeitfenster, in dem gar keine App da ist.
    for app in "${FAVENIO_APPS[@]}"; do
        if [ -d "$dest/$app" ] && ! mv "$dest/$app" "$backup/$app"; then
            echo "FEHLER: alte $app ließ sich nicht sichern." >&2
            _favenio_install_failure "$dest" "$stage" "$backup" "$lock" \
                "${installed[@]}"
            return $?
        fi
        # Die Kennung VOR dem Umbenennen notieren: Sie bleibt beim atomaren mv
        # erhalten. Trifft ein Signal direkt nach dem mv ein, kennt der
        # Rollback das neue Bundle damit schon und verwechselt es nicht mit
        # einem fremden, parallel eingesetzten Verzeichniseintrag.
        staged_id=$(_favenio_dir_id "$stage/$app")
        if [ -z "$staged_id" ]; then
            echo "FEHLER: Kennung der neuen $app ließ sich nicht lesen." >&2
            _favenio_install_failure "$dest" "$stage" "$backup" "$lock" \
                "${installed[@]}"
            return $?
        fi
        installed+=("$app|$staged_id")
        if ! mv "$stage/$app" "$dest/$app"; then
            echo "FEHLER: neue $app ließ sich nicht einsetzen." >&2
            _favenio_install_failure "$dest" "$stage" "$backup" "$lock" \
                "${installed[@]}"
            return $?
        fi
        # Nach dem Tausch zählt nur noch, was WIRKLICH im Zielordner liegt.
        if ! notarize_verify_installed "$dest/$app"; then
            echo "FEHLER: installierte $app ist nicht notarisiert/gültig." >&2
            _favenio_install_failure "$dest" "$stage" "$backup" "$lock" \
                "${installed[@]}"
            return $?
        fi
        echo "  $app installiert und geprüft."
    done

    # Beide Bundles sind jetzt eingesetzt und am Ziel geprüft: Die Transaktion
    # ist fachlich abgeschlossen. Während des kurzen Entfernens der alten
    # Kopien wird ein Signal ignoriert, denn ein Rollback ohne die womöglich
    # schon gelöschte Sicherung würde gerade erst einen halben Stand erzeugen.
    trap '' HUP INT TERM
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
# Aufrufer übersetzt Letzteres in den öffentlichen Exit 3; die Begründung steht
# auf stderr.
_favenio_install_restore() {
    # Ein einmal begonnener Rollback ist die Datenrettung. Weitere weiche
    # Abbruchsignale werden für diese kurze kritische Phase ignoriert, damit
    # beide alten Bundles vollständig zurückkehren.
    setopt localoptions localtraps
    trap '' HUP INT TERM
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
    # Ergebnis dieses Rollbacks festhalten, BEVOR die Sperre fällt: Ein spätes
    # weiches Signal im Rückkehrfenster sieht danach nur noch die leere globale
    # Sperre und könnte einen vollständigen Rollback sonst als unvollständig
    # melden (Review-Fund 2026-08-17).
    if [ "$failed" -eq 0 ]; then
        FAVENIO_INSTALL_ROLLED_BACK="$lock"
    else
        FAVENIO_INSTALL_ROLLED_BACK=""
    fi
    _favenio_install_unlock "$lock"
    return $failed
}
