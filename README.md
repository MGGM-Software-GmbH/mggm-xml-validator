# MGGM XML Validator für Delphi

Eigenständige Delphi-Bibliothek und Konsolenprogramme zur Prüfung von XML-Dokumenten mit XML Schema und Schematron. Der Ablauf orientiert sich am [KoSIT XML Validator](https://github.com/itplr-kosit/validator): Szenario bestimmen, XSD und Schematron ausführen, Bericht erzeugen und Annahme oder Ablehnung ermitteln.

Das Repository `mggm-xml-validator` ist ein unabhängiges Projekt der MGGM Software GmbH und kein offizielles KoSIT-Projekt.

Die XML-Verarbeitung erfolgt im eigenen Windows-Prozess mit MSXML 6 und [The Saxon XSLT and XQuery Processor from Saxonica Limited](https://www.saxonica.com/), hier als native SaxonC-HE-DLL. Eine Java-Laufzeit wird für die Validierung nicht benötigt. Szenariokonfigurationen und Regelpakete werden unverändert vom Dateisystem geladen; XML und Ergebnisse können über Streams im Speicher verarbeitet werden.

## Voraussetzungen

- Windows x64 mit registriertem MSXML 6.
- Für die geprüften Builds: Delphi 11 Alexandria, Ziel Win64.
- Unveränderte `saxonc-core-he.dll` aus SaxonC-HE 12.10.1 für Windows x86_64 sowie deren benötigte Visual-C++-Laufzeit.
- Passende lokale Szenariokonfigurationen und Prüfregeln für das gewünschte Rechnungsformat.

Die native Anbindung ist auf diese SaxonC-Core-Version geprüft. Andere Versionen und Win32 werden nicht als kompatibel vorausgesetzt. Für zusätzliche Lizenzbedingungen und die noch offene Quellcodezuordnung des Binärpakets siehe [THIRD_PARTY.md](THIRD_PARTY.md).

## Laufzeitordner

Die gebauten Programme und die DLL liegen direkt unter `build`. Das Paket enthält darunter die Prüfregeln und Lizenzhinweise:

~~~text
build/
  MGGMXmlValidator.exe
  MGGMXmlValidatorBatch.exe
  ValidateXmlExample.exe
  saxonc-core-he.dll
  validate.cmd
  manifest.json
  Validation/
    validator-configuration-zugferd/
      scenarios.xml
      scenarios_zugferd1.xml
      Schema/...
    validator-configuration-xrechnung/
      3.0.2/
        scenarios.xml
        resources/...
  Notices/...
~~~

Compilerzwischenprodukte liegen unter `build/obj/<Projektname>`; sie gehören nicht zum Laufzeitpaket. Es werden keine Unterordner mit Compilerversionen für EXE und DLL verwendet.

Ohne expliziten DLL-Pfad sucht `TMGKositValidator.Create` ausschließlich neben der aktiven Anwendung. Das aktuelle Arbeitsverzeichnis spielt dabei keine Rolle. Ein ausdrücklich übergebener DLL-Pfad muss absolut sein. Die Beispielanwendung verwendet standardmäßig `Validation` neben ihrer EXE.

## Ein XML-Dokument prüfen

In `cmd.exe` aus dem Repository-Verzeichnis:

~~~bat
build\validate.cmd "C:\Rechnungen\Rechnung.xml" "C:\Pruefung\Ergebnis"
~~~

Das Ausgabeziel muss neu sein. Ohne zweites Argument entsteht ein neuer Ergebnisordner unter `build\Reports`. Die CMD-Datei ruft die Delphi-Beispielanwendung auf und gibt deren Exitcode weiter. Auch ein Aufruf aus einem anderen Arbeitsverzeichnis wird unterstützt.

Die Beispielanwendung lässt sich direkt starten:

~~~bat
build\ValidateXmlExample.exe "C:\Rechnungen\Rechnung.xml" "C:\Pruefung\Ergebnis"
~~~

Sie lädt die XML-Datei in einen Speicherstream, registriert die drei lokalen Regelkonfigurationen, prüft über die Unit `MGKosit` und schreibt `report.xml` sowie `report.html`. Als drittes Argument kann ein anderes Regelverzeichnis angegeben werden.

| Beispiel-Exitcode | Bedeutung |
|---|---|
| 0 | Angenommen, gegebenenfalls mit Warnungen |
| 1 | Fachlich abgelehnt |
| 2 | Ungültiger Aufruf oder nicht lesbare Eingabe |
| 3 | Saxon-DLL fehlt oder kann nicht initialisiert werden |
| 4 | Regelkonfiguration fehlt oder kann nicht geladen werden |
| 5 | Ausgabeziel ungültig oder Berichte nicht schreibbar |
| 6 | Verarbeitungsfehler |

## Allgemeine CLI

Die allgemeine CLI nimmt ihre Szenarien ausdrücklich entgegen. Beispiel mit XRechnung:

~~~bat
build\MGGMXmlValidator.exe --html ^
  -s "build\Validation\validator-configuration-xrechnung\3.0.2\scenarios.xml" ^
  -o "C:\Pruefung\XRechnung" "C:\Rechnungen\Rechnung.xml"
~~~

Mehrere `-s` registrieren mehrere Konfigurationen. `-r` ordnet ein abweichendes Ressourcenverzeichnis zu. Dateien, Verzeichnisse mit direkten XML-Dateien und `-` für stdin sind möglich. `--json` liefert strukturierte Ergebnisse, `--print` den XML-Bericht. `--serialize-report-input` schreibt zusätzlich die interne Berichtseingabe. `--help` beschreibt die Optionen.

Die CLI gibt je Dokument `V` für angenommen, `W` für angenommen mit Warnungen, `E` für abgelehnt und `F` für einen Verarbeitungsfehler aus. Exitcode 0 bedeutet Annahme aller Dokumente; positive Werte zählen nicht angenommene Dokumente. Aufruffehler verwenden 2, übergreifende technische Fehler 254. Zur Unterscheidung gehören stderr beziehungsweise die strukturierten Ergebnisse zum Aufruf.

## In Delphi verwenden

`Source` zum Projektsuchpfad hinzufügen und die öffentliche Unit `MGKosit` einbinden:

~~~pascal
uses
  System.SysUtils, System.Classes, MGKosit;

var
  Validator: TMGKositValidator;
  XmlStream: TMemoryStream;
  Validation: TMGKositValidationResult;
begin
  Validator := TMGKositValidator.Create;
  try
    Validator.AddScenario('C:\Validator\Validation\validator-configuration-xrechnung\3.0.2\scenarios.xml');
    XmlStream := TMemoryStream.Create;
    try
      XmlStream.LoadFromFile('C:\Rechnungen\Rechnung.xml');
      Validation := Validator.ValidateStream(XmlStream, 'Rechnung.xml');
      // Validation enthält Status, Befunde sowie XML- und HTML-Bericht.
    finally
      FreeAndNil(XmlStream);
    end;
  finally
    FreeAndNil(Validator);
  end;
end;
~~~

Eine Instanz kann mehrere Dokumente nacheinander prüfen und ihre kompilierten Ressourcen wiederverwenden. Erzeugen, Verwenden und Freigeben müssen im selben Thread stattfinden. Für parallele Aufrufer sind getrennte Instanzen erforderlich. Der Validator verwaltet die benötigte COM-Initialisierung selbst.

Eine ausführbare Fassung des Streambeispiels steht unter [Examples/ValidateXmlExample.dpr](Examples/ValidateXmlExample.dpr). [Examples/MGKositStreamAdapter.pas](Examples/MGKositStreamAdapter.pas) zeigt zusätzlich die Übergabe eines HTML-Ergebnisstreams.

`MGGMXmlValidatorBatch` prüft mehrere XML-Dateien in einem Prozess. Aufruf: `MGGMXmlValidatorBatch DLL ValidationRoot InputDirectory OutputDirectory [WorkerCount]`. Ein Worker entspricht einer eigenen Validatorinstanz; Standard ist ein Worker. Für den normalen Einzelbeleg genügt das kleine Beispiel.

## Bauen und lokal paketieren

Die Projekte sind auf Delphi 11 und Win64 ausgelegt. In einer Delphi-11-Eingabeaufforderung:

~~~bat
msbuild MGGMXmlValidator.dproj /t:Build /p:Config=Release /p:Platform=Win64
msbuild MGGMXmlValidatorBatch.dproj /t:Build /p:Config=Release /p:Platform=Win64
msbuild Examples\ValidateXmlExample.dproj /t:Build /p:Config=Release /p:Platform=Win64
~~~

Die EXEs entstehen direkt unter `build`. Ein Wechsel von Compiler oder Konfiguration erfordert einen erneuten Build der betroffenen Projekte; der flache Ausgabeordner enthält jeweils einen Buildstand.

Das [offizielle SaxonC-HE-12.10.1-Paket](https://downloads.saxonica.com/SaxonC/HE/12/SaxonCHE-windows-x86_64-12-10-1.zip) beispielsweise nach `Vendor\SaxonC` entpacken. Dort müssen `SaxonCCoreHE\bin\saxonc-core-he.dll` und `notices` vorhanden sein. Die gewünschten Regelverzeichnisse unter `Validation` bereitstellen. Herkunft: [ZUGFeRD-Konfiguration](https://github.com/itplr-kosit/validator-configuration-zugferd), [XRechnung-Konfiguration 3.0.2](https://github.com/itplr-kosit/validator-configuration-xrechnung/releases/tag/release-2024-06-20).

~~~bat
python package_runtime.py --sdk "Vendor\SaxonC" --validation-root "Validation"
~~~

Der Paketierer prüft DLL-Hash, das Vorhandensein der drei Szenariodateien, Lizenzdateien und Zielkonflikte vor dem Kopieren. Er übernimmt die technischen Regeln unter `build\Validation`, ergänzt DLL, Beispiel-CMD und Hinweise und schreibt ein Hashmanifest. Vorhandene fremde oder veränderte Zieldateien werden nicht still überschrieben. `--target` erlaubt einen anderen Paketordner; die drei EXE-Pfade können ebenfalls ausdrücklich angegeben werden. Ob die Regeln einschließlich ihrer Importe verwendbar sind, prüft anschließend ein tatsächlicher Validierungslauf; die Paketierung ersetzt diese Prüfung nicht.

Das erzeugte Paket dient zunächst der lokalen Prüfung. Die in [THIRD_PARTY.md](THIRD_PARTY.md) beschriebene Zuordnung des SaxonC-Quellcodes muss vor externer Binärweitergabe geklärt werden.

## Tests und Ressourcenpflege

~~~bat
python -m unittest discover -s Tests
python -m unittest discover -s Tests -p test_framework_resources.py
~~~

Die Python-Tests prüfen unter anderem Paketierung, Berichtvergleich, Quellcodeexport und die Bytegleichheit der fünf eingebetteten Framework-Ressourcen.

Die Originaldateien `scenarios.xsd`, `createReportInput.xsd`, `svrl-kosit.xsd`, `xml.xsd` und `identity.xsl` liegen direkt unter `Source`. Die Laufzeit verwendet weiterhin die Base64-Konstanten in `MGKositValidator.pas` und registriert ihre dekodierten Bytes unter logischen URIs im Speicher. Die lesbaren Dateien sind keine Laufzeitabhängigkeit. Ihre ursprünglichen Pfade sind an den Konstanten dokumentiert.

Bei Änderungen zuerst die Originaldatei bytegenau übernehmen, danach die Base64-Konstante aus denselben Bytes erzeugen und beide Darstellungen gemeinsam committen. Beispiel:

~~~bat
python -c "import base64,pathlib; print(base64.b64encode(pathlib.Path('Source/scenarios.xsd').read_bytes()).decode('ascii'))"
~~~

Die Delphi-Testprogramme unter `Tests` prüfen Engine, Pipeline, CLI, Streams, Wiederverwendung und das Beispiel. Sie schreiben ihre EXEs unter `Tests/build`. Argumente und Ergebnisse stehen in [docs/TESTING.md](docs/TESTING.md).

Das [PRP zur gezielten Testerweiterung](docs/prp/test-coverage/PRP.md) beschreibt den geplanten Abgleich mit den Originaltests, zusätzliche fachlich begründete Fälle und Java-/Delphi-Vergleiche. Die dort geplanten Tests sind vom vorhandenen Prüfnachweis zu unterscheiden.

MSXML-Diagnosen können sich von den Java-Diagnosen unterscheiden; insbesondere wird die erste MSXML-Schemadiagnose übernommen. Unbekannte Regeln und ungültige Laufzeitvoraussetzungen bleiben Fehler. Regelpakete müssen vertrauenswürdig sein. Das Projekt verspricht keine vollständige XPath-/XSLT-Sprachkonformitätsprüfung oder Dateisystem-Sandbox.

## Lizenz und Herkunft

Der Delphi-Code steht unter [Apache License 2.0](LICENSE). Übernommene KoSIT-Ressourcen behalten ihre ursprünglichen Hinweise. SaxonC-HE und die zusätzlichen Prüfregeln behalten ihre eigenen Lizenzen. Details und Quellcodeverweise stehen in [THIRD_PARTY.md](THIRD_PARTY.md) und [ThirdParty](ThirdParty).

Der MGGM XML Validator für Delphi ist eine unabhängige Implementierung und kein offizielles KoSIT-Projekt. Die Bezeichnung KoSIT verweist auf die Herkunft der übernommenen Framework-Ressourcen und des ursprünglichen Validierungsablaufs. Für ZUGFeRD beruht die Anwendung auf den veröffentlichten technischen Artefakten; die Wiedergabe des zugrunde liegenden Standards erfolgt mit Erlaubnis von CEN und DIN gemäß den [FeRD-Nutzungsrechten](https://www.ferd-net.de/ueber-uns/ressourcen-1/veroeffentlichungen/haftungsausschluss-und-nutzungsrechte).

Die private GitHub-Ablage und der Export ohne übergeordnete Git-Historie sind in [docs/PUBLICATION.md](docs/PUBLICATION.md) beschrieben.
