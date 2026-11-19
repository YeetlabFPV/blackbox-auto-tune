# Betaflight Blackbox Auto-Tune

Das lokale Python-Tool erstellt den ersten PID- und Filtervorschlag bereits aus Flug 1. Flug 2 misst den Effekt und kann einen kleineren Nachschritt vorschlagen. Flug 3 prüft diesen Nachschritt. Bei einer deutlichen Verschlechterung bietet das Tool die Rücknahme des zuletzt vorgeschlagenen Schritts an. Wenn ein Ergebnis nach Flug 2 für dich passt und das Tool keine weitere Änderung vorschlägt, kannst du dort aufhören.

## Auf diesem Mac öffnen

Öffne im Finder im Ordner `outputs` die App **Blackbox Auto-Tune** per Doppelklick. Wähle unter **Logs auswählen** mit gedrückter ⌘-Taste ein oder mehrere Rohlogs. Einen CLI-Dump kannst du optional auswählen. Klicke auf **Runde analysieren**. Den Vorschlag kannst du aus der Ergebnisansicht kopieren. Mit **Runde 2 vorbereiten** oder **Runde 3 vorbereiten** übernimmt die App automatisch den passenden Vorbericht.

Die App nutzt die eingerichtete Python-Umgebung und den Blackbox-Decoder aus dem Arbeitsordner. Öffne sie deshalb am ursprünglichen Speicherort. Die Terminalbefehle weiter unten sind für die Nutzung ohne Oberfläche gedacht.

## Mehrere Logs pro Runde

Wähle ein oder mehrere Logs. Die App gruppiert Segmente mit derselben aufgezeichneten Konfiguration und vergleichbarer Lograte. Sie bevorzugt in Runde 1 eine Gruppe mit begründetem CLI-Vorschlag. Sonst entscheidet die Messabdeckung. Bei Folgerunden kommen nur Gruppen infrage, deren Einstellungen zum vorherigen Bericht passen. In der Ergebnisansicht steht, welche Segmente verwendet wurden und welche zu anderen Gruppen gehören. Innerhalb einer Gruppe bildet die App für vergleichbare Messwerte den Median der verwertbaren Einzelmessungen. Wiederholte Stickstopps werden gemeinsam gezählt. Die CLI-Werte beziehen sich auf den Tune der gewählten Gruppe. Falls du im Terminal arbeitest, kannst du `--additional-log zweites.bbl` pro Zusatzdatei wiederholen. Die App prüft automatisch alle Segmente und nennt übersprungene Segmente mit Grund. Eine optionale Segmentnummer wirkt auf alle ausgewählten Dateien.

Der CLI-Befehl `dump` liefert die Profilnummer, die Ausgangswerte für Rücknahmen und den Konfigurationsstand für den Folgeflug. Blackbox liefert die Flugdaten und einen Teil der Einstellungen. Ohne Dump verwendet das Tool die im Log gespeicherten PID- und Filterwerte. Wähle dann vor dem Einfügen das geflogene PID-Profil und prüfe die angezeigten Ausgangswerte im Betaflight-CLI mit `get`. Ein Dump genügt für alle Logs derselben Runde. Wenn du den zusätzlichen Abgleich nutzen möchtest, hole nach Änderungen einen neuen Dump.

## Was aus dem Log in die CLI gelangt

Der Betaflight-Regler vergleicht die Soll-Drehrate mit der gemessenen Drehrate. Für das Tuning sind besonders Überschwingen, Nachschwingen, Regelabweichung und Vibration bei unterschiedlichen Gasstufen relevant. Der offizielle Blackbox-Decoder wandelt die binären Frames in Messreihen um. Das Tool verwendet Sollwerte, gefiltertes und ungefiltertes Gyro, D-Term und Motorausgänge. Es prüft Zeitlücken und blendet Messfenster mit Motorausgang nahe der Obergrenze aus. [Blackbox-Dokumentation](https://betaflight.com/docs/wiki/guides/current/Black-Box-logging-and-usage) · [Betaflight PID Tuning Guide](https://betaflight.com/docs/wiki/guides/current/PID-Tuning-Guide)

- **P und D** werden anhand wiederholter Drehimpulse bewertet. Die Regeln nutzen Überschwingen, den anschließenden Rückschwinger und die Sollwertabweichung. Bei günstiger Datenlage kann das Tool auf Roll und Pitch auch die D-Dämpfung erhöhen. Die Zuordnung für Basis- und Spitzen-D hängt von der Firmware ab. [Dynamic D](https://betaflight.com/docs/wiki/guides/current/Dynamic-D)
- **Filter** können auch bei einem normalen Flug beurteilt werden. Die Auswertung verwendet ruhige Fenster in den Gasbereichen 20–40 % und 40–65 %. Spürbares hochfrequentes Restgeräusch in Gyro und D-Term kann zu tieferen Grenzfrequenzen des bestehenden D-Term-LPF1 führen. Mit der optionalen A/B-Prüfung kann das Tool einen kleinen Schritt am statischen Gyro-LPF1 vorschlagen. RPM-Filter und Dynamic Notch werden diagnostisch beurteilt. Eine begrenzte Feedforward-Korrektur ist möglich, wenn die App bei wiederholten Stickstopps in beiden Richtungen einen deutlichen Rückschlag und überwiegenden Feedforward-Bremsanteil misst. I bleibt außerhalb der CLI-Automatik. [PID Tuning Tab](https://betaflight.com/docs/wiki/app/pid-tuning-tab) · [RPM Filtering](https://betaflight.com/docs/wiki/guides/current/DSHOT-RPM-Filtering)
- **Vergleich** verwendet ähnliche Drehimpulse und gemeinsame Gasbereiche. Bei fehlender Abdeckung oder starken Vibrationen kann der Bericht ohne neue Einstellungen enden. Die Entscheidungsgrenzen sind konservative Heuristiken. Sie wurden noch nicht anhand einer Serie realer Flüge kalibriert.

Die Kommandozuordnungen sind für **4.5.x**, **2025.12.x** und **2026.6.x** ausgelegt. Öffentliche Rohlogs wurden mit **4.5.1**, **4.5.2** und **2025.12.2** geprüft. Für **2026.6.2** wurde der Ablauf bisher mit synthetischen Logs getestet. Der geprüfte Build **2025.12.0-beta (9d3558c3f)** kann ebenfalls CLI-Vorschläge erhalten. Andere Vorab-Builds der unterstützten Serien öffnen sich zur Diagnose. Weitere 2026er Firmware-Reihen benötigen eine Prüfung ihrer Log- und CLI-Zuordnungen. Der Prototyp ist für einen bereits normal fliegenden Quad im Acro-Modus gedacht. Drei Flüge sind das Messbudget der Reihe. Wie nah das Ergebnis am besten erreichbaren Tune liegt, hängt von Flugdatengüte, Setup und Einsatzprofil ab. [Firmware 4.5.2](https://github.com/betaflight/betaflight/tree/4.5.2) · [Firmware 2026.6.2](https://github.com/betaflight/betaflight/tree/2026.6.2)

## Einmal einrichten

Im Terminal in den Ordner mit `bb_tune.py` wechseln und NumPy installieren.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install numpy
```

Für Rohlogs wird der offizielle Decoder benötigt. Auf macOS mit installierten Command Line Tools lässt er sich so bauen. Alternativ kannst du einen vorhandenen Decoder über `--decoder` angeben. [Betaflight blackbox-tools](https://github.com/betaflight/blackbox-tools)

```sh
git clone https://github.com/betaflight/blackbox-tools.git
make -C blackbox-tools ./obj/blackbox_decode
```

## Testflug 1

1. Stelle den Quad mit intakten Props, festem Aufbau und bekanntem Tune auf. Sichere vorab im Betaflight-CLI mit `diff all` die Konfiguration. Hole für das Tool separat die Ausgabe von **`dump`** (aktives Profil) als `flug1-dump.txt`. Bei betaflightseitiger Profilumschaltung mit dem tatsächlich geflogenen Profil arbeiten.
2. Aktiviere Blackbox auf Flash oder SD. Aktiviere Setpoint, PID, Gyro, ungefiltertes Gyro und Motoren in den Logfeldern. Falls die App die Felder nicht anzeigt, lauten die entsprechenden CLI-Einstellungen bei den Referenzständen `blackbox_disable_setpoint`, `blackbox_disable_pids`, `blackbox_disable_gyro`, `blackbox_disable_gyrounfilt` und `blackbox_disable_motors`; setze sie auf `OFF`. Wähle die Abtastrate passend zur PID-Loop-Rate, z. B. `1/4` bei 8 kHz oder `1/2` bei 4 kHz für ca. **2 kHz**. Nimm den Dump nach dem Speichern der Logging-Einstellungen auf. [Blackbox Logging](https://betaflight.com/docs/wiki/guides/current/Black-Box-logging-and-usage)
3. Fliege normal in Acro auf freiem Gelände. In geraden Passagen kannst du das Gas sanft erhöhen und wieder zurücknehmen. Die App liest die Gasstellung aus dem Log.
4. Fliege ein paar gewohnte Rolls oder Flips in beide Richtungen und lass den Stick am Ende sauber zur Mitte zurück. Variiere die Bewegungen nach Gefühl. Wiederhole für den Flugvergleich möglichst ähnliche Manöver mit demselben Akku- und Propellertyp. Die App schätzt zusätzlich die dynamische Antwort aus normalen Stickbewegungen. Daraus abgeleitete Kennwerte sind experimentell und dienen als Diagnose. [Plasmatree PID-Analyzer](https://github.com/Plasmatree/PID-Analyzer) · [Betaflight PID Tuning Guide](https://github.com/betaflight/betaflight.com/blob/master/docs/wiki/guides/current/PID-Tuning-Guide.md)
5. Lade das rohe Blackbox-Log herunter. Das Tool prüft alle Armings einer Datei. Mit `--index N` kannst du die Prüfung auf ein bestimmtes Segment begrenzen, beginnend bei 1.

## Auswerten und nachmessen

```sh
.venv/bin/python bb_tune.py flug1.bbl --dump flug1-dump.txt \
  --decoder blackbox-tools/obj/blackbox_decode --report flug1.json
```

Im Terminal erscheinen Messwerte, Begründungen und gegebenenfalls zwei CLI-Blöcke. Prüfe die neuen Werte gegen deinen Dump. Füge nur den gewünschten Block in das CLI des disarmten Flight Controllers ein. Prüfe die Antworten auf Fehler und speichere anschließend separat mit `save`. Hebe den Rücknahmeblock auf. Bei direkten PID- oder Filteränderungen kann der Vorschlag die jeweils zugehörige vereinfachte Slider-Steuerung im ausgewählten Profil deaktivieren.

Hole nach dem Speichern und für jeden Folgeflug einen aktuellen `dump`. Der Bericht enthält die lokalen Einstellungen und Messwerte. Behalte ihn als Eingabe für die Folgeanalyse.

```sh
.venv/bin/python bb_tune.py flug2.bbl --dump flug2-dump.txt \
  --decoder blackbox-tools/obj/blackbox_decode --previous flug1.json --report flug2.json

.venv/bin/python bb_tune.py flug3.bbl --dump flug3-dump.txt \
  --decoder blackbox-tools/obj/blackbox_decode --previous flug2.json --report flug3.json
```

Der Ablauf setzt voraus, dass zwischen zwei Flügen entweder der vollständige Vorschlag angewandt wurde oder der vorherige Bericht keinen Vorschlag enthielt. Bei einem Config-Mismatch prüfe Profil, CLI-Dump und Logsegment. Wenn ein Vergleich offen bleibt, kannst du das geeignete Segment mit demselben Vorbericht und einem neuen Berichtsnamen auswerten. Flug 3 gibt nur noch den Vergleich und gegebenenfalls eine Rücknahme aus.

## Filter und PID nach dem Rosser-Workflow

Im Ergebnis öffnet **Frequenzkarte und Gyro-Filterverzögerung** die Spektren für Rohgyro, gefiltertes Gyro und D-Term in 20-%-Gasbereichen. Die App ordnet die Abschnitte anhand der geloggten Gasstellung zu. Bei vorhandener eRPM-Telemetrie zeigt sie zusätzlich, ob eine dominante Rohgyro-Spitze mit der Drehzahl wandert. Das ist ein Hinweis auf eine drehzahlabhängige Anregung. Die geschätzte Phasenverzögerung gilt für die gesamte Gyro-Filterkette im gemessenen Frequenzband. [Chris Rosser · Filter Tuning](https://www.youtube.com/watch?v=E3s5XYk3M74) · [Betaflight · RPM-Filter](https://betaflight.com/docs/wiki/guides/current/DSHOT-RPM-Filtering)

Die Option **Filteröffnung als A/B-Test prüfen** ist standardmässig aus. Für einen Vorschlag verlangt die App in Runde 1 ausreichend ruhige Fenster über mehrere Gasbereiche, aufgezeichnete eRPM-Daten, saubere Spektren, messbare Gyro-Filterverzögerung und einen aktiven statischen Gyro-LPF1. Der mögliche Schritt ist auf etwa 5 % und maximal 10 Hz begrenzt. Bei einer vorgeschlagenen Filteränderung folgt die Gain-Bewertung in der nächsten Runde. Prüfe nach einem kurzen Folgeflug Motorwärme und Flugverhalten und verwende den Rücknahmeblock, wenn sich das Ergebnis verschlechtert.

Unter **Geschätzte Sprungantwort** siehst du pro Achse die aus Sollwert und Gyro geschätzte Kurve. Bei einem Folgeflug erscheinen verfügbare Kurven des vorherigen Berichts im selben Diagramm. Die gestrichelte Linie markiert den geschätzten Endwert. Überschwingen und Einschwingzeit stehen unter der Kurve. Die Rohgyro- und Gyro-Frequenzkarten teilen sich pro Segment eine Farbskala, sodass die Wirkung der Filter sichtbar wird. Beide Ansichten orientieren sich am dokumentierten Analyseablauf in [PIDtoolbox Pro](https://www.youtube.com/watch?v=1Y5zCZUWANY). Die App unterscheidet zwischen P/D-Balance und einem durch protokollierte Feedforward-Beiträge gestützten Rückschlag nach Stickstopps. P/D-Vorschläge setzen einen belegten Feedforward-Wert von null auf der jeweiligen Achse voraus. Nach einer D-Term-Filterabsenkung muss der Folgeflug die zuvor auffälligen Gasbereiche erneut abdecken. Master Multiplier, I, Dynamic D und RC-Link-Presets werden nicht automatisch optimiert. Für diese Schritte empfiehlt Rosser getrennte Vergleichsflüge und für Dynamic D dessen Debug-Signale. [Chris Rosser · PID Tuning](https://www.youtube.com/watch?v=1oYoVE4xu1U) · [Betaflight · Dynamic D](https://betaflight.com/docs/wiki/guides/current/Dynamic-D)

## Kurze Schwingungen, Propwash und Einstellempfehlungen

Unter **Kurze Schwingungen und Abfangmanöver** findest du die stärksten kurzen Gyro-Auffälligkeiten bei kleinen Stickbefehlen im Bereich von 25 bis 120 Hz. Der Zeitstempel bezieht sich auf den Segmentbeginn. Für den Propwash-Vergleich fliegst du mehrere ähnliche Abfangmanöver. Die App vergleicht Medianwerte für Roll-/Pitch-Sollwertfehler und Dauer bei mindestens drei erkannten Manövern im gleichen Gaswechselbereich pro Bericht. Der Vergleich dient der Diagnose. Ein Gaswechsel im Log belegt die aerodynamische Ursache allein nicht.

**Einstellempfehlung** zeigt Ist- und Zielwerte. Einen D-Term-Filter-Slider zeigt die App bei Betaflight 4.5.2 und 2026.6.2 an, wenn der CLI-Dump die Slider-Konfiguration belegt und der Zielwert dieselben Grenzfrequenzen wie der Einzelvorschlag ergibt. Für diesen Slider-Schritt benötigt auch die Nachmessung einen aktuellen CLI-Dump. Andere Empfehlungen zeigen die konkreten Gains oder Grenzfrequenzen an. Bei kurzen Schwingungen empfiehlt die App, den Master-Wert beizubehalten.

## Relative Slider-Schritte

Die App kann für den Betaflight Configurator einen einzelnen Vergleichsschritt empfehlen. D-Term Filter Multiplier um 0.05 senken bei wiederholt erhöhtem D-Term-Rauschen, Gyro Filter Multiplier um 0.05 erhöhen bei sauberen Spektren und messbarer Verzögerung oder Master Multiplier um 0.05 erhöhen bei vergleichbarem Rückstand auf Roll und Pitch mit Motorreserve. Die jeweiligen vereinfachten Einstellungen müssen aktiv sein. Ein zusätzliches Eingabefeld ist dafür nicht nötig. Der Ausgangswert erscheint, soweit er im Log oder im optionalen Dump belegt ist.

Ändere nur den genannten Slider und wiederhole die entsprechenden Passagen. Die App prüft im Folgeflug die erkennbaren Einstellungsänderungen und den messbaren Nutzen. Wenn beide Reports den Slider-Wert enthalten, prüft sie den Schritt direkt. Ansonsten vergleicht sie die geloggten Gains oder Grenzfrequenzen. Bei fehlender Vergleichbarkeit bleibt das Ergebnis offen. Bei Verschlechterung oder fehlendem messbaren Nutzen erscheint der manuelle Rücknahmeschritt.
