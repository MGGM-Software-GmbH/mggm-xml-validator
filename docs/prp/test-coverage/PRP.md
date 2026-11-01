# PRP: Risikoorientierte Testabdeckung

## Auftrag und Ergebnis

Die Tests des eigenständigen MGGM XML Validators für Delphi sollen gezielt Fehler erkennen,
die zu falscher Annahme, verlorenen Befunden, unbrauchbaren Berichten oder unsicherem
Ressourcenzugriff führen. Eine höhere Testzahl ist kein eigenes Ziel.

Dieses PRP beschreibt die spätere Umsetzung. Es erweitert weder Tests noch Produktcode.
Originaltests für Server, Daemon und HTTP-Endpunkte werden nicht übernommen.
Java dient ausschließlich als Referenz im Entwicklungsprozess, nicht als Delphi-Laufzeitabhängigkeit.

Ergebnis der Umsetzung sind belegte Lückenentscheidungen, passende Regressionstests,
reproduzierbare Vergleichsläufe und aktuelle Prüfanweisungen. Vorhandene Runner werden erweitert.
Es wird kein neues Testframework und keine Nachbildung interner Java-Klassen mit Mock-Objekten gebaut.

## Quellen und gesicherter Bestand

Maßgebliche Projektquellen sind [TESTING.md](../../TESTING.md), die Programme unter
`Tests`, `compare_reports.py` und [publication-verification.json](../../../Tests/publication-verification.json).
Der Prüfnachweis dokumentiert die folgenden vorhandenen Suite-Ergebnisse für Delphi 11 und 13,
jeweils für Win64. Das PRP selbst führt diese Tests nicht aus:

| Suite | Dokumentiertes Ergebnis | Bestehender Schwerpunkt |
|---|---|---|
| `EngineTests` | 38/38 | Parser, lokale XSD-Auflösung, Cache, Langpfade, Sicherheitsgrenzen |
| `PipelineTests` | 16/16 | Szenarien, Annahme, Status, Berichte, Fehler und Stream-Eingabe |
| `CliTests` | 16/16 | CLI-Aufrufe, Assertions, Ausgabeverhalten und Fehler |
| `StreamAdapterTests` | 4/4 | Stream-Anbindung |
| `NativeReuseTests` | 20/20 | Kontextwechsel, Wiederverwendung, Fehlererholung und Serialisierung |
| `MemoryTransferTests` | 14/14 | Speicherübergabe, Eingabeposition, Encodings, Betrieb ohne Tempdateien |
| `ParallelEngineTests` | 16 Aufrufe, 8 überlappende Runden | Parallele isolierte Validierungen |
| `DelphiExampleTests` | 17/17 | Beispielprogramm, Pfade, fehlende Voraussetzungen und Ausgabeschutz |
| Python | 81/81 | Paketierung, Quellpaket, Ressourcen und Auswertungswerkzeuge |
| Berichtskorpus | 23/23 | Normierte Regression gegen gesicherten Bestand, kein erneuter Java-Lauf |

Die Fallzahlen belegen keine lückenlose Übernahme der Originalsemantik.
`PipelineTests` nennt bereits Originalmethoden in `SourceExpectation`, beispielsweise
`DefaultCheckTest.testHappyCase`, `testRejectAcceptMatch` und `testSchematronExecutionError`.
Diese Hinweise sind Ausgangspunkte für die Inventur, keine pauschale Abdeckungszusage.

Referenz ist [KoSIT validator v1.6.3](https://github.com/itplr-kosit/validator/tree/v1.6.3),
Commit `37cddce28e15ac3a0319db006ab21d3f1064ca8c`.
Der separat dokumentierte Original-Lauf mit Java `21.0.12.1` und Maven `3.9.9` ergab
192 Tests in 37 Surefire-Klassen und 9 Integrationstests in 4 Failsafe-Klassen,
ohne Fehler oder übersprungene Tests. Alle 313 Originalquelldateien wurden unverändert verglichen.
Die Originalergebnisse liegen außerhalb dieses Repositorys und werden hier nicht als neuer Testlauf ausgegeben.

## Abgrenzung

- Im Umfang: öffentliche Delphi-API, CLI, lokale Validierung, Berichte, Ressourcenauflösung,
  Speicher- und Dateiverarbeitung sowie die vorhandenen Prüfwerkzeuge.
- Ausgeschlossen: Original-Server, Daemon, HTTP-Endpunkte, Weboberflächen und deren Integrationstests.
- Lokale Sicherheitsprüfungen für verbotene URI-Schemata bleiben relevant. Sie benötigen
  keinen HTTP-Server, keinen Abruf und keine Internetverbindung.
- Java-spezifische Builder, JAR-Zugriffe, DOM-/XdmNode-Typen oder austauschbare Java-Provider
  werden nur dann fachlich übertragen, wenn ein entsprechender öffentlicher Delphi-Vertrag existiert.
  Fehlende Java-Implementierungsdetails rechtfertigen keine neue Delphi-API.
- Performance bleibt in `BenchmarkRuns` und den vorhandenen Auswertungswerkzeugen.
  Fachliche Tests erhalten keine festen Zeitgrenzen als Leistungsbehauptung.
  Technische Prozess-Timeouts zum Erkennen hängender Läufe bleiben davon getrennt.
- Keine privaten Rechnungen, zusätzlichen Plattformversprechen oder allgemeine Konformitätsaussage
  zu XRechnung oder ZUGFeRD.

## Prioritäten und fachliche Prüfpunkte

Die folgenden Bereiche sind Prüfaufträge. Welche Fälle neu anzulegen sind, entscheidet die
Methodenmatrix anhand vorhandener Assertions. Bereits gleichwertig geprüfte Fälle werden verknüpft.

| Priorität | Fehlerrisiko und zu prüfender Vertrag | Bezug und vorgesehener Runner |
|---|---|---|
| P0 | Annahme wird mit technischem Status oder Schema-Gültigkeit verwechselt | `ComputeAcceptanceActionTest`, `DefaultCheckTest`; `PipelineTests` |
| P0 | Ein Befund, dessen Schweregrad oder Location geht verloren; Dubletten verschwinden | `SchematronValidationActionTest`, `CreateReportActionTest`; Pipeline und Berichtvergleich |
| P0 | Ein defektes Schema, Stylesheet oder eine Konfiguration wird als fachliche Ablehnung versteckt | `SchemaValidatorActionTest`, `DocumentParseActionTest`, Konfigurationstests; Engine und Pipeline |
| P0 | Falsches oder mehrdeutiges Szenario wird gewählt; fehlende Prüfphasen werden als Erfolg behandelt | `ScenarioRepositoryTest`, `SimpleScenarioCheckTest`, Annahmetests; Pipeline |
| P0 | Relative Ressourcen umgehen lokale Grenzen oder verwenden einen fremden Dokumentkontext | Resolver- und Sicherheitstests; Engine und NativeReuse |
| P1 | Berichte, Eingabebytes oder Hashes verändern sich bei Datei-/Stream-/Byte-Eingaben | `InputFactoryTest`, Report- und Serialisierungstests; MemoryTransfer und Pipeline |
| P1 | CLI-Fehlercode, Assertion, Dateiname oder Ausgabeschutz widerspricht dem dokumentierten Vertrag | `CommandlineApplicationTest`, Actions und Naming-Tests; CliTests |
| P1 | Reale Regelpakete funktionieren nur für einen günstigen Beispielfall | Kleine repräsentative Auswahl aus offiziellen Standard-Fixtures; Pipeline und Berichtvergleich |
| P2 | Wiederholungs- und Parallelfälle sind ohne zusätzlichen Fehlernachweis redundant | Bestehende NativeReuse-, Parallel- und Python-Tests gezielt auf Assertions prüfen |

Für P0 sind mindestens folgende unterscheidbare Ergebnisse abzudecken, soweit noch nicht belegt:

1. Gültiges Dokument mit Annahme, fachlich ungültiges Dokument ohne Annahme sowie
   explizite Ablehnung ohne Befund.
2. `acceptMatch` erfüllt und nicht erfüllt, einschließlich Schematron-Fehler sowie
   ungültigem Schema. Annahme und Status werden jeweils separat geprüft.
3. Warnung gegenüber Fehler, mehrere Befunde einschließlich gleicher Codes mit verschiedenen
   Locations und identischen doppelten Befunden.
4. Kein Szenario, mehrere passende Szenarien, Parserfehler und XSLT-Laufzeitfehler.
   Erwartete übersprungene Phasen und vorhandene Berichte werden ausdrücklich geprüft.
5. Fehlerhafte oder fehlende Konfiguration, Ressource oder Import sowie anschließender
   gültiger Aufruf. Fehlerursache und Wiederverwendbarkeit sind getrennte Assertions.
6. Erlaubter lokaler Import gegenüber Wurzelüberschreitung und verbotenem externem Zugriff.
   Ein reines Fehlschlagen ohne passende Diagnose genügt nicht.

Die Standard-Fixtures ergänzen diese generischen Verträge:

- Je ein gültiges offizielles UBL- und CII-Beispiel für die festgelegte XRechnung-Regelversion.
- Je ein gezielt abgeleiteter negativer Fall für einen Schemafehler und einen eindeutigen
  Geschäftsregelverstoß, mit erwartetem Code und Schweregrad.
- Ein gültiges ZUGFeRD-/Factur-X-XML-Beispiel und eine gezielte negative Variante für ein
  vom vorhandenen Regelpaket unterstütztes Profil. Profil und Regelversion explizit festlegen.
- Keine PDF-Einbettungstests als Ersatz für XML-Validierung. Fehlende passende Regeln oder
  veröffentlichbare Fixtures werden als Voraussetzung gemeldet, nicht stillschweigend ersetzt.

Die Auswahl muss unterschiedliche Validierungswege belegen. Mehrere Rechnungen mit denselben
Regeln und denselben erwarteten Befunden werden nicht allein zur Vergrößerung des Korpus aufgenommen.

## Deliverable: Methodenmatrix des Originals

In der Umsetzung entsteht eine versionierte Matrix neben diesem PRP. Jede Original-Testmethode
aus `src/test/java` erhält einen Eintrag; parametrisierte Methoden nennen zusätzlich die
fachlich unterschiedlichen Varianten. Die Inventur berücksichtigt Testannotationen,
Vererbung und Datenquellen, nicht nur Dateinamen oder ausgeführte Fallzahlen.

Pflichtspalten:

| Feld | Inhalt |
|---|---|
| `source` | Commit, relativer Dateipfad, Klasse, Methode und Quellzeile |
| `contract` | Fachlich beobachtbares Verhalten und relevante Varianten |
| `classification` | `covered`, `new` oder `not_relevant` |
| `reason` | Begründung der Zuordnung, bei Ausschluss genaue Umfangs- oder API-Grenze |
| `target` | Delphi-/Python-Datei, Fallname und konkrete Assertion; bei neuen Fällen Zielrunner |
| `evidence` | Lauf-ID, Ergebnis und Artefaktverweis nach Umsetzung |

`covered` erfordert einen belegten gleichwertigen Prüfinhalt. Eine Namensähnlichkeit reicht nicht.
`new` benennt eine konkrete Lücke, keine automatische Eins-zu-eins-Portierung der Java-Methode.
`not_relevant` bleibt sichtbar, einschließlich aller ausgeschlossenen Server-/Daemon-/HTTP-Methoden.
Reine Hilfsmethoden und Beispiele ohne Testfunktion werden als Inventurabgrenzung dokumentiert.
Vor der Abnahme bleiben keine ungeklärten Zuordnungen und keine unbelegten `covered`-Einträge.

## Referenzvergleich und aussagekräftige Gegenproben

`compare_reports.py` wird erweitert, ohne echte Abweichungen wegzunormalisieren.
Der vorhandene Vergleich erfasst unter anderem Szenario, Annahme, Schritte, Schematron-Befunde,
Dokumentdaten und Hash. XML-Schema- und Parserdiagnosen werden bislang nicht als Befundmenge verglichen.
Die vorhandene DTD-Hashausnahme ist ausdrücklich zu bewerten und separat nachzuweisen.
Eine isolierte Gegenprobe mit leerem Manifest liefert derzeit Exitcode 0 bei 0/0 Fällen
und nicht ausgeführter Befund-Gegenprobe. Der Ausbau muss leere Korpora, fehlende Referenzberichte
und nicht ausgeführte vorgeschriebene Gegenproben als Fehler erkennen.

Der neue Vergleichsvertrag umfasst:

- Annahme, öffentlichen Status und Gültigkeitsentscheid getrennt; keine Ableitung von
  Annahme allein aus dem Vorkommen oder Fehlen von Fehlern.
- Szenarioidentität, Prüfphasen mit Ergebnis und Skip-Verhalten sowie relevante Berichtstruktur.
- Befund-Multimenge mit Code, Schweregrad, Location, Prüfphase und fachlichem Meldungstext.
  Reihenfolge darf nur bei nachgewiesen irrelevanter Reihenfolge vereinheitlicht werden;
  Häufigkeit, fehlende und zusätzliche Befunde bleiben sichtbar.
- Eingabeidentität und Hash gegen die tatsächlichen Originalbytes, nicht nur gegen Java.
- Berichtseingabe gegen das vorhandene Schema sowie relevante Inhalte des erzeugten
  XML- und HTML-Berichts. Vorhandensein einer HTML-Datei allein genügt nicht.

Namespace-Präfixe, Attributreihenfolge und nachweislich irrelevante XML-Formatierung dürfen
strukturell vereinheitlicht werden. Text und Locations werden nicht pauschal gekürzt oder entfernt.
Zeitstempel und engineabhängige Diagnoseformatierung erhalten nur eng begrenzte, dokumentierte
Ausnahmen pro Feld und Fehlerklasse. Erwartete semantische Diagnosemerkmale bleiben verpflichtend.
Die unterschiedliche DTD-Hashbildung darf keine falsche Delphi-Eingabeidentität verdecken.
Jede weitere echte Vertragsabweichung wird berichtet und entschieden, nicht durch eine neue
Normalisierungsregel automatisch akzeptiert.

Für jedes unterschiedliche Fehlerverhalten des Vergleichswerkzeugs eine isolierte Gegenprobe:

| Manipulation an einer temporären Berichtkopie | Erwartung |
|---|---|
| Annahme oder Status ändern | Vergleich schlägt fehl |
| Befund entfernen, hinzufügen oder duplizieren | Vergleich schlägt wegen anderer Multimenge fehl |
| Code, Schweregrad oder Location ändern | Vergleich schlägt mit benanntem Feld fehl |
| Prüfphase oder notwendige Berichtstruktur entfernen | Vergleich schlägt fehl |
| Eingabehash verändern | Eigenständige Hashprüfung schlägt fehl |
| Leeres Manifest oder nicht ausgeführte vorgeschriebene Gegenprobe | Vergleich schlägt statt eines 0/0-Erfolgs fehl |
| Nur erlaubtes Zeitstempelfeld ändern | Vergleich bleibt erfolgreich |
| Diagnoseformat innerhalb einer belegten Ausnahme ändern | Erfolg nur bei erhaltenen semantischen Merkmalen |

Jede Gegenprobe beginnt mit einem unveränderten gültigen Vergleich. Manipulierte Kopien
werden nicht als Referenzbestand gespeichert. Bei Produktfixes ist der Defekt nach Möglichkeit
vorher reproduzierbar zu zeigen und der Regressionstest anschließend im regulären Code erneut auszuführen.

## Fixtures, Lizenz und reproduzierbare Ausführung

Ein Fixture-Manifest nennt Quelle, Lizenzdatei, Originalpfad, Release/Commit, SHA-256,
Regelpaketversion und Zweck jedes übernommenen oder abgeleiteten Falls. Ableitungen nennen
die gezielte Änderung und behalten die Provenienz. Lizenzbedingungen vor Übernahme prüfen;
Quellcode-Lizenz nicht ungeprüft auf fremde Rechnungsbeispiele übertragen.

Normale Tests arbeiten mit lokalen, unveränderlichen Fixtures und Regeln ohne Internetzugriff.
Einrichtung und gesonderter Referenzlauf dürfen benötigte öffentliche Artefakte beschaffen;
Version und Hash müssen vor Verwendung geprüft werden. Fehlende Voraussetzungen erzeugen
einen sichtbaren Fehler, keinen erfolgreichen übersprungenen Vergleich.

`docs/TESTING.md` wird um genaue Befehle, Arbeitsverzeichnisse und Ergebnisdateien ergänzt.
Zu protokollieren sind Delphi-Version, Win64-Konfiguration, DLL-Version und -Hash,
Python-Version, Java-/Maven-Version im Referenzlauf, Regel- und Fixture-Hashes sowie Lauf-IDs.
Die geprüften Compiler sind Delphi 11 Alexandria und Delphi 13 Florence, jeweils für Win64.
Weitere Compiler-Versionen und Plattformen gelten erst nach eigenen Läufen als geprüft.
Delphi-Builds und Teststarts verwenden den verfügbaren dokumentierten Buildzugang.
Java-Abhängigkeiten werden vor einem anschließenden Offline-Referenzlauf bereitgestellt.
Dieser Referenzlauf prüft die ausgewählten lokalen Eingaben mit beiden Validatoren. Er ist
von der gesamten Original-Testsuite zu unterscheiden: Deren `RemoteResolvingStrategyTest`
verwendet einen externen Schemaimport und ist kein Nachweis für einen Offline-Testlauf.
Ergebnisverzeichnisse sind je Lauf neu; alte Erfolgsmeldungen gelten nicht als aktueller Nachweis.

## Umsetzungspakete und Abnahme

1. **Inventur:** Originalmethoden und vorhandene Assertions zuordnen, Ausschlüsse begründen,
   konkrete P0-/P1-Lücken und benötigte Fixtures festlegen.
2. **Fixtures und Vergleich:** Provenienz sichern, Vergleichsvertrag implementieren und
   dessen gültige Fälle sowie jede fachlich unterschiedliche Gegenprobe prüfen.
3. **Regressionen:** Priorisierte Lücken in bestehenden Runnern schließen. Repräsentative
   Standardfälle ergänzen, danach verbleibende P1-Lücken aus der Matrix bearbeiten.
4. **Gesamtnachweis:** Betroffene und vorgeschriebene Projektsuiten ausführen,
   Original-/Delphi-Vergleich mit identischen Eingaben erstellen, Dokumentation und Matrix aktualisieren.

Abnahmebedingungen der Umsetzung:

- Jede Original-Testmethode hat eine begründete Zuordnung und die eingeschlossenen Lücken
  besitzen konkrete Assertions statt bloßer Ausführungs- oder Dateiexistenzprüfungen.
- P0 und die begründete P1-Auswahl laufen mit belegten Ergebnissen; erkannte Produktfehler
  sind behoben und geprüft oder als konkrete Blocker mit betroffenen Fällen benannt.
- Vergleich und Gegenproben erkennen die beschriebenen Veränderungen; keine neue
  pauschale Normalisierung verschluckt fachliche Unterschiede.
- Bestehende Regressionen bleiben nachgewiesen. Fallzahlen werden berichtet, aber nicht als Ziel vorgegeben.
- Fixtures sind veröffentlichbar, lokal reproduzierbar und unabhängig von privaten Daten.
- Server-/Daemon-/HTTP-Tests wurden nicht in den Delphi-Umfang aufgenommen.

## Risiken und Aufwand

Die Methodenmatrix kann zusätzliche öffentliche Verträge oder echte Unterschiede zwischen den
Engines offenlegen. Unklare Verträge, nicht verfügbare Regeln oder ungeklärte Fixture-Lizenzen
benötigen eine konkrete Entscheidung; sie werden nicht durch erfundene Erwartungen ersetzt.
Original-Fixtures sind bislang teilweise externe Voraussetzungen. Ihre lizenzierte und
versionierte Bereitstellung ist daher Teil der Umsetzung, kein vorhandener Repository-Nachweis.

Grobe Schätzung: 4 bis 8 Stunden Agentenbearbeitungszeit für Inventur, gezielte Tests,
Vergleich, Gegenproben und Dokumentation bei verfügbarem Buildzugang und verwendbaren Fixtures.
Dabei entdeckte Produktfehler sowie fehlende Lizenzen, Zugänge oder Regelpakete sind darin nicht enthalten.
