"""Gültige Berichtspaare und isolierte Gegenproben für den Referenzvergleich."""

from contextlib import redirect_stdout
from copy import deepcopy
import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compare_reports as comparison

NS = comparison.NS


class ReportComparisonTests(unittest.TestCase):
    """Jede Manipulation erhält zunächst einen nachgewiesenen gültigen Ausgangsfall."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.data = b"<Invoice><ID>123</ID></Invoice>"
        self.source = self.directory / "Rechnung.xml"
        self.source.write_bytes(self.data)
        self.case = {"name": "invoice", "file": str(self.source), "sha256": hashlib.sha256(self.data).hexdigest(),
                     "expected": {"status": "W", "accepted": True, "schema_valid": True, "processing_error": False}}
        digest = base64.b64encode(hashlib.sha256(self.data).digest()).decode()
        scenario = f'''<s:scenario xmlns:s="{NS['s']}"><s:name>Testrechnung</s:name><s:match>true()</s:match>
          <s:validateWithXmlSchema><s:resource><s:name>Testschema</s:name><s:location>invoice.xsd</s:location></s:resource></s:validateWithXmlSchema>
          <s:validateWithSchematron><s:resource><s:name>Testregeln</s:name><s:location>invoice.xsl</s:location></s:resource></s:validateWithSchematron></s:scenario>'''
        html = f'''<html xmlns="{NS['h']}"><head><title>Prüfbericht</title></head><body><h1>Prüfbericht</h1>
          <dl><dt>Referenz:</dt><dd>Rechnung.xml</dd><dt>Zeitpunkt der Prüfung:</dt><dd>01.11.2026 12:00:00</dd></dl>
          <table><tr><td>BR-01</td><td>Hinweis für ID 123</td></tr></table>
          <p>Dieser Prüfbericht wurde erstellt mit Testengine.</p></body></html>'''
        report = f'''<r:report xmlns:r="{NS['r']}" valid="true" varlVersion="1.0.0">
          <r:engine><r:name>Testengine</r:name></r:engine><r:timestamp>2026-11-01T12:00:00Z</r:timestamp>
          <r:documentIdentification><r:documentHash><r:hashAlgorithm>SHA-256</r:hashAlgorithm><r:hashValue>{digest}</r:hashValue></r:documentHash>
          <r:documentReference>Rechnung.xml</r:documentReference></r:documentIdentification>
          <r:scenarioMatched>{scenario}<r:documentData><id>123</id></r:documentData>
          <r:validationStepResult id="val-xsd" valid="true"/><r:validationStepResult id="val-sch.1" valid="true">
          <r:message id="val-sch.1.1" code="BR-01" level="warning" xpathLocation="/Invoice/ID">Hinweis für ID 123</r:message>
          </r:validationStepResult><r:validationStepResult id="val-xml" valid="true"/></r:scenarioMatched>
          <r:assessment><r:accept><r:explanation>{html}</r:explanation></r:accept></r:assessment></r:report>'''
        report_input = f'''<i:createReportInput xmlns:i="{NS['i']}" frameworkVersion="1.0.2">
          <i:engine><i:name>Testengine</i:name></i:engine><i:timestamp>2026-11-01T12:00:00Z</i:timestamp>
          <i:documentIdentification><i:documentHash><i:hashAlgorithm>SHA-256</i:hashAlgorithm><i:hashValue>{digest}</i:hashValue></i:documentHash>
          <i:documentReference>Rechnung.xml</i:documentReference></i:documentIdentification>{scenario}
          <i:validationResultsWellformedness/><i:validationResultsXmlSchema><s:resource xmlns:s="{NS['s']}"><s:name>Testschema</s:name><s:location>invoice.xsd</s:location></s:resource></i:validationResultsXmlSchema>
          <i:validationResultsSchematron><s:resource xmlns:s="{NS['s']}"><s:name>Testregeln</s:name><s:location>invoice.xsl</s:location></s:resource>
          <i:results><svrl:schematron-output xmlns:svrl="http://purl.oclc.org/dsdl/svrl"/></i:results></i:validationResultsSchematron></i:createReportInput>'''
        self.java = {"report": ET.fromstring(report), "report_input": ET.fromstring(report_input), "html": ET.fromstring(html), "public": {}}
        self.native = deepcopy(self.java)
        self.native["public"] = {"input": str(self.source), "status": "W", "acceptance": "ACCEPTABLE", "schema_valid": True, "processing_error": False}
        self.assertEqual(self.compare(), [])

    def compare(self, candidate=None):
        return comparison.compare_pair(self.java, self.native if candidate is None else candidate, self.case, self.data)

    def mutate(self, operation, expected=None):
        self.assertEqual(self.compare(), [])
        changed = deepcopy(self.native)
        operation(changed)
        differences = self.compare(changed)
        self.assertTrue(differences)
        if expected:
            self.assertTrue(any(expected in field for field in differences), differences)

    def write_run(self):
        for name, bundle in (("java", self.java), ("native", self.native)):
            directory = self.directory / name
            directory.mkdir(exist_ok=True)
            for key, suffix in (("report", "-report.xml"), ("report_input", "-reportInput.xml"), ("html", "-report.html")):
                ET.ElementTree(bundle[key]).write(directory / (self.case["name"] + suffix), encoding="utf-8", xml_declaration=True)
        (self.directory / "native" / "results.json").write_text(json.dumps([self.native["public"]]), encoding="utf-8")
        (self.directory / "manifest.json").write_text(json.dumps({"cases": [self.case]}), encoding="utf-8")

    def verify(self):
        with redirect_stdout(io.StringIO()):
            return comparison.verify(self.directory)

    def test_valid_run_executes_every_countercheck(self):
        self.write_run()
        self.assertEqual(self.verify(), 0)
        evidence = json.loads((self.directory / "comparison.json").read_text())
        self.assertEqual(json.loads((self.directory / "native/comparison.json").read_text()), evidence)
        self.assertEqual(evidence["total"], 1)
        self.assertEqual(len(evidence["counterchecks"]), 17)
        self.assertTrue(all(evidence["counterchecks"].values()))

    def test_finding_fields(self):
        for attribute, value, field in (("code", "BR-OTHER", "code"), ("level", "error", "level"), ("xpathLocation", "/Invoice/Other", "location")):
            with self.subTest(attribute=attribute):
                self.mutate(lambda bundle: bundle["report"].find(".//r:message", NS).set(attribute, value), "findings." + field)
        self.mutate(lambda bundle: setattr(bundle["report"].find(".//r:message", NS), "text", "Anderer Hinweis"), "findings.text")

    def test_multiset_preserves_duplicates_and_locations(self):
        step = self.native["report"].find(".//r:validationStepResult[@id='val-sch.1']", NS)
        for bundle in (self.java, self.native):
            target = bundle["report"].find(".//r:validationStepResult[@id='val-sch.1']", NS)
            item = deepcopy(target[0])
            item.set("id", "val-sch.1.2")
            target.append(item)
        self.assertEqual(self.compare(), [])
        self.mutate(lambda bundle: bundle["report"].find(".//r:validationStepResult[@id='val-sch.1']", NS).remove(bundle["report"].find(".//r:message", NS)), "findings.multiset")
        self.mutate(lambda bundle: bundle["report"].find(".//r:message", NS).set("xpathLocation", "/Invoice/ID[2]"), "findings.location")

    def test_acceptance_status_validity_are_independent(self):
        self.mutate(lambda bundle: setattr(bundle["report"].find("r:assessment/r:accept", NS), "tag", f"{{{NS['r']}}}reject"), "accepted")
        self.mutate(lambda bundle: bundle["public"].update(status="E"), "public_status")
        self.mutate(lambda bundle: bundle["report"].set("valid", "false"), "valid")

    def test_phase_and_structure(self):
        self.mutate(lambda bundle: bundle["report"].find(".//r:validationStepResult", NS).set("id", "val-other"), "phase")
        self.mutate(lambda bundle: bundle["report"].remove(bundle["report"].find("r:assessment", NS)), "report_structure")
        self.mutate(lambda bundle: bundle["report"].find("r:scenarioMatched", NS).remove(bundle["report"].find(".//r:validationStepResult[@id='val-sch.1']", NS)), "phase")
        for bundle in (self.java, self.native):
            bundle["report"].remove(bundle["report"].find("r:documentIdentification", NS))
        self.assertTrue(self.compare())

    def test_original_hashes_and_reference(self):
        for key, namespace in (("report", "r"), ("report_input", "i")):
            path = f"{namespace}:documentIdentification/{namespace}:documentHash/{namespace}:hashValue"
            self.mutate(lambda bundle: setattr(bundle[key].find(path, NS), "text", base64.b64encode(bytes(32)).decode()), "input_hash")
        self.mutate(lambda bundle: setattr(bundle["report"].find("r:documentIdentification/r:documentReference", NS), "text", "Andere.xml"), "input_reference")

    def test_schema_and_meaningful_content(self):
        self.mutate(lambda bundle: bundle["report_input"].set("invalid", "true"), "report_input_schema")
        self.mutate(lambda bundle: bundle["html"].find("h:body", NS).clear(), "h:body")
        self.mutate(lambda bundle: setattr(bundle["html"].find(".//h:td", NS), "text", "BR-OTHER"), "html")
        self.mutate(lambda bundle: setattr(bundle["report"].find("r:scenarioMatched/r:documentData/id", NS), "text", "456"), "document_data")
        self.mutate(lambda bundle: bundle["report_input"].remove(bundle["report_input"].find("i:validationResultsSchematron", NS)), "report_input.phase")

    def test_allowed_metadata_and_prefixes(self):
        self.native["report"].find("r:timestamp", NS).text = "2030-01-01T00:00:00Z"
        self.native["report_input"].find("i:timestamp", NS).text = "2030-01-01T00:00:00Z"
        self.native["report"].find("r:engine/r:name", NS).text = "Andere Engine"
        self.native["report"].find("r:documentIdentification/r:documentReference", NS).text = "file:///D:/Pr%C3%BCfung/Rechnung.xml"
        self.native["html"].find("h:body/h:dl/h:dd", NS).text = "D:/Prüfung/Rechnung.xml"
        embedded = self.native["report"].find(".//h:html", NS)
        embedded.find("h:body/h:dl/h:dd", NS).text = "D:/Prüfung/Rechnung.xml"
        self.assertEqual(self.compare(), [])

    def test_empty_missing_and_unexecuted_counterchecks_fail(self):
        self.write_run()
        self.assertEqual(self.verify(), 0)
        (self.directory / "manifest.json").write_text('{"cases": []}')
        self.assertEqual(self.verify(), 1)
        self.write_run()
        with patch.object(comparison, "counterchecks", return_value={}):
            self.assertEqual(self.verify(), 1)
        self.write_run()
        # Fehlender Referenzbericht wird in einem isolierten temporären Lauf entfernt.
        (self.directory / "java" / "invoice-report.xml").unlink()
        self.assertEqual(self.verify(), 1)

    def test_manifest_and_public_status_are_required(self):
        self.write_run()
        self.assertEqual(self.verify(), 0)
        self.source.write_bytes(self.data + b" ")
        self.assertEqual(self.verify(), 1)
        self.source.write_bytes(self.data)
        self.native["public"].pop("status")
        self.assertIn("native.public_status", self.compare())

    def test_html_parser_rejects_empty_and_broken_documents(self):
        self.assertEqual(comparison.HtmlParser().parse('<html><head><meta charset="utf-8"></head><body>Text</body></html>').tag, f"{{{NS['h']}}}html")
        for invalid in ("", "<html><body>", "<html><body></html>"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                comparison.HtmlParser().parse(invalid)

    def test_real_saxon_html_encoding_serialization(self):
        # Im aktuellen Java- und Delphi-Artefakt steht XHTML charset=utf-8
        # nach title; der HTML-Serializer ersetzt es durch Content-Type davor.
        for bundle in (self.java, self.native):
            embedded_head = bundle["report"].find(".//h:html/h:head", NS)
            ET.SubElement(embedded_head, f"{{{NS['h']}}}meta", {"charset": "utf-8"})
            external_head = bundle["html"].find("h:head", NS)
            external_head.insert(0, ET.Element(f"{{{NS['h']}}}meta", {"http-equiv": "Content-Type", "content": "text/html; charset=UTF-8"}))
        self.assertEqual(self.compare(), [])
        self.mutate(lambda bundle: bundle["html"].find("h:head/h:meta", NS).set("content", "text/html; charset=UTF-16"), "html.report_content")
        self.mutate(lambda bundle: bundle["html"].find("h:head/h:meta", NS).set("name", "unrelated"), "html.report_content")
        self.mutate(lambda bundle: setattr(bundle["html"].find("h:head/h:title", NS), "text", "Anderer Bericht"), "html.report_content")

    def test_finding_whitespace_is_preserved(self):
        for text in (" Hinweis für ID 123", "Hinweis für ID 123 ", "Hinweis  für ID 123", "Hinweis\nfür ID 123"):
            with self.subTest(text=text):
                self.mutate(lambda bundle: setattr(bundle["report"].find(".//r:message", NS), "text", text), "findings.text")

    def test_svrl_source_uri_requires_explicit_same_input_alias(self):
        svrl = "http://purl.oclc.org/dsdl/svrl"
        windows_file = "D:/Referenzlauf/Eingaben/Rechnung.xml"
        self.case["input_aliases"] = [windows_file]
        for bundle, uri in ((self.java, self.source.as_uri()), (self.native, "file:///" + windows_file)):
            output = bundle["report_input"].find(".//{" + svrl + "}schematron-output")
            ET.SubElement(output, "{" + svrl + "}active-pattern", {"documents": uri})
        self.assertEqual(self.compare(), [])
        self.mutate(lambda bundle: bundle["report_input"].find(".//{" + svrl + "}active-pattern").set("documents", "file:///D:/FremderKontext/Rechnung.xml"), "input_reference.svrl_documents")
        self.case.pop("input_aliases")
        self.assertIn("native.input_reference.svrl_documents", self.compare())

    def test_schema_diagnostic_exception_requires_semantics(self):
        java = 'Ungültiger Content wurde beginnend mit Element \'{"urn:test":IssueDate}\' gefunden. \'{"urn:test":ID}\' wird erwartet.'
        native = "MSXML 0xC00CE014: Der Inhalt des Elements '{urn:test}IssueDate' ist nicht gültig. Erwartet: {urn:test}ID. [Datei: ; Zeile: 0; Position: 0]"
        kind = "schema-unexpected-element"
        valid = comparison.diagnostic(java, "val-xsd", "cvc-complex-type.2.4.a", self.data, kind)
        self.assertIsNotNone(valid)
        self.assertEqual(valid, comparison.diagnostic(native, "val-xsd", "generic-error", self.data, kind))
        english = 'Invalid content was found starting with element \'{"urn:test":IssueDate}\'. One of \'{"urn:test":ID}\' is expected.'
        self.assertEqual(valid, comparison.diagnostic(english, "val-xsd", "cvc-complex-type.2.4.a", self.data, kind))
        self.assertNotEqual(valid, comparison.diagnostic(native.replace("}ID.", "}Other."), "val-xsd", "generic-error", self.data, kind))
        self.assertIsNone(comparison.diagnostic(native.replace("Erwartet:", "Text:"), "val-xsd", "generic-error", self.data, kind))
        self.assertIsNone(comparison.diagnostic(native, "val-xsd", "changed-code", self.data, kind))
        self.assertIsNone(comparison.diagnostic(native, "val-xml", "generic-error", self.data, kind))
        self.assertIsNone(comparison.diagnostic(native, "val-xsd", "generic-error", self.data, None))

    def test_parser_diagnostic_exceptions_require_actual_input(self):
        for data, kind, java, native in (
            (b"<Invoice>", "xml-unclosed-document", "SXXP0003 XML-Dokumentstrukturen müssen innerhalb derselben Entity beginnen und enden.", "MSXML 0xC00CE553: Die folgenden Tags wurden nicht geschlossen: Invoice."),
            (b'<!DOCTYPE Invoice><Invoice/>', "xml-doctype-forbidden", 'SXXP0003 DOCTYPE ist nicht zulässig disallow-doctype-decl', 'MSXML 0xC00CE584: DTD ist nicht zulässig.')):
            with self.subTest(kind=kind):
                valid = comparison.diagnostic(java, "val-xml", "generic-error", data, kind)
                self.assertIsNotNone(valid)
                self.assertEqual(valid, comparison.diagnostic(native, "val-xml", "generic-error", data, kind))
                self.assertIsNone(comparison.diagnostic(native, "val-xml", "generic-error", self.data, kind))
                self.assertIsNone(comparison.diagnostic("Andere Ursache", "val-xml", "generic-error", data, kind))
                english = ("SXXP0003 XML document structures must start and end within the same entity."
                           if kind == "xml-unclosed-document" else "SXXP0003 DOCTYPE is disallowed disallow-doctype-decl")
                self.assertEqual(valid, comparison.diagnostic(english, "val-xml", "generic-error", data, kind))

    def parser_pair(self, kind):
        """Zwei echte Providerformate mit identischer fachlicher Parserursache aufbauen."""
        if kind == "xml-unclosed-document":
            self.data = b"<Invoice>"
            texts = ("SXXP0003 XML-Dokumentstrukturen müssen innerhalb derselben Entity beginnen und enden.",
                     "MSXML 0xC00CE553: Die folgenden Tags wurden nicht geschlossen: Invoice.")
        else:
            self.data = b'<!DOCTYPE Invoice [<!ENTITY value "123">]><Invoice>&value;</Invoice>'
            texts = ("SXXP0003 DOCTYPE ist nicht zulässig disallow-doctype-decl",
                     "MSXML 0xC00CE584: DTD ist nicht zulässig.")
        self.case["diagnostic_exception"] = kind
        self.case["expected"] = {"status": "F", "accepted": False, "schema_valid": False, "processing_error": True, "report_valid": False}
        digest = base64.b64encode(hashlib.sha256(self.data).digest()).decode()
        for bundle, text in zip((self.java, self.native), texts):
            report = bundle["report"]
            report.set("valid", "false")
            branch = report.find("r:scenarioMatched", NS)
            branch.clear()
            branch.tag = f"{{{NS['r']}}}noScenarioMatched"
            step = ET.SubElement(branch, f"{{{NS['r']}}}validationStepResult", {"id": "val-xml", "valid": "false"})
            ET.SubElement(step, f"{{{NS['r']}}}message", {"id": "val-xml.1", "code": "generic-error", "level": "error"}).text = text
            report.find("r:assessment/r:accept", NS).tag = f"{{{NS['r']}}}reject"
            report.find("r:documentIdentification/r:documentHash/r:hashValue", NS).text = digest
            report_input = bundle["report_input"]
            report_input.find("i:documentIdentification/i:documentHash/i:hashValue", NS).text = digest
            for child in list(report_input):
                if child.tag in (f"{{{NS['s']}}}scenario", f"{{{NS['i']}}}validationResultsXmlSchema", f"{{{NS['i']}}}validationResultsSchematron"):
                    report_input.remove(child)
            syntax = ET.SubElement(report_input.find("i:validationResultsWellformedness", NS), f"{{{NS['i']}}}xmlSyntaxError")
            ET.SubElement(syntax, f"{{{NS['i']}}}message").text = text
            ET.SubElement(syntax, f"{{{NS['i']}}}severityCode").text = "SEVERITY_FATAL_ERROR"
            for html in (bundle["html"], report.find(".//h:html", NS)):
                html.find(".//h:td", NS).text = text
        self.native["public"].update(status="F", acceptance="REJECT", schema_valid=False, processing_error=True)
        self.assertEqual(self.compare(), [])

    def test_parser_exception_in_full_comparison(self):
        self.parser_pair("xml-unclosed-document")
        self.mutate(lambda bundle: setattr(bundle["report"].find(".//r:message", NS), "text", "Andere Ursache"), "semantic_features")
        self.mutate(lambda bundle: bundle["report"].find(".//r:message", NS).set("level", "warning"), "findings.level")
        self.mutate(lambda bundle: bundle["report"].find(".//r:message", NS).set("xpathLocation", "/Other"), "findings.location")

    def test_dtd_reference_prefix_is_independently_verified(self):
        self.parser_pair("xml-doctype-forbidden")
        self.case["java_hash_exception"] = "doctype-read-prefix"
        prefix_hash = base64.b64encode(hashlib.sha256(self.data[:24]).digest()).decode()
        for key, namespace in (("report", "r"), ("report_input", "i")):
            self.java[key].find(f"{namespace}:documentIdentification/{namespace}:documentHash/{namespace}:hashValue", NS).text = prefix_hash
        self.assertEqual(self.compare(), [])
        self.mutate(lambda bundle: setattr(bundle["report"].find("r:documentIdentification/r:documentHash/r:hashValue", NS), "text", prefix_hash), "input_hash")
        original = deepcopy(self.java)
        self.java["report"].find("r:documentIdentification/r:documentHash/r:hashValue", NS).text = base64.b64encode(bytes(32)).decode()
        self.assertTrue(self.compare())
        self.java = original
        self.case.pop("java_hash_exception")
        self.assertTrue(self.compare())

    def test_unknown_exceptions_and_expected_contracts_fail(self):
        for value in ("schema-errors", "all-parser-errors"):
            self.case["diagnostic_exception"] = value
            self.assertTrue(self.compare())
        self.case.pop("diagnostic_exception")
        self.case["expected"]["required_findings"] = [{"code": "MISSING", "level": "error"}]
        self.assertTrue(self.compare())
        self.case["expected"]["required_findings"] = [{"code": "BR-01", "level": "warning"}]
        self.assertEqual(self.compare(), [])
        self.case["expected"]["report_valid"] = False
        self.assertTrue(self.compare())

    def test_schema_exception_in_full_comparison(self):
        java = 'Ungültiger Content wurde beginnend mit Element \'{"urn:test":UnexpectedID}\' gefunden. \'{"urn:test":ID}\' wird erwartet.'
        native = "MSXML 0xC00CE014: Der Inhalt des Elements '{urn:test}UnexpectedID' ist nicht gültig. Erwartet: {urn:test}ID. [Datei: ; Zeile: 0; Position: 0]"
        self.case["diagnostic_exception"] = "schema-unexpected-element"
        self.case["expected"] = {"status": "E", "accepted": False, "schema_valid": False, "processing_error": False, "report_valid": False}
        for bundle, text, code in ((self.java, java, "cvc-complex-type.2.4.a"), (self.native, native, "generic-error")):
            report = bundle["report"]
            report.set("valid", "false")
            report.find("r:assessment/r:accept", NS).tag = f"{{{NS['r']}}}reject"
            branch = report.find("r:scenarioMatched", NS)
            branch.remove(branch.find("r:validationStepResult[@id='val-sch.1']", NS))
            step = branch.find("r:validationStepResult[@id='val-xsd']", NS)
            step.set("valid", "false")
            attributes = {"id": "val-xsd.1", "level": "error", "code": code}
            if bundle is self.java:
                attributes.update(lineNumber="2", columnNumber="20")
            ET.SubElement(step, f"{{{NS['r']}}}message", attributes).text = text
            report_input = bundle["report_input"]
            report_input.remove(report_input.find("i:validationResultsSchematron", NS))
            syntax = ET.SubElement(report_input.find("i:validationResultsXmlSchema", NS), f"{{{NS['i']}}}xmlSyntaxError")
            ET.SubElement(syntax, f"{{{NS['i']}}}message").text = (code + ": " if bundle is self.java else "") + text
            ET.SubElement(syntax, f"{{{NS['i']}}}severityCode").text = "SEVERITY_ERROR"
            if bundle is self.java:
                ET.SubElement(syntax, f"{{{NS['i']}}}rowNumber").text = "2"
                ET.SubElement(syntax, f"{{{NS['i']}}}columnNumber").text = "20"
            for html in (bundle["html"], report.find(".//h:html", NS)):
                row = html.find(".//h:tr", NS)
                row.clear()
                for value in ("val-xsd.1", code, "error", text):
                    ET.SubElement(row, f"{{{NS['h']}}}td").text = value
                coordinate_row = ET.SubElement(html.find(".//h:table", NS), f"{{{NS['h']}}}tr")
                ET.SubElement(coordinate_row, f"{{{NS['h']}}}td").text = " Zeile: 2 Spalte: 20" if bundle is self.java else ""
        self.native["public"].update(status="E", acceptance="REJECT", schema_valid=False)
        self.assertEqual(self.compare(), [])
        self.mutate(lambda bundle: setattr(bundle["report"].find(".//r:message", NS), "text", native.replace("}ID.", "}Other.")), "findings.text")
        self.mutate(lambda bundle: bundle["report"].find(".//r:message", NS).set("code", "other-code"), "semantic_features")
        def wrong_position(bundle):
            for html in (bundle["html"], bundle["report"].find(".//h:html", NS)):
                html.find(".//h:table", NS)[1][0].text = "Zeile: 99 Spalte: 99"
        self.mutate(wrong_position, "html")


if __name__ == "__main__":
    unittest.main()
