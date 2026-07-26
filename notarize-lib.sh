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
