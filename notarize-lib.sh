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
# Zweites Argument „ticket": Das angeheftete Ticket ist Pflicht. Das gilt für
# frisch notarisierte Bundles. Kommen die Apps dagegen aus einem älteren DMG,
# hängt das Ticket am Image statt am Bundle; dann bleibt Gatekeeper der Maßstab,
# und das fehlende Ticket wird nur als Hinweis gemeldet (erster Start braucht
# dann Netz).
notarize_verify_installed() {
    local app="$1" require="${2:-}"
    codesign --verify --strict "$app" || return 2
    spctl --assess --type execute "$app" >/dev/null 2>&1 || return 2
    if ! xcrun stapler validate "$app" >/dev/null 2>&1; then
        if [ "$require" = "ticket" ]; then
            echo "FEHLER: $app trägt kein angeheftetes Notary-Ticket." >&2
            return 2
        fi
        echo "  Hinweis: $app ohne angeheftetes Ticket — der erste Start" \
             "braucht Netz."
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
# Argumente: <quellordner> <zielordner> [ticket]
# Rückgabe: 0 = beide installiert und geprüft, 2 = alter Stand wiederhergestellt.
favenio_install_bundles() {
    local source_dir="$1" dest="$2" require="${3:-}"
    local app
    # Ablage- und Sicherungsordner tragen die Prozessnummer, damit zwei Läufe
    # sich nicht ins Gehege kommen. Sie liegen IM Zielordner, denn nur dann
    # ist das spätere Umbenennen ein Vorgang innerhalb desselben Dateisystems.
    local stage="$dest/.favenio-install.$$"
    local backup="$dest/.favenio-previous.$$"
    rm -rf "$stage" "$backup"
    if ! mkdir -p "$stage" "$backup"; then
        echo "FEHLER: Ablageordner in $dest nicht anlegbar." >&2
        return 2
    fi

    # 1. Danebenlegen und dort schon prüfen: Vor dem ersten Eingriff steht
    #    fest, dass beide Kopien vollständig und gültig sind.
    for app in "${FAVENIO_APPS[@]}"; do
        if ! ditto "$source_dir/$app" "$stage/$app"; then
            echo "FEHLER: $app ließ sich nicht nach $dest kopieren." >&2
            _favenio_install_restore "$dest" "$stage" "$backup"
            return 2
        fi
        if ! notarize_verify_installed "$stage/$app" "$require"; then
            echo "FEHLER: kopierte $app ist nicht notarisiert/gültig." >&2
            _favenio_install_restore "$dest" "$stage" "$backup"
            return 2
        fi
    done

    # 2. Alten Stand sichern und tauschen. Beides sind Umbenennungen im
    #    selben Ordner — kein Zeitfenster, in dem gar keine App da ist.
    for app in "${FAVENIO_APPS[@]}"; do
        if [ -d "$dest/$app" ] && ! mv "$dest/$app" "$backup/$app"; then
            echo "FEHLER: alte $app ließ sich nicht sichern." >&2
            _favenio_install_restore "$dest" "$stage" "$backup"
            return 2
        fi
        if ! mv "$stage/$app" "$dest/$app"; then
            echo "FEHLER: neue $app ließ sich nicht einsetzen." >&2
            _favenio_install_restore "$dest" "$stage" "$backup"
            return 2
        fi
        # Nach dem Tausch zählt nur noch, was WIRKLICH im Zielordner liegt.
        if ! notarize_verify_installed "$dest/$app" "$require"; then
            echo "FEHLER: installierte $app ist nicht notarisiert/gültig." >&2
            _favenio_install_restore "$dest" "$stage" "$backup"
            return 2
        fi
        echo "  $app installiert und geprüft."
    done

    rm -rf "$stage" "$backup"
    return 0
}

# Alten Stand zurückholen und die Zwischenordner aufräumen. Wird nur aus
# favenio_install_bundles gerufen (Unterstrich = intern).
_favenio_install_restore() {
    local dest="$1" stage="$2" backup="$3" app
    for app in "${FAVENIO_APPS[@]}"; do
        [ -d "$backup/$app" ] || continue
        # Der halb eingesetzte neue Stand muss weg, bevor der alte
        # zurückkommt; deshalb hier ausnahmsweise löschen vor umbenennen.
        rm -rf "$dest/$app"
        if ! mv "$backup/$app" "$dest/$app"; then
            echo "FEHLER: $app ließ sich nicht zurückholen und liegt noch" \
                 "unter $backup." >&2
        fi
    done
    rm -rf "$stage"
    # rmdir statt rm -rf: Was hier noch liegt, ist ein nicht zurückgeholter
    # alter Stand — der darf nicht auch noch verschwinden.
    rmdir "$backup" 2>/dev/null || true
}
