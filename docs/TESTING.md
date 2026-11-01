# Bauen und prüfen

Die geprüfte Toolchain des MGGM XML Validators für Delphi ist Delphi 11 Alexandria, Win64. Für den normalen Paketaufbau werden `MGGMXmlValidator.dproj`, `MGGMXmlValidatorBatch.dproj` und `Examples/ValidateXmlExample.dproj` in Release gebaut. Die Programme heißen `MGGMXmlValidator.exe`, `MGGMXmlValidatorBatch.exe` und `ValidateXmlExample.exe`. Die Ausgaben liegen direkt unter `build`; Tests schreiben nach `Tests/build`. Compilerzwischenprodukte bleiben pro Projekt unter `obj` getrennt.

Python-Prüfungen aus dem Projektverzeichnis:

~~~bat
python -m unittest discover -s Tests
~~~

Die Tests verwenden isolierte Verzeichnisse für Gegenproben. Sie prüfen Paketinhalt und Konflikte, Exportgrenzen, Berichtvergleich und eingebettete Ressourcen. Der Ressourcenvergleich benötigt weder DLL noch Regelpaket.

Die Delphi-Testprogramme werden jeweils über ihre `.dproj` gebaut und mit den folgenden Argumenten gestartet. Ergebnisziele sind für jeden Lauf neu zu wählen. `DLL` bezeichnet einen absoluten Pfad; `ValidationRoot` ist beispielsweise das paketierte `build/Validation`. `CLIExe` bezeichnet `build/MGGMXmlValidator.exe`, `ExampleExe` bezeichnet `build/ValidateXmlExample.exe`. Testberichte enthalten die tatsächlich ausgeführten Fälle.

| Projekt | Argumente |
|---|---|
| `Tests/EngineTests.dproj` | `DLL ValidationRoot EvidenceJson [OriginalUblInvoice]` |
| `Tests/PipelineTests.dproj` | `DLL UpstreamRoot EvidenceDirectory` |
| `Tests/CliTests.dproj` | `CLIExe DLL ValidationRoot ValidXml InvalidBusinessXml EvidenceDirectory` |
| `Tests/StreamAdapterTests.dproj` | `DLL ValidationRoot ValidUbl InvalidUbl EvidenceJson` |
| `Tests/NativeReuseTests.dproj` | `DLL EvidenceJson` |
| `Tests/MemoryTransferTests.dproj` | `DLL ValidationRoot ValidXml InvalidBusinessXml EvidenceJson` |
| `Tests/ParallelEngineTests.dproj` | `DLL ValidationRoot ValidXml InvalidBusinessXml EvidenceJson` |
| `Tests/DelphiExampleTests.dproj` | `ExampleExe DLL ValidationRoot ValidXml InvalidBusinessXml EvidenceDirectory` |

`UpstreamRoot` bezeichnet einen separaten Checkout des [KoSIT-Originalvalidators](https://github.com/itplr-kosit/validator). Gültige und fachlich ungültige Rechnungsfixtures können aus einer eigenen isolierten Testsammlung bereitgestellt werden. Die Vorlage für offizielle XRechnung-Beispiele ist die [KoSIT-Testsuite](https://github.com/itplr-kosit/xrechnung-testsuite). Fremde Fixtures werden nicht ungeprüft in dieses Quellrepository übernommen.

Der Beispieltest prüft insbesondere den DLL-Pfad neben der EXE bei fremdem Arbeitsverzeichnis, fehlende DLL, ausdrückliche Pfade, fehlende Regeln, XML-Fehler und Ausgabeschutz. Der CLI-Test erwartet die Saxon-DLL neben der geprüften CLI-EXE. Deshalb vor dem Lauf die lokale Paketierung ausführen.

Der projektbezogene [Prüfnachweis](../Tests/publication-verification.json) hält die ausgeführten Builds und Fallzahlen fest. Win32, weitere Delphi-Versionen und ein Windows-Rechner ohne Entwicklungswerkzeuge sind damit nicht geprüft.
