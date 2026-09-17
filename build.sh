#!/bin/zsh
# build.sh — einheitlicher Einstieg zum Bauen. Das Projekt stellt build.sh,
# install.sh und release.sh als stabile Einstiegspunkte an der Repo-Wurzel bereit.
#
# Baut nur: keine Notarisierung, keine Installation. Ohne Developer-ID im
# Schlüsselbund signiert build-app.sh ad hoc — eine Signatur ist also keine
# Voraussetzung. Die eigentliche Arbeit macht build-app.sh, das seinen Namen
# wegen Tests, CI und Doku behält; Umgebungsvariablen (FAVENIO_SIGN_ID,
# SPARKLE_FEED_URL, …) gehen unverändert durch, der Exit-Code ist der von
# build-app.sh (exec ersetzt diesen Prozess).
#
# Aufruf:  ./build.sh   (ohne Argumente; sonst Exit 2)
# Letzte Zeile bei Erfolg: BUILD OK: <ordner>/Favenio.app <ordner>/FavenioQuick.app
# Der Ordner ist zweimal derselbe und darf Leerzeichen enthalten (unmaskiert):
# Die Zeile deshalb NICHT an Leerzeichen trennen. Beide Pfade ergeben sich aus
# dem Ordner und den festen Namen Favenio.app und FavenioQuick.app.
set -euo pipefail
# build-app.sh wertet kein Argument aus. Durchgereicht startete
# `./build.sh --help` einen vollständigen Bau samt Selbsttest, statt etwas
# über den Aufruf zu sagen. install.sh und release.sh rufen ohne Argumente.
if [ $# -gt 0 ]; then
    echo "FEHLER: build.sh nimmt keine Argumente (erhalten: $*)." >&2
    echo "Aufruf: ./build.sh — Einstellungen über Umgebungsvariablen," \
         "z. B. FAVENIO_SIGN_ID." >&2
    exit 2
fi
cd "$(dirname "$0")"
exec ./build-app.sh
