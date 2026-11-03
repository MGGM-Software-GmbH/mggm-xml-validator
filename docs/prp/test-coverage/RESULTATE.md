# Prüfnachweise zur Testabdeckung

Der Prüfauftrag steht im [PRP](PRP.md), die Zuordnung der Originalmethoden in der
[Methodenmatrix](METHODENMATRIX.md). [TESTING.md](../../TESTING.md) beschreibt die
reproduzierbare Ausführung. Annahme, öffentlicher Status und Berichtgültigkeit werden
getrennt geprüft. Eine Fallzahl allein belegt keine Gleichwertigkeit mit dem Original.

## Quellen und Fixtures

Referenz ist KoSIT validator v1.6.3, Commit
`37cddce28e15ac3a0319db006ab21d3f1064ca8c`. Die Inventur bindet 201 annotierte
Testmethoden in 41 Klassen, zehn Hilfsdateien und insgesamt 99 Java-Testquellen und
Testressourcen an ihre SHA-256. Server-, Daemon- und HTTP-Endpunkte bleiben außerhalb
des Delphi-Umfangs. Ausschlüsse sind einzeln in der Matrix begründet.

Die Matrix klassifiziert 134 Methoden als `covered` und 67 als `not_relevant`.
Es gibt keine verbleibende `new`-Zuordnung. Alle 99 gebundenen Quell- und
Ressourcendateien stimmen mit dem festgelegten Git-Commit überein.
Die zwölf Python-Tests der Inventurprüfung bestehen einschließlich ihrer
isolierten Gegenproben. Die Quellenbindung ersetzt nicht die in jedem
Matrixeintrag gesondert begründete fachliche Gleichwertigkeit.

Die zehn ausgewählten Referenzfälle liegen unter `Tests/Fixtures/reference`.
Die beiden inhaltlich unveränderten UBL-/CII-Beispiele und vier gekennzeichnete Ableitungen
stammen aus der KoSIT-XRechnung-Testsuite, Commit
`04cb0e80c14aaa4fb40c1118846570756dc534cd`, mit mitgeführter Apache-2.0-Lizenz.
Bei den beiden Ausgangsbeispielen sind ausschließlich die Zeilenenden von LF auf CRLF normalisiert. Das Fixture-Manifest unterscheidet Git-Quellhash und lokalen Dateihash; der Runner prüft die rücktransformierten Originalbytes offline. Vier Parser- und Szenariofälle sind synthetisch. Die ZUGFeRD-/Factur-X-Ableitungen
prüfen EN16931/Comfort mit ZUGFeRD 2.5.2 / Factur-X 1.09.2 und sind keine offiziellen
FeRD-Beispiele. Es werden keine privaten Rechnungen verwendet.

`fixture-manifest.json` legt Eingaben, Herkunft, Änderungen und Erwartungen fest.
`rule-hashes.json` bindet 219 lokale Regeldateien: XRechnung 3.0.2 mit Schematron 2.3.0
und EN16931 1.3.13 sowie ZUGFeRD 2.5.2 / Factur-X 1.09.2 und ZUGFeRD 1.0.
Der SHA-256 der geordneten Regeldateizuordnung ist
`bb36f36779ca35bdde59b0586e2805d3e7f21b7a95ac78d466a5f7fc34df97e3`.
Die Regeln liegen unter `build/Validation`; Java-JAR und native DLL werden separat
bereitgestellt. Sie sind keine Bestandteile des Fixture-Verzeichnisses.

## Ausgewählter Referenzlauf

Der Java-Referenzlauf verwendet die Laufmanifest-ID
`reference-verified-bb5413987e9748459bdacba2ae36690a` und die Vorbereitung am
1. November 2026 um 19:20:49 UTC mit Python 3.12.3.
Die zugehörige Manifestbindung steht im maschinenlesbaren Laufnachweis. Das aktuelle Fixture-Manifest bindet dieselben lokalen XML-Bytes und zusätzlich ihre tatsächlichen Git-Quellhashes.

Der Java-Nachweis dokumentiert Java 21.0.12.1, den Start am 1. November 2026
um 19:20:52 UTC und die Ausführungs-ID `c61c16edae3a48698600d265fb7dc352`.
Das lokale Standalone-JAR 1.6.3 hat SHA-256
`799e64befca97d4080e03608c80b85dd5a5ecc5f4ae4f35d1116ec2855b9a7c9`.
Es wurde direkt ohne Maven gestartet. Der tatsächliche Java-Exitcode ist 7 und
entspricht den sieben erwarteten Ablehnungen unter zehn Eingaben.

Die nativen Läufe prüfen dieselben lokalen XML-Bytes. Beide ergeben ebenfalls
Exitcode 7 und bestehen den strengen Berichtvergleich mit 10/10 Fällen sowie
17/17 Laufzeitgegenproben. Die drei angenommenen Eingaben enthalten einen
ZUGFeRD-Fall mit Warnung. Annahme bedeutet deshalb nicht automatisch Berichtgültigkeit.

| Compiler | Lauf-ID |
|---|---|
| Delphi 11 Alexandria | `7737C157-D35E-45C3-B60C-BA4E43698DAA` |
| Delphi 13 Florence | `65F64BA8-D35D-42BB-A408-883B7676B532` |

Beim 69.771 Byte großen Fall `dtd-prefix-hash` unterscheidet sich der tatsächliche
Java-Präfixhash vom Hash der gesamten Eingabe. Beide Delphi-Läufe liefern den
vollständigen SHA-256 `6bbb8d533753b109649477f560df378d2e55091903ea0b3141bc314c5e09618b`.

## Delphi- und Python-Prüfungen

Programme werden in Release und Testprogramme in Debug gebaut, jeweils für Win64.
Die aktuellen Build-IDs, Lauf-IDs und Datei-Hashes stehen im
[maschinenlesbaren Prüfnachweis](../../../Tests/publication-verification.json). Die aktuelle SVRL-Erweiterung und ihre Läufe stehen im [SVRL-Prüfnachweis](../../../Tests/svrl-metadata-verification.json).

| Runner | Delphi 11 | Delphi 13 |
|---|---|---|
| EngineTests | 59/59 | 59/59 |
| PipelineTests einschließlich aktueller XRechnung-Regeln | 39/39 | 39/39 |
| CliTests | 56/56 | 56/56 |
| NativeReuseTests | 22/22 | 22/22 |
| MemoryTransferTests | 14/14 | 14/14 |
| StreamAdapterTests | 4/4 | 4/4 |
| ParallelEngineTests | 16 Aufrufe, 8 überlappende Runden | 16 Aufrufe, 8 überlappende Runden |
| DelphiExampleTests | 17/17 | 17/17 |

Die Python-Suite besteht 159/159 Tests. Sie prüft unter anderem die Inventur,
Fixture- und Regelbindung, Gegenproben des Berichtvergleichs, Ressourcen,
Paketierung und Exportgrenzen. Server-, Daemon- und HTTP-Endpunkttests wurden
nicht übernommen.

Die Regressionen prüfen auch die dadurch erkannten Produktkorrekturen:
konkrete Pfade bei fehlenden Ressourcen, statische Prüfung von Szenario-XPath,
Frameworkversion 1.0.2 im ReportInput sowie Originalpositionen und mehrere
Schemafehler. Der CLI ordnet ein ausdrücklich gemeinsam angegebenes
Ressourcenverzeichnis allen Szenarien zu, meldet fehlende benannte Zuordnungen,
warnt bei unbenutzten Repositorydefinitionen und fehlenden Assertions und zeigt
bei Argumentfehlern einen Aufrufhinweis. Partielle Berichtseingaben behalten
technische Ressourcenfehler.

Die Sicherheitsprüfung lokaler Stylesheet-Imports gilt gemeinsam für `Transform`
und `TransformBytes`. Sie berücksichtigt auch transitive Imports, `xml:base`
und UTF-8-Prozentkodierung. Ein Hauptstylesheet erhält erst nach erfolgreicher
Kompilierung eine wiederverwendbare Sicherheitsfreigabe. Ein Compilerfehler
hinterlässt keine Freigabe; geänderte Ressourcenwurzeln und die Invalidierung
des nativen Caches erzwingen eine erneute Graphprüfung. Dadurch darf ein bereits
kompilierter Pfad eine entzogene Ressourcenfreigabe nicht weiterverwenden.

Sieben Engine-Fälle prüfen den Bytepfad: erlaubte transitive Imports, direkte und
transitive Wurzelüberschreitungen, Wiederverwendung, Freigabeentzug mit erneuter
Freigabe, native Cacheinvalidierung und Reparatur nach einem Compilerfehler.
16 wiederholte Transformationen erhöhen weder `StylesheetCompilationCount`
noch `DomMs`. Das ist ein Nachweis der Wiederverwendung des unveränderten
Importgraphen, keine allgemeine Laufzeitzusage.

Der gezielt fehlerhafte Zustand liefert im Lauf
`C4BD7554-EE2A-47CF-B2E9-A61316D33E8D` fünf fehlgeschlagene Sicherheitsfälle.
Die reguläre Implementierung besteht die Engine- und Pipeline-Prüfungen auf
beiden Compilern mit den folgenden Lauf-IDs.

| Runner | Delphi 11 | Delphi 13 |
|---|---|---|
| EngineTests, 59/59 | `02ABB026-219A-460D-BD74-B57F5CE0B85C` | `83A2FE89-45C7-458B-9F4D-B7AAF32D4B08` |
| PipelineTests, 32/32 | `51954F00-28E8-4D4C-867C-7F53AD34065C` | `213B2872-0526-443B-9849-0C13CFB47B5E` |

## Vergleichsvertrag und Grenzen

Der Vergleich prüft Szenario, Annahme, öffentlichen Status, Berichtgültigkeit,
Prüfphasen einschließlich übersprungener Phasen und Befund-Multimengen. Code,
Schweregrad, Location, Phase und fachlicher Text bleiben Teil jedes Befunds.
Er prüft Eingabehashes gegen die versionierten Eingabebytes, Berichtseingaben gegen das lokale XSD
mit `xmllint --nonet` sowie Inhalte der XML- und HTML-Berichte.

17 isolierte Laufzeitgegenproben gehören zum Werkzeug: Annahme, Status,
Gültigkeit, entfernte, zusätzliche und duplizierte Befunde, Code, Schweregrad,
Location, Text, Phase, Berichtstruktur, Bericht- und Berichtseingabehash,
Berichtseingabeschema und HTML werden manipuliert und müssen erkannt werden.
Die zulässige Zeitstempeländerung muss vergleichbar bleiben. Ein leerer Korpus,
fehlende Berichte und fehlende Gegenproben sind Fehler.

Die drei eng begrenzten Diagnoseklassen betreffen unerwartete Schemaelemente,
ungeschlossene XML-Dokumente und verbotene DTDs. Ihre semantischen Merkmale
werden weiterhin geprüft. Beim DTD-Abbruch ist ausschließlich für Java ein
nachgewiesener Hash des gelesenen Eingabepräfixes zugelassen. Delphi muss alle
Originalbytes hashen; `dtd-prefix-hash` prüft dafür einen längeren Eingaberest.
Explizite zusätzliche Hostpfade derselben Eingabe dürfen als `input_aliases`
geführt werden. Eine fremde Dokumentreferenz bleibt ein Fehler.

Der gesonderte vorhandene Fall `zf-minimum` zeigt eine echte Engineabweichung:
Java meldet zwei Schemafehler, MSXML sieben. Beide lehnen die Eingabe ab.
Diese unterschiedliche Befundmenge wird nicht zu einem erfolgreichen strengen
Vergleich normalisiert. Sie ist vom neuen, manifestgebundenen Zehn-Fälle-Korpus
zu unterscheiden und begründet keine allgemeine Austauschbarkeit der Diagnosen.

Der gesonderte 23-Dateien-Lauf verwendet die geprüften Programme und eine
eigens erzeugte Java-Referenz. Alle 23 Eingabeidentitäten, Entscheidungen
und Schematron-Befundmengen stimmen überein. Die aktuellen Delphi-11-/13-Signaturen
und öffentlichen Ergebnisse sind für alle 23 Eingaben identisch. Unter den
dokumentierten Providerdiagnoseausnahmen stimmen 22/23 strenge Artefaktvergleiche
überein; `zf-minimum` bleibt abweichend. Die fünf zusätzlichen MSXML-Diagnosen
betreffen zweimal `CityName`, zweimal `LineOne` und einmal `LineTwo`. Keiner der
beiden gemeinsamen Schemafehler fehlt. Der historische Bestand enthält keinen
öffentlichen CLI-Status als Referenz; dessen Vergleich gilt hier zwischen den
beiden aktuellen Compilern. Der kleinere DTD-Fall weist den Java-Präfixhash über
32 von 55 Bytes nach, während beide Delphi-Läufe sämtliche 55 Bytes hashen.

Win32, weitere Delphi-Versionen und ein Windows-Rechner ohne Entwicklungswerkzeuge
sind durch diese Läufe nicht geprüft. Der ausgewählte lokale JAR-Lauf ist von der
gesamten Original-Java-Testsuite zu unterscheiden. Er belegt keine allgemeine
XPath-/XSLT-Sprachkonformität, Dateisystem-Sandbox oder PDF-Prüfung.
