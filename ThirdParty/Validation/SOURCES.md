# Herkunft der zusätzlichen Prüfregeln

Die Regeln werden beim lokalen Paketieren aus einem ausdrücklich bereitgestellten Verzeichnis übernommen. Ihre Bytes und vorhandenen Hinweise werden nicht verändert. Java-Laufzeiten und Java-Validatoren gehören nicht zum Laufzeitpaket.

| Bestandteil | Herkunft und Lizenzhinweis |
|---|---|
| ZUGFeRD-/Factur-X-Konfiguration | [LandrixSoftware/validator-configuration-zugferd](https://github.com/LandrixSoftware/validator-configuration-zugferd), von MGGM mitentwickelt; die mitgelieferte `LICENSE` erhalten |
| ZUGFeRD-/Factur-X-Schemata und Schematron | [FeRD-Nutzungsrechte](https://www.ferd-net.de/ueber-uns/ressourcen-1/veroeffentlichungen/haftungsausschluss-und-nutzungsrechte); Apache 2.0 für technische Prüfartefakte |
| XRechnung 3.0.2 | [Release 2024-06-20](https://github.com/itplr-kosit/validator-configuration-xrechnung/releases/tag/release-2024-06-20); `XRechnung-LICENSE` und `XRechnung-NOTICE` sind unveränderte Dateien dieses Tags |
| EN16931-Schematron | [ConnectingEurope/eInvoicing-EN16931](https://github.com/ConnectingEurope/eInvoicing-EN16931); EUPL 1.2. `EN16931-EUPL.txt` stammt unverändert aus [validation-1.3.12](https://github.com/ConnectingEurope/eInvoicing-EN16931/blob/validation-1.3.12/LICENSE.txt), der von XRechnung 3.0.2 verwendeten Referenz |
| UBL 2.1 | [OASIS UBL 2.1, Notices](https://docs.oasis-open.org/ubl/UBL-2.1.html); OASIS-Hinweise in den XSD-Dateien erhalten |
| UN/CEFACT CII | Lizenz- und Copyright-Texte in den jeweiligen Schemaheadern erhalten; [UNECE XML Naming and Design Rules](https://unece.org/sites/default/files/2023-07/XMLNamingAndDesignRulesV2.1.1.pdf) |

## Gemeinsam entwickelte ZUGFeRD-/Factur-X-Konfiguration

Die Zusammenstellung wird im Landrix-Repository gepflegt. Die Autorenangaben in [scenarios.xml](https://github.com/LandrixSoftware/validator-configuration-zugferd/blob/8399f5459df34b2af9cae0d613870649b3f17a58/scenarios.xml#L5-L7) und [scenarios_zugferd1.xml](https://github.com/LandrixSoftware/validator-configuration-zugferd/blob/8399f5459df34b2af9cae0d613870649b3f17a58/scenarios_zugferd1.xml#L5) nennen ausdrücklich **MGGM Software GmbH und Landrix Software**. Die Verweise sind auf den geprüften Quellstand `8399f5459df34b2af9cae0d613870649b3f17a58` festgelegt.

Diese Konfiguration ermöglicht neben XRechnung die Prüfung von ZUGFeRD-/Factur-X-XML mit den darin hinterlegten Profilen und Versionen. Sie ist sowohl mit dem MGGM XML Validator für Delphi als auch mit dem Original-KoSIT-Validator unter Java nutzbar. Die zusätzliche Formatunterstützung kommt aus den Prüfregeln; die KoSIT-Engine selbst ist nicht auf XRechnung beschränkt.

## Hinweise zur Weitergabe

Bei Weitergabe der EN16931-Prüfartefakte bleiben EUPL-Lizenz und Quellcodezugang erhalten. Die weitergegebenen XSLT-/XSD-Dateien liegen im lesbaren Quellformat vor; das offizielle EN16931-Repository bietet zusätzlich die zugehörigen Schematron-Quellen. Vorhandene Versions- und Herkunftskommentare dürfen nicht entfernt werden.

Für ZUGFeRD beruht die Anwendung auf der veröffentlichten Spezifikation; die Wiedergabe des zugrunde liegenden Standards erfolgt mit Erlaubnis von CEN und DIN gemäß den verlinkten FeRD-Nutzungsrechten. Diese Hinweise erteilen keine pauschale Apache-Lizenz für Spezifikations-PDFs, Referenztabellen oder sonstige zusätzliche Unterlagen. Solche Unterlagen werden nicht in das Laufzeitpaket übernommen.
