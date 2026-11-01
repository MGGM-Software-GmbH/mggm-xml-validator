# Referenzfälle

`xr-ubl-valid.xml` und `xr-cii-valid.xml` sind unveränderte Originalbytes der offiziellen
[KoSIT-XRechnung-Testsuite](https://github.com/itplr-kosit/xrechnung-testsuite/tree/04cb0e80c14aaa4fb40c1118846570756dc534cd).
Es gilt die unverändert übernommene `XRechnung-Testsuite-LICENSE` (Apache 2.0).

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
