# Bauen und prüfen

Der MGGM XML Validator für Delphi wird mit Delphi 11 Alexandria und Delphi 13 Florence für Win64 geprüft. Für den Paketaufbau werden `MGGMXmlValidator.dproj`, `MGGMXmlValidatorBatch.dproj` und `Examples/ValidateXmlExample.dproj` in Release gebaut. Die Programme heißen `MGGMXmlValidator.exe`, `MGGMXmlValidatorBatch.exe` und `ValidateXmlExample.exe`.

| Compiler | Programme und Laufzeitpaket | Testprogramme |
|---|---|---|
| Delphi 11 Alexandria | `build` | `Tests/build` |
| Delphi 13 Florence | `build/Delphi13` | `Tests/build/Delphi13` |

Compilerzwischenprodukte liegen unter `build/obj/<Compilerversion>/<Plattform>/<Konfiguration>/<Projektname>`, bei Testprojekten entsprechend unter `Tests/build/obj`. Die Projektdateien bestimmen die Version aus `PRODUCTVERSION` oder dem Versionsordner der Delphi-Installation unter `BDS`. Bei einem abweichend benannten Installationsordner ist `PRODUCTVERSION` beim MSBuild-Aufruf ausdrücklich anzugeben. Für getrennte Laufzeitpakete alle drei EXE-Pfade und das Ziel wie im [README](../README.md#bauen-und-lokal-paketieren) angeben.

Python-Prüfungen aus dem Projektverzeichnis:

~~~bat
python -m unittest discover -s Tests
~~~

Die Tests verwenden isolierte Verzeichnisse für Gegenproben. Sie prüfen Paketinhalt und Konflikte, Exportgrenzen, Berichtvergleich und eingebettete Ressourcen. Der Ressourcenvergleich benötigt weder DLL noch Regelpaket.

Die Delphi-Testprogramme werden jeweils über ihre `.dproj` in Debug gebaut und mit den folgenden Argumenten gestartet. Ergebnisziele sind für jeden Lauf neu zu wählen. `DLL` bezeichnet einen absoluten Pfad; `ValidationRoot` ist das `Validation`-Verzeichnis des jeweiligen Laufzeitpakets. `CLIExe` und `ExampleExe` bezeichnen dessen CLI beziehungsweise Beispielprogramm. Die Delphi-Programme eines Laufs stammen aus demselben Compiler-Build. Testberichte enthalten die tatsächlich ausgeführten Fälle.

| Projekt | Argumente |
|---|---|
| `Tests/EngineTests.dproj` | `DLL ValidationRoot EvidenceJson [OriginalUblInvoice [FixtureRoot]]` |
| `Tests/PipelineTests.dproj` | `DLL UpstreamRoot EvidenceDirectory` |
| `Tests/CliTests.dproj` | `CLIExe DLL ValidationRoot ValidXml InvalidBusinessXml EvidenceDirectory` |
| `Tests/StreamAdapterTests.dproj` | `DLL ValidationRoot ValidUbl InvalidUbl EvidenceJson` |
| `Tests/NativeReuseTests.dproj` | `DLL EvidenceJson` |
| `Tests/MemoryTransferTests.dproj` | `DLL ValidationRoot ValidXml InvalidBusinessXml EvidenceJson` |
| `Tests/ParallelEngineTests.dproj` | `DLL ValidationRoot ValidXml InvalidBusinessXml EvidenceJson` |
| `Tests/DelphiExampleTests.dproj` | `ExampleExe DLL ValidationRoot ValidXml InvalidBusinessXml EvidenceDirectory` |

`UpstreamRoot` bezeichnet einen separaten Checkout oder bytegleichen Quellexport des [KoSIT-Originalvalidators v1.6.3](https://github.com/itplr-kosit/validator/tree/v1.6.3), Commit `37cddce28e15ac3a0319db006ab21d3f1064ca8c`. Für `ValidXml` und `InvalidBusinessXml` können `Tests/Fixtures/reference/xr-ubl-valid.xml` und `Tests/Fixtures/reference/xr-ubl-business-error.xml` verwendet werden. Herkunft, Lizenz und die gezielten Änderungen sind im [Fixture-Verzeichnis](../Tests/Fixtures/reference/README.md) dokumentiert.

`FixtureRoot` bezeichnet das versionierte Verzeichnis `Tests/Fixtures`. Für compilerabhängige Testausgabeordner diesen Pfad beim Engine-Test ausdrücklich übergeben. Die optionale Standardauflösung liegt eine Ebene über dem normalen Testausgabeordner und sucht keine alternativen Verzeichnisse.

Der Beispieltest prüft insbesondere den DLL-Pfad neben der EXE bei fremdem Arbeitsverzeichnis, fehlende DLL, ausdrückliche Pfade, fehlende Regeln, XML-Fehler und Ausgabeschutz. Der CLI-Test erwartet die Saxon-DLL neben der geprüften CLI-EXE. Deshalb vor dem Lauf die lokale Paketierung ausführen.

Der projektbezogene [Prüfnachweis](../Tests/publication-verification.json) hält die ausgeführten Builds und Fallzahlen je Compiler fest. Win32, andere Compiler-Versionen als Delphi 11 und 13 sowie ein Windows-Rechner ohne Entwicklungswerkzeuge sind damit nicht geprüft.

## Originalinventur

Alle Befehle beginnen im Repositoryverzeichnis. `UpstreamRoot` ist hier durch den absoluten Pfad zum festgelegten Originalstand zu ersetzen:

~~~bat
python verify_original_test_inventory.py "C:\Quellen\validator-1.6.3"
python -m unittest discover -s Tests -p test_original_test_inventory.py -v
~~~

Die Prüfung bindet Methoden, Fundstellen, Varianten, Hilfsdateien, Vererbung und Testressourcen an die [Methodenmatrix](prp/test-coverage/METHODENMATRIX.md). Sie führt weder die Originalsuite noch Delphi-Tests aus. Ohne Git-Metadaten werden die Quellen gegen die gespeicherten SHA-256 geprüft; ein Checkout muss zusätzlich den festgelegten Commit ausweisen.

## Lokaler Java-/Delphi-Referenzlauf

Der Korpus unter `Tests/Fixtures/reference` enthält zehn Fälle: unveränderte XRechnung-UBL-/CII-Beispiele, einen Schemafehler, Geschäftsregelverstöße, ZUGFeRD-/Factur-X EN16931/Comfort sowie Parser-, DTD- und Szenariofehler. `fixture-manifest.json` legt die Erwartungen und Eingabehashes fest. `rule-hashes.json` bindet die gesamte lokale Regeldateimenge einschließlich der drei Szenariokonfigurationen. Zusätzliche, fehlende oder veränderte Regeldateien sind Fehler.

Voraussetzungen sind Python, das lokale KoSIT-Standalone-JAR 1.6.3, Java und `xmllint` im Suchpfad sowie die gebauten Win64-Programme mit ihrer SaxonC-HE-DLL. `xmllint --nonet` prüft die Berichtseingabe gegen `Source/createReportInput.xsd`. Der ausgewählte Referenzlauf verwendet das JAR direkt und benötigt Maven nicht. Nach lokaler Bereitstellung der Abhängigkeiten benötigen diese Schritte keinen Internetzugriff.

Beispiel für `cmd.exe` auf einem Windows-Rechner mit allen Voraussetzungen. Absolute Pfade anpassen und ein neues, noch nicht existentes Laufverzeichnis wählen:

~~~bat
python Tests\reference_corpus.py prepare "C:\Pruefung\referenzlauf" --validation-root "C:\Quellen\mggm-xml-validator\build\Validation" --jar "C:\Werkzeuge\validator-1.6.3-standalone.jar"
python Tests\reference_corpus.py java "C:\Pruefung\referenzlauf" --java "C:\Java\bin\java.exe"
python Tests\reference_corpus.py delphi "C:\Pruefung\referenzlauf" --executable "C:\Quellen\mggm-xml-validator\build\MGGMXmlValidator.exe" --library "C:\Quellen\mggm-xml-validator\build\saxonc-core-he.dll" --name native11
python compare_reports.py "C:\Pruefung\referenzlauf" native11
python Tests\reference_corpus.py delphi "C:\Pruefung\referenzlauf" --executable "C:\Quellen\mggm-xml-validator\build\Delphi13\MGGMXmlValidator.exe" --library "C:\Quellen\mggm-xml-validator\build\Delphi13\saxonc-core-he.dll" --name native13
python compare_reports.py "C:\Pruefung\referenzlauf" native13
~~~

`prepare` prüft Fixtures, Lizenzdateien, JAR und Regeln vor dem Kopieren. Der festgelegte JAR-SHA-256 ist `799e64befca97d4080e03608c80b85dd5a5ecc5f4ae4f35d1116ec2855b9a7c9`. Jeder Engine-Start prüft den Bestand erneut. Der Runner selbst liefert bei erfolgreicher Ausführung Exitcode 0; die gestarteten Validatoren liefern für diesen Korpus jeweils 7, entsprechend den sieben erwarteten Ablehnungen. Ein anderer Validator-Exitcode ist ein Fehler.

Das neue Laufverzeichnis enthält `manifest.json`, kopierte Originaleingaben unter `input` und getrennte Ergebnisse unter `java`, `native11` und `native13`. `execution.json` hält Argumente, Lauf-ID, Zeitpunkt, tatsächlichen Exitcode und Versionsangaben fest. Die nativen Starts halten zusätzlich EXE- und DLL-Hashes fest. `stdout.log`, `stderr.log`, XML-, HTML- und Berichtseingabedateien gehören zum jeweiligen Lauf. `results.json` hält die öffentlichen CLI-Ergebnisse fest. Jeder Vergleich schreibt seinen Nachweis zusätzlich in `native11/comparison.json` beziehungsweise `native13/comparison.json`; die oberste `comparison.json` beschreibt den zuletzt verglichenen Compilerlauf.

Bei getrennten Betriebssystemen müssen die Argumentpfade für den jeweiligen Host auf dieselben Originalbytes zeigen. `input_aliases` darf im Laufmanifest ausschließlich die tatsächlich verwendeten weiteren Hostpfade derselben Eingaben benennen. Hashes, Erwartungen und Szenariokonfigurationen bleiben unverändert. Unbekannte Dokumentkontexte sind Vergleichsfehler.

Der Vergleich prüft Annahme, öffentlichen Status, Berichtgültigkeit, Szenario, Prüfphasen, Befund-Multimengen, Originalbytehashes, XSD-gültige Berichtseingaben und HTML-Inhalte getrennt. Er führt 17 isolierte Laufzeitgegenproben aus: 16 gezielte Manipulationen müssen erkannt werden; die erlaubte Zeitstempeländerung muss vergleichbar bleiben. Fehlende Berichte, leere Korpora oder fehlende Gegenproben führen zu Exitcode 1.

Eng begrenzte Diagnoseausnahmen betreffen unerwartete Schemaelemente, ungeschlossene Dokumente und verbotene DTDs. Die semantischen Merkmale dieser Fehler bleiben verpflichtend. Beim DTD-Abbruch darf nur Java den nachgewiesenen gelesenen Präfix hashen; Delphi muss den Hash aller Originalbytes liefern. Der längere Fall `dtd-prefix-hash` prüft diese Grenze ausdrücklich. Andere Befundmengen oder verlorene Meldungen werden nicht durch Normalisierung ausgeglichen.

Aktuelle Lauf-IDs, Fallzahlen und festgestellte Unterschiede stehen in [RESULTATE.md](prp/test-coverage/RESULTATE.md). Die vollständige Original-Java-Testsuite ist ein eigener Nachweis und kein Teil dieses ausgewählten Offline-Korpus.
