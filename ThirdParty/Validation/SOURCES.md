# Herkunft der zusätzlichen Prüfregeln

Die Regeln werden beim lokalen Paketieren aus einem ausdrücklich bereitgestellten Verzeichnis übernommen. Ihre Bytes und vorhandenen Hinweise werden nicht verändert. Java-Laufzeiten und Java-Validatoren gehören nicht zum Laufzeitpaket.

| Bestandteil | Herkunft und Lizenzhinweis |
|---|---|
| ZUGFeRD-Konfiguration | [itplr-kosit/validator-configuration-zugferd](https://github.com/itplr-kosit/validator-configuration-zugferd); die mitgelieferte `LICENSE` erhalten |
| ZUGFeRD-/Factur-X-Schemata und Schematron | [FeRD-Nutzungsrechte](https://www.ferd-net.de/ueber-uns/ressourcen-1/veroeffentlichungen/haftungsausschluss-und-nutzungsrechte); Apache 2.0 für technische Prüfartefakte |
| XRechnung 3.0.2 | [Release 2024-06-20](https://github.com/itplr-kosit/validator-configuration-xrechnung/releases/tag/release-2024-06-20); `XRechnung-LICENSE` und `XRechnung-NOTICE` sind unveränderte Dateien dieses Tags |
| EN16931-Schematron | [ConnectingEurope/eInvoicing-EN16931](https://github.com/ConnectingEurope/eInvoicing-EN16931); EUPL 1.2. `EN16931-EUPL.txt` stammt unverändert aus [validation-1.3.12](https://github.com/ConnectingEurope/eInvoicing-EN16931/blob/validation-1.3.12/LICENSE.txt), der von XRechnung 3.0.2 verwendeten Referenz |
| UBL 2.1 | [OASIS UBL 2.1, Notices](https://docs.oasis-open.org/ubl/UBL-2.1.html); OASIS-Hinweise in den XSD-Dateien erhalten |
| UN/CEFACT CII | Lizenz- und Copyright-Texte in den jeweiligen Schemaheadern erhalten; [UNECE XML Naming and Design Rules](https://unece.org/sites/default/files/2023-07/XMLNamingAndDesignRulesV2.1.1.pdf) |

Bei Weitergabe der EN16931-Prüfartefakte bleiben EUPL-Lizenz und Quellcodezugang erhalten. Die weitergegebenen XSLT-/XSD-Dateien liegen im lesbaren Quellformat vor; das offizielle EN16931-Repository bietet zusätzlich die zugehörigen Schematron-Quellen. Vorhandene Versions- und Herkunftskommentare dürfen nicht entfernt werden.

Für ZUGFeRD beruht die Anwendung auf der veröffentlichten Spezifikation; die Wiedergabe des zugrunde liegenden Standards erfolgt mit Erlaubnis von CEN und DIN gemäß den verlinkten FeRD-Nutzungsrechten. Diese Hinweise erteilen keine pauschale Apache-Lizenz für Spezifikations-PDFs, Referenztabellen oder sonstige zusätzliche Unterlagen. Solche Unterlagen werden nicht in das Laufzeitpaket übernommen.
