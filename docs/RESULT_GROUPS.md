# Treffer gruppieren und die Archivquelle zeigen

Ab 0.54.0 bietet **Gruppieren** in beiden Apps **Ordner**, **Endung** und
**Quellarchiv**. **Keine** stellt die flache Liste wieder her. Gruppenüberschriften
nennen ihre Trefferzahl; der Pfeil klappt eine Gruppe ein oder auf.
Kopf und Trefferzahl bleiben innerhalb des sichtbaren Tabellenbereichs, auch
wenn die Dateispalten horizontal gescrollt werden. Der Tooltip nennt den
vollständigen Gruppennamen.
**Alle aufklappen / Alle einklappen** wirken auf die vorhandenen Gruppen.
Neue Gruppen durch Suchnachschub erscheinen aufgeklappt. Eine neue Suche öffnet
alle Gruppen und behält die gewählte Gruppierungsart für dieses Fenster.
Gruppierung und Klappzustand sind Darstellungsoptionen und werden nicht als
Suchkriterien in Vorlagen, Aufzeichnungen oder Quick-Übergaben gespeichert.

Gruppen sind alphabetisch geordnet. Die gewählte Spaltensortierung gilt innerhalb
jeder Gruppe. Ordnergruppen unterscheiden Archivstufen und ursprüngliche
Namensbytes, auch bei gleich aussehenden Namen oder `!/` im Namen. Endungsgruppen
fassen Groß-/Kleinschreibung zusammen; Verzeichnisse und Dateien ohne Endung
haben eigene Gruppen. Quellarchivgruppen nennen die tatsächliche äußere Datei;
Treffer außerhalb von Archiven stehen in einer eigenen Gruppe. Die Gruppierung
liest keine Dateien oder Archive und verändert keine Suchbelege oder Identitäten.

Ab 0.55.0 nennen Ordnergruppen mit `searchRoot`-Herkunft ihren physischen
Elternpfad. Dadurch bleiben Gruppen aus mehreren Suchbereichen eindeutig,
auch wenn ihre relativen Ordnernamen gleich lauten. Die Pfadspalte nennt bei
Mehrwurzelständen zusätzlich die Herkunft; [Suchbereichsvertrag](SEARCH_ROOTS.md).

## Mengen, Auswahl und Aktionen

Es gibt drei Mengen: erhaltene Quelltreffer, durch den Ansichtsfilter zugelassene
Treffer und gerade aufgeklappte Trefferzeilen. **x von y Treffern** nennt die
gefilterte Menge und Quelle. Bei aktiver Gruppierung ergänzt **n aufgeklappt**
die tatsächlich dargestellte Trefferzahl. Überschriften zählen nicht als Treffer.
Einklappen verliert keine Treffer, hebt aber eine dadurch verborgene Auswahl auf.
Eine gemeinsame Auswahl kann echte Treffer aus mehreren aufgeklappten Gruppen
enthalten. Gruppenüberschriften lassen sich weder öffnen noch ziehen, kopieren,
exportieren oder in den Papierkorb legen. Ein Rechtsklick darauf verwendet keine
alte Dateiauswahl. Darstellungswechsel entwerten ausstehende Datei-/Vorschau- und
Fastra-Aufträge; alte Antworten dürfen nicht auf einer neuen Zeile landen.

**Alle gefilterten Treffer exportieren…** enthält auch eingeklappte Gruppen;
der Sichern-Dialog nennt diesen Umfang ausdrücklich. Auswahl-Export verwendet
nur ausgewählte echte Treffer. Die Gruppierung ist nicht Bestandteil von JSONL,
CSV oder anderen Trefferformaten. Aufzeichnungen und **Alle in Favenio** bewahren
weiterhin den vollständigen Quellstand des Ansichtsfilters.

Der lokale Controller liefert unter `resultGrouping` Gruppierungsart, Gruppen-
und Klappzahl, gefilterte Trefferzahl (`matchedCount`) sowie dargestellte
Trefferzahl (`displayedHitCount`). Ergebnisseiten enthalten die vollständige
gefilterte Menge einschließlich eingeklappter Gruppen; `resultsIncludeCollapsed`
ist ausdrücklich wahr. Auswahl enthält nur echte aufgeklappte Trefferidentitäten.
Explizites `select` oder `handoff` klappt die Gruppe des angefragten Treffers auf
und scrollt ihn sichtbar. Klapp-/Gruppierungswechsel entwerten Ergebnisgenerationen.

## Quellarchiv und Archivkette

Bei Archivtreffern zeigt **Quellarchiv im Finder zeigen** die äußere Archivdatei
an ihrem ursprünglichen Dateisystemort. Mehrfachauswahl dedupliziert dieselbe
äußere Datei bytegetreu. Dafür wird ausschließlich `filesystemPath` verwendet;
ein sichtbarer `!/`-Pfad wird nie zerlegt. Es wird nichts ausgepackt.
Die bisherige Aktion **Im Finder zeigen** bleibt bei der materialisierten Datei,
die auch Öffnen und Ziehen verwenden. Fehler beim Zugriff meldet der Finder.

**Archivkette anzeigen…** zeigt für einen ausgewählten Archivtreffer in einer
begrenzten, scrollbar und auswählbar dargestellten Textansicht die Quelle,
getrennte innere Archivstufen und den Treffer. Der Tooltip seiner Pfadspalte
zeigt dieselbe Kette. Zeilenumbrüche in Namen sind als `\n`/`\r` erkennbar;
sehr lange Stufen werden in dieser Anzeige ausdrücklich gekürzt. Die strukturierten
Identitäten und Rohbytes bleiben in Aktionen und Exporten vollständig erhalten.
