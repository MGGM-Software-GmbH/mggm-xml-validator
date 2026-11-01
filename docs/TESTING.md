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

`UpstreamRoot` bezeichnet einen separaten Checkout des [KoSIT-Originalvalidators](https://github.com/itplr-kosit/validator). Gültige und fachlich ungültige Rechnungsfixtures können aus einer eigenen isolierten Testsammlung bereitgestellt werden. Die Vorlage für offizielle XRechnung-Beispiele ist die [KoSIT-Testsuite](https://github.com/itplr-kosit/xrechnung-testsuite). Fremde Fixtures werden nicht ungeprüft in dieses Quellrepository übernommen.

`FixtureRoot` bezeichnet das versionierte Verzeichnis `Tests/Fixtures`. Für compilerabhängige Testausgabeordner diesen Pfad beim Engine-Test ausdrücklich übergeben. Die optionale Standardauflösung liegt eine Ebene über dem normalen Testausgabeordner und sucht keine alternativen Verzeichnisse.

Der Beispieltest prüft insbesondere den DLL-Pfad neben der EXE bei fremdem Arbeitsverzeichnis, fehlende DLL, ausdrückliche Pfade, fehlende Regeln, XML-Fehler und Ausgabeschutz. Der CLI-Test erwartet die Saxon-DLL neben der geprüften CLI-EXE. Deshalb vor dem Lauf die lokale Paketierung ausführen.

Der projektbezogene [Prüfnachweis](../Tests/publication-verification.json) hält die ausgeführten Builds und Fallzahlen je Compiler fest. Win32, andere Compiler-Versionen als Delphi 11 und 13 sowie ein Windows-Rechner ohne Entwicklungswerkzeuge sind damit nicht geprüft.
