# Referenzfälle

`xr-ubl-valid.xml` und `xr-cii-valid.xml` stammen aus der offiziellen
[KoSIT-XRechnung-Testsuite](https://github.com/itplr-kosit/xrechnung-testsuite/tree/04cb0e80c14aaa4fb40c1118846570756dc534cd).
Gegenüber den Git-Originalen wurden ausschließlich die Zeilenenden von LF auf CRLF normalisiert.
Geschäftsinhalt und XML-Kopf sind unverändert. Die lokalen Fixturebytes bleiben als Regressionseingaben erhalten.
Es gilt die unverändert übernommene `XRechnung-Testsuite-LICENSE` (Apache 2.0).

| Fixture | SHA-256 des Git-Originals (LF) | SHA-256 der lokalen Datei (CRLF) |
| --- | --- | --- |
| `xr-ubl-valid.xml` | `74fb09c609d5fba15a8c543060998d3b92858f56a81fb5b0ed244d6794e498d1` | `0efafa05c74d06ff25bbc2b70bcb2e9f14b97d22a4b33c5e92838bf2cc8986cb` |
| `xr-cii-valid.xml` | `727b51982a84c9b406599a7384783570910440ed405c9bb6d918b22442636886` | `e58a673aa659973ba190c25fd583050af3239a58b3ab04b1c2b2583920d203e6` |

`source.original_sha256` bezeichnet auch bei den vier Ableitungen den Git-Quellhash.
`sha256` bezeichnet stets die tatsächlich verwendeten lokalen Bytes. `derived: false` kennzeichnet
die beiden fachlich unveränderten Quellbeispiele; `line_ending_normalization: lf-to-crlf`
dokumentiert ihre Byteänderung und die Ausgangsbasis der fachlichen Ableitungen ausdrücklich.

Die vier abgeleiteten Rechnungen tragen einen Änderungshinweis im XML. Die ZUGFeRD-/Factur-X-Fälle
übernehmen das CII-Beispiel und setzen seine Guideline-ID auf `urn:cen.eu:en16931:2017`.
Damit prüfen sie gezielt das EN16931-/Comfort-Szenario des angegebenen Regelpakets.
Sie sind abgeleitete Testdaten und keine weiteren offiziellen FeRD-Beispiele.
Der angenommene Profilfall enthält eine Warnung; Annahme und Berichtgültigkeit werden getrennt geprüft.

Die vier Parser-/Szenariofälle sind synthetisch. Der größere DTD-Fall prüft den Hash der gesamten Eingabe,
obwohl der Parser bereits an der DTD abbricht. Keiner der Fälle stammt aus privaten Rechnungen.
`fixture-manifest.json` hält Quellen, Lizenzen, Änderungen, Profile, Hashes und Erwartungen fest.
`rule-hashes.json` legt die 219 Dateien des tatsächlich verwendeten lokalen Regelpakets fest.
Die Regeldateien selbst sind kein Bestandteil dieses Testverzeichnisses.

Bei einer fachlich beabsichtigten Änderung zuerst Quelle und Regelversion prüfen, danach Fixture,
Änderungshinweis und Manifest gemeinsam aktualisieren. Einen abweichenden Hash nicht ungeprüft übernehmen.
Der dokumentierte Referenzlauf unter [TESTING.md](../../../docs/TESTING.md) prüft die Bytes vor jedem Start.
Er rekonstruiert bei beiden Quellbeispielen die LF-Bytes und prüft ihren Originalhash ohne Netzwerkzugriff.
Die vier Ableitungen müssen auf eine so geprüfte Quelle im selben Bestand verweisen.
