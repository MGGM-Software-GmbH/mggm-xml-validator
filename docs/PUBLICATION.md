# Vorbereitung des Quellrepositories

Der MGGM XML Validator für Delphi wird unter dem Repositorynamen `mggm-xml-validator` als eigenständig nutzbares Delphi-Projekt mit Apache-2.0-Lizenz, nachvollziehbaren Drittanbieterbedingungen, Bibliothek, CLI und kleinem Dateibeispiel gepflegt. Er ist ein unabhängiges Projekt der MGGM Software GmbH und kein offizielles KoSIT-Projekt. Hinweise auf KoSIT benennen die Herkunft übernommener Ressourcen und des ursprünglichen Validierungsablaufs.

Der lokale Laufzeitordner heißt `build`; `MGGMXmlValidator.exe`, `MGGMXmlValidatorBatch.exe`, `ValidateXmlExample.exe`, DLL und `Validation` liegen zusammen. Eingebettete Framework-Ressourcen bleiben im Speicher registriert. Die öffentlichen Unit- und Klassennamen `MGKosit` und `TMGKositValidator` bleiben für bestehende Delphi-Aufrufer erhalten.

## Inhalt und Nachweise

Der Quellstand enthält ausschließlich Bibliothek, Konsolenprogramme, generische Beispiele, Tests, Paketierungswerkzeuge, Dokumentation und Lizenzhinweise. Projektspezifische Messprogramme und interne Laufprotokolle werden außerhalb dieses Quellverzeichnisses erhalten. Generierte EXEs, DLLs, Regelpakete und Compilerdateien gehören nicht zum Git-Quellstand.

Die Prüfung umfasst Build, Bytevergleich der eingebetteten Ressourcen, Paketierungsgegenproben, den Start aus einem fremden Arbeitsverzeichnis sowie gültige und fehlerhafte XML-Eingaben. Ergebnisse stehen in [Tests/publication-verification.json](../Tests/publication-verification.json). Für eine externe Binärweitergabe bleibt die in [THIRD_PARTY.md](../THIRD_PARTY.md) erläuterte SaxonC-Quellcodezuordnung zu klären.

## Privates GitHub-Quellrepository

GitHub unterstützt private Repositories. Sie sind für berechtigte Benutzer und bei Organisationsrepositories insbesondere für Organisationsinhaber sichtbar. Zusätzliche Organisationsrechte und Teamberechtigungen bestimmen den weiteren Zugriff. `Private` bedeutet daher nicht, dass allein der Ersteller Zugriff hat. Grundlage: [GitHub-Dokumentation zur Sichtbarkeit](https://docs.github.com/en/repositories/creating-and-managing-repositories/about-repositories).

Das GitHub-Ziel ist [MGGM-Software-GmbH/mggm-xml-validator](https://github.com/MGGM-Software-GmbH/mggm-xml-validator) mit Sichtbarkeit `private`. Für den Upload werden keine zusätzlichen Personen oder Teams berechtigt. Bestehende Organisationsrechte gelten weiterhin. Die Sichtbarkeit wird vor dem Push und anschließend erneut über die GitHub-API geprüft.

Der hochgeladene Stand enthält den vorhandenen Produktcode und das [PRP zur gezielten Testerweiterung](prp/test-coverage/PRP.md). Das PRP beschreibt geplante Arbeiten; diese Testerweiterung wird durch den Upload nicht umgesetzt. Es wird kein Binärrelease erzeugt.

## Export ohne fremde Historie

Das Arbeitsverzeichnis liegt in einem übergeordneten lokalen Checkpoint-Repository. Diese Historie darf nicht als Historie des neuen Quellrepositories übernommen werden. Der Export kopiert nur vorgesehene Projektdateien in einen neuen Ordner und enthält kein `.git`:

~~~bat
python export_source.py "C:\Export\mggm-xml-validator"
~~~

Das Ziel muss neu sein und außerhalb dieses Projektverzeichnisses liegen. Der Export erhält für GitHub ein eigenes Git-Repository mit `main` als Hauptbranch und `origin` als Remote. Das Entwicklungsverzeichnis bleibt im übergeordneten lokalen Checkpoint-Repository. Weitere Uploads müssen daher bewusst über das eigenständige GitHub-Repository erfolgen; ein Push aus dem übergeordneten Repository gehört nicht zu diesem Ablauf.

Ein Quellcodeexport enthält keine Saxon-DLL und keine heruntergeladenen Regelpakete; diese werden lokal nach den dokumentierten Voraussetzungen ergänzt. Vor dem Upload werden Dateiliste und Bytes des Exports mit dem vorgesehenen Quellstand verglichen. Die GitHub-Dateiliste und der Commit werden nach dem Push mit dem Export abgeglichen.

Ein späterer Wechsel von privat zu öffentlich ist ein eigener Veröffentlichungsschritt. Die Apache-Lizenz des Quellcodes erfordert keine sofortige öffentliche Sichtbarkeit des Repositories.
