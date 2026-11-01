# Methodenmatrix des Originals

Die verbindlichen Einzelzuordnungen stehen in [original-method-matrix.json](original-method-matrix.json).
Jeder Eintrag nennt Originalcommit, Datei, Klasse, Methode, Deklarations- und Annotationszeile,
Quellhashes, Vertrag, Varianten, Klassifikation, Begründung, Zielfall und konkrete Assertions.
`covered` verweist auf tatsächliche Lauf-IDs. `new` bezeichnet fehlende oder noch nicht nachgewiesene
Assertions, auch wenn andere Teile derselben Methode bereits geprüft sind.
`not_relevant` bezeichnet die im jeweiligen Eintrag erklärte öffentliche API- oder Umfangsgrenze.

Der geprüfte Stand enthält **134 `covered`, 0 `new` und 67 `not_relevant`**.
Jede der 134 übertragenen Methoden nennt die tatsächlich bestandenen Zielfälle und die
getrennten Ergebnisse für Delphi 11 Alexandria und Delphi 13 Florence, jeweils Win64.
Die 67 Ausschlüsse betreffen die unten beschriebenen Umfangs- und API-Grenzen. Sie werden
nicht wegen des Umsetzungsaufwands ausgeschlossen.

Der Originalstand ist KoSIT validator v1.6.3, Commit
`37cddce28e15ac3a0319db006ab21d3f1064ca8c`. Die aus den Quellen ermittelte Inventur umfasst
201 annotierte Methoden in 41 Testklassen: 192 Unitmethoden und 9 Integrationstestmethoden.
Die Übereinstimmung mit den dokumentierten ausgeführten Fallzahlen wurde anhand der Quellen
festgestellt. Die Fallzahlen waren nicht die Inventurgrundlage.

Der Quellstand enthält keine JUnit-Parametertests und keine externen Parameterprovider.
Methodeninterne Varianten bleiben trotzdem sichtbar. Dazu gehören insbesondere die fünf
`evil*.xsl`-Eingaben, vier Datumsvarianten, die Präfix-/Postfixzustände der vier Namingmethoden,
unterschiedliche Namespacekontexte und wiederholte Reader-/DOM-/XdmNode-Aufrufe.
Die beiden Java-Listenüberladungen verwenden jeweils `MULTI_COUNT=5`.
Die vier Integrationstestklassen erben von `BaseIT`. Diese Basisklasse enthält Lifecycle- und
Serverhilfen, aber keine zusätzliche annotierte Testmethode.

Die zehn Java-Dateien ohne Testannotation stehen unter `helpers`, einschließlich der
Dokumentationsbeispiele und Testdatenfabriken. Das Feld `classes` hält alle Hauptklassen und
ihre Basisklassen fest. `files` sichert die 51 Java-Testquelldateien und 48 Testressourcen mit
SHA-256. Damit bleiben auch die bei Methodenvarianten benutzten Hilfsquellen und Daten gebunden.

Vom Repositoryverzeichnis aus:

```bash
python3 verify_original_test_inventory.py /absoluter/pfad/zum/validator-1.6.3
python3 -m unittest discover -s Tests -p test_original_test_inventory.py -v
```

Die erste Prüfung verlangt dieselben Methoden, Fundstellen, Methoden- und Dateihashes,
Hilfsdateien, Vererbungsangaben und Testressourcen. Eine vorhandene `.git`-Metadatenwurzel
muss zusätzlich den festgelegten Commit ausweisen. Beim hier verwendeten unveränderten
Quellarchiv ohne `.git` wird die Byteidentität gegen die gespeicherten Hashes geprüft.
Zusätzlich wurden alle 99 Dateien direkt mit `git show
37cddce28e15ac3a0319db006ab21d3f1064ca8c:<path>` aus dem Repository `kosit-validator`
verglichen: 99 Hashprüfungen, 0 Abweichungen. `source_verification` hält Zeitpunkt,
Quellcommit und Ergebnis dieses unabhängigen Git-Objektabgleichs fest.
Fehlende Quellen, unbekannte Testannotationen oder Parameterprovider, zusätzliche Testmethoden
und nicht inventarisierte geerbte Tests sind Fehler.

Die zwölf Gegenproben verwenden ausschließlich temporäre Java-Fixtures. Sie prüfen einen
gültigen Bestand und die Erkennung von geänderten Methoden und Testdaten, fehlenden oder
doppelten Einträgen, unbelegtem `covered`, unzulässiger Klassifikation, fehlenden Varianten,
unbekannten Parametertestprovidern und geerbten Testmethoden. Kommentare und Zeichenketten
mit scheinbaren Testannotationen oder geschweiften Klammern verfälschen die Inventur nicht.

Die Inventurprüfung belegt Vollzähligkeit und Quellenbindung. Die fachliche Gleichwertigkeit
der Zielfälle ist die gesonderte, im jeweiligen Eintrag begründete Zuordnung. Der Prüfer führt
weder Delphi-Tests noch die Originalsuite aus. Ein grüner Inventurlauf ersetzt keine aktuellen
Laufnachweise für ergänzte Assertions.

Alle 134 eingeschlossenen Methoden sind als `current-regression` mit den aktuellen
Ergebnisartefakten, Ausführungsartefakten, Lauf-IDs, Compilerangaben und ausdrücklich bestandenen
Zielfällen belegt. Die Nachweise verweisen auf die folgenden ausgeführten Suiten:

| Suite | Delphi 11 Win64 | Delphi 13 Win64 |
|---|---|---|
| `CliTests` | 56/56, `E8A00DBD-075D-421D-BEBF-EE7509673AD1` | 56/56, `6019F345-696A-44BF-8B3B-31243E3AF8C8` |
| `PipelineTests` | 32/32, `51954F00-28E8-4D4C-867C-7F53AD34065C` | 32/32, `213B2872-0526-443B-9849-0C13CFB47B5E` |
| `EngineTests` | 59/59, `02ABB026-219A-460D-BD74-B57F5CE0B85C` | 59/59, `83A2FE89-45C7-458B-9F4D-B7AAF32D4B08` |
| `NativeReuseTests` | 22/22, `D69DCEC0-21AC-4F19-9DF0-6B81506D8B16` | 22/22, `26A6EF2E-5A2A-459F-9B43-7CF5336DC73F` |
| `MemoryTransferTests` | 14/14, `077A58B9-A6A9-4C65-A7FC-F910A1FB3501` | 14/14, `37D20017-2A2D-436A-A1AB-30886671697B` |

Diese Suitezahlen ersetzen nicht die Einzelzuordnung. Mehrere Originalmethoden können denselben
Zielfall nutzen; ein Originaltest kann mehrere getrennte Zielfälle benötigen. Die Begründung und
Assertions des jeweiligen Eintrags bestimmen die übertragene Semantik.

Ein `pending`-Eintrag wäre kein erfolgreicher Lauf. Nach Ergänzungen sind Zielfall, Assertions,
Klassifikation und Nachweis gemeinsam zu pflegen.

`implementation_status=assertions_verified_both_compilers` kennzeichnet die 134 mit beiden
Compilern geprüften Zuordnungen.
Bei mehreren ausgeführten Zielfällen nennt `target.cases` alle Fälle, beispielsweise die vier
Namenszustände oder fünf Sicherheitsvarianten. `target.line` ist die bei dieser Zuordnung
ermittelte Fundstelle; nach weiteren Änderungen kann sie sich verschieben. Der Fallname bleibt
deshalb die maßgebliche Kennung. Ein `covered`-Eintrag benötigt mindestens einen erfolgreichen
Laufnachweis mit Lauf-ID; eine bloße nicht leere `pending`-Liste wird als Fehler erkannt.

Die Wurzelgrenzen werden auch auf dem Bytepfad geprüft: erlaubte transitive Includes mit
`xml:base` und prozentkodierten Namen, direkte und transitive Wurzelüberschreitungen sowie
Entzug und erneute Freigabe einer bereits verwendeten Ressourcenwurzel. Die zusätzlichen
Cacheassertions prüfen 16 Wiederholungen ohne neue Kompilierung oder Graphprüfung, erneute
Prüfung nach Native-Cacheinvalidierung und fehlende Sicherheitsfreigabe nach einem
Compilerfehler. Gehören diese ergänzenden Fälle zu einem anderen Runner als der Hauptfall,
stehen sie unter `target.additional_targets` mit eigenen Assertions und Laufnachweisen.

`supplementary_verification` verknüpft die aktuellen Build- und Ausführungsartefakte sowie
die ergänzenden Ergebnisse von StreamAdapterTests, ParallelEngineTests und DelphiExampleTests
für beide Compiler. Diese zusätzlichen Suiten verändern die Originalmethodenzahl nicht.

Der zusätzliche Referenzvergleich unter `reference_comparison` verwendet zehn identische
lokale Eingaben mit Java und beiden Delphi-Compilern. Die beiden Ergebnisartefakte weisen
jeweils 10/10 Vergleiche und 17/17 Gegenproben aus. Die Validierungsprozesse liefern jeweils
Exitcode 7 für die sieben gezielt abgelehnten oder technisch fehlerhaften Eingaben. Diese
Prozesscodes sind von den erfolgreichen Vergleichsergebnissen zu unterscheiden. Dieser
Vergleich ist ein zusätzlicher Nachweis und kein erneuter Lauf aller 201 Originalmethoden.

Es gibt keine pauschale Übertragung aller Java-Builder- oder Providerklassen. Fachliche
Pflichtfelder, Ressourcenfehler, Versionen, Namespacefehler und die Auswahl des ersten
Fallbackberichts bleiben eingeschlossen, soweit sie beim Laden oder Validieren öffentlich
beobachtbar sind. Java-Objektidentität, JAXB-Zieltypen, JAR-/Classpath-Zugriffe, spezifische
Buildermetadaten, Java-Heap-/Stacktraceausgaben sowie Server-, Daemon- und HTTP-Endpunkte
erhalten explizite Ausschlussbegründungen. Ein lokaler negativer HTTP-URI-Test wird dadurch
nicht ausgeschlossen.
