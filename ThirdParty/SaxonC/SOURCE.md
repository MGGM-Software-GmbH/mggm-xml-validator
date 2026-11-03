# SaxonC-HE: Herkunft und Quellcode

Verwendet wird die unveränderte Windows-x86_64-DLL aus SaxonC-HE 12.10.1:

- [Offizielles Binärpaket](https://downloads.saxonica.com/SaxonC/HE/12/SaxonCHE-windows-x86_64-12-10-1.zip).
- ZIP-SHA-256: `319d23516d2290491149ad71831c3b54ac3b61dba137e03ed88df60f03ce48d2`.
- DLL-SHA-256: `2a15c4631efa5b45a86b63b0618da32acf5552abf653c36b54f1b2932df94a6c`.

Die drei Dateien `LICENSE.txt`, `JAMESCLARK.txt` und `JLINE2.txt` sind unverändert aus diesem Paket übernommen. Die primäre Lizenz ist MPL 2.0. Die besonderen Hinweise bleiben zusätzlich erhalten.

Der direkte Bezug durch den Benutzer ist mit [download-saxon.cmd](../../download-saxon.cmd) möglich. Standardziel ist `build` neben den Skripten; ein anderes Anwendungsverzeichnis kann ausdrücklich angegeben werden. Das Skript lädt das oben verlinkte Original-ZIP, prüft dessen SHA-256 und den DLL-SHA-256 und übernimmt ausschließlich die DLL sowie `notices/LICENSE.txt`, `notices/JAMESCLARK.txt` und `notices/JLINE2.txt`. Die Hinweise liegen anschließend unter `Notices/SaxonC/SDK` im gewählten Ziel. Die zugehörige PowerShell-Datei gehört zum Downloader und muss neben der CMD-Datei bleiben. Das Quellrepository enthält weiterhin keine DLL.

SaxonC 12.10.1 basiert laut [Saxonica](https://www.saxonica.com/html/saxon-c/index.html) auf SaxonJ 12.10 und GraalVM Community Edition für JDK 21. Die [SaxonJ-12.10-Quellen](https://github.com/Saxonica/Saxon-HE/blob/main/12/source/saxon12-10source.zip) sind öffentlich verfügbar. Saxonica verweist für SaxonC-Quellen auf das [Saxon-HE-Repository](https://github.com/Saxonica/Saxon-HE). Bei der Prüfung am 01.11.2026 enthält dessen Verzeichnis `12/source` als eigenes C-Quellarchiv `SaxonCHE-source-12-9-0.zip`; ein eigenes C-Quellarchiv für 12.10.1 wurde dort nicht gefunden.

MPL 2.0, Abschnitt 3.2, verlangt bei Binärweitergabe die Verfügbarkeit des zugehörigen Quellcodes und einen Hinweis auf dessen Bezug. Vor einer externen Weitergabe des DLL-Pakets muss deshalb die genaue Quellcodezuordnung für SaxonC-HE 12.10.1 einschließlich der enthaltenen Laufzeitbestandteile geklärt und hier dokumentiert werden. Der vorhandene Verweis auf SaxonJ 12.10 und das ältere C-Archiv ist kein Nachweis identischer Quellen der ausgelieferten DLL. Das lokale Paket dient bis dahin Entwicklung und interner Prüfung.
