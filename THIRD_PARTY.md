# Lizenzen und Weitergabe

Der von MGGM erstellte Delphi-Code steht unter [Apache License 2.0](LICENSE). Kostenlose und kommerzielle Nutzung, Änderungen und Weitergabe sind nach deren Bedingungen möglich. Fremdkomponenten werden dadurch nicht umlizenziert. Die folgende Prüfung bezieht sich auf den vorhandenen Quellstand und SaxonC-HE 12.10.1.

## KoSIT

Der [Originalvalidator](https://github.com/itplr-kosit/validator) steht unter Apache 2.0. Die fünf eingebetteten Framework-Ressourcen sind unverändert übernommen; ihre Originaldateien liegen zusätzlich unter `Source`. [ThirdParty/KoSIT/LICENSE](ThirdParty/KoSIT/LICENSE) und [NOTICE](ThirdParty/KoSIT/NOTICE) bleiben erhalten. Die ursprüngliche NOTICE gehört zum übernommenen Projekt und kann zusätzliche Komponenten der ursprünglichen Java-Distribution nennen.

Bei Weitergabe sind Lizenz- und Urheberrechtshinweise zu erhalten. Änderungen an weitergegebenen abgeleiteten Dateien müssen als solche erkennbar sein. Der Projekt-[NOTICE](NOTICE) beschreibt die Delphi-Implementierung und die unverändert übernommenen Ressourcen. Maßgeblich sind die [Apache-Bedingungen](https://www.apache.org/licenses/LICENSE-2.0.html), insbesondere Abschnitte 3 und 4.

## SaxonC-HE

Verwendet wird **The Saxon XSLT and XQuery Processor from Saxonica Limited**, [SaxonC-HE](https://www.saxonica.com/html/saxon-c/index.html). Die primäre Lizenz ist [MPL 2.0](https://www.mozilla.org/en-US/MPL/2.0/). Die ursprünglichen SDK-Hinweise stehen unter [ThirdParty/SaxonC](ThirdParty/SaxonC). Die DLL wird unverändert verwendet. Das eigenständige Delphi-Modul darf seine Apache-Lizenz behalten; die MPL-Bedingungen für Saxon gelten zusätzlich.

MPL 2.0, Abschnitt 3.2, verlangt bei Binärweitergabe die Verfügbarkeit des zugehörigen Quellcodes und einen Bezugshinweis. Die [Herkunftsdokumentation](ThirdParty/SaxonC/SOURCE.md) verlinkt die verfügbaren Quellen. **Offen bleibt vor einer externen Binärweitergabe die genaue Quellcodezuordnung von SaxonC-HE 12.10.1 und der darin enthaltenen nativen Laufzeitbestandteile.** Das öffentlich gelistete C-Quellarchiv trägt Version 12.9.0; es wird nicht als identischer Quellstand der aktuellen DLL ausgegeben. Ein reiner Quellcodeexport dieses Delphi-Projekts enthält die DLL nicht.

## Prüfregeln

Die drei verwendeten Konfigurationen und ihre technischen Abhängigkeiten bleiben unverändert. Das Laufzeitpaket enthält die Regeln unter `Validation` und die zusätzlichen Lizenzhinweise unter `Notices/Validation`. Die Herkunft ist in [ThirdParty/Validation/SOURCES.md](ThirdParty/Validation/SOURCES.md) dokumentiert.

Die Zusammenstellung [validator-configuration-zugferd](https://github.com/LandrixSoftware/validator-configuration-zugferd) wurde von MGGM Software GmbH mitentwickelt und wird im Repository von Landrix Software gepflegt. Sie ergänzt die XRechnung-Konfiguration um die Prüfung der XML-Daten von ZUGFeRD-/Factur-X-E-Rechnungen. Dieselben Regeln können auch mit dem Original-KoSIT-Validator verwendet werden. Der gemeinsame Autorenhinweis steht in den Szenariodateien; die Herkunft der zugrunde liegenden Standardartefakte und deren Lizenzbedingungen bleiben davon unberührt.

- ZUGFeRD-/Factur-X-Konfiguration und technische Schema-/Schematron-Artefakte: Apache 2.0 gemäß [FeRD-Nutzungsrechten](https://www.ferd-net.de/ueber-uns/ressourcen-1/veroeffentlichungen/haftungsausschluss-und-nutzungsrechte). Die Spezifikation und zusätzliche Veröffentlichungsunterlagen haben eigene Bedingungen. Das Paket übernimmt keine Spezifikations-PDFs oder Referenztabellen.
- XRechnung-3.0.2-Konfiguration: ursprüngliche Apache-Lizenz einschließlich der Standardhinweise sowie KoSIT-NOTICE aus [release-2024-06-20](https://github.com/itplr-kosit/validator-configuration-xrechnung/releases/tag/release-2024-06-20) mitführen.
- EN16931-Prüfartefakte: EUPL 1.2, einschließlich Lizenzkopie und Zugang zu den zugehörigen [Schematron-Quellen](https://github.com/ConnectingEurope/eInvoicing-EN16931). Die lesbaren generierten Regeln und ihre Herkunftskommentare bleiben erhalten.
- OASIS UBL und UN/CEFACT CII: ursprüngliche Copyright- und Lizenztexte in den Schemata erhalten. Sie werden nicht pauschal als Apache- oder MIT-Dateien bezeichnet.

Für ZUGFeRD beruht die Anwendung auf der veröffentlichten Spezifikation; die Wiedergabe des zugrunde liegenden Standards erfolgt mit Erlaubnis von CEN und DIN gemäß den verlinkten FeRD-Nutzungsrechten. Das ist keine Übertragung von Markenrechten oder eine Zertifizierung dieses Validators.

## Betriebssystem und Compiler

MSXML und die benötigte Visual-C++-Laufzeit sind Voraussetzungen der Windows-Installation. Sie werden nicht aus dem Entwicklungsrechner in das Paket kopiert. Delphi ist ein Entwicklungswerkzeug und wird nicht mitgeliefert.
