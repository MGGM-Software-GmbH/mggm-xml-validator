"""Gegenproben für fachliche Differenzen und unpassende Benchmark-Artefakte."""

import base64
import hashlib
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compare_benchmark import compare, main, NS


class BenchmarkComparisonTests(unittest.TestCase):
    """Jede Mutation verändert nur einen fachlich eigenständigen Nachweis."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        self.source = self.inputs / "Rechnung.XML"
        self.source.write_bytes(b"<Invoice/>")
        digest = hashlib.sha256(self.source.read_bytes()).digest()
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps({"input_directory": str(self.inputs), "cases": [
            {"name": self.source.name, "sha256": digest.hex(), "size": self.source.stat().st_size}]}), encoding="utf-8")
        self.baseline = self.root / "java"
        self.candidate = self.root / "batch"
        html = '<html><head><title>Prüfung</title></head><body><dl><dt>Referenz:</dt><dd>Rechnung.XML</dd>'
        html += '<dt>Zeitpunkt der Prüfung:</dt><dd>31.10.2026 20:00:00</dd></dl><p>BR-01: Hinweis</p>'
        html += '<p>Dieser Prüfbericht wurde erstellt mit Java.</p></body></html>'
        xml = f'''<r:report xmlns:r="{NS['r']}" valid="true" varlVersion="1.0.0">
          <r:engine><r:name>Java</r:name></r:engine><r:timestamp>2026-10-31T20:00:00Z</r:timestamp>
          <r:documentIdentification><r:documentHash><r:hashAlgorithm>SHA-256</r:hashAlgorithm>
          <r:hashValue>{base64.b64encode(digest).decode()}</r:hashValue></r:documentHash>
          <r:documentReference>Rechnung.XML</r:documentReference></r:documentIdentification>
          <r:scenarioMatched><r:validationStepResult id="val-xsd" valid="true"/>
          <r:validationStepResult id="val-sch.1" valid="true"><r:message code="BR-01" level="warning" xpathLocation="/Invoice" test="exists(ID)">Hinweis</r:message>
          </r:validationStepResult></r:scenarioMatched>
          <r:assessment><r:accept><r:explanation>Fachlich zulässig</r:explanation></r:accept></r:assessment></r:report>'''
        for directory in (self.baseline, self.candidate):
            directory.mkdir()
            (directory / "Rechnung-report.xml").write_text(xml, encoding="utf-8")
            (directory / "Rechnung-report.html").write_text(html, encoding="utf-8")

    def mutate(self, operation):
        """Einzelne Berichtselemente ändern, ohne das gültige Ausgangspaar zu verlieren."""
        path = self.candidate / "Rechnung-report.xml"
        tree = ET.parse(path)
        operation(tree.getroot())
        tree.write(path, encoding="utf-8", xml_declaration=True)

    def result(self):
        """Öffentliche Vergleichsfunktion mit denselben Parametern wie das CLI ausführen."""
        return compare(self.manifest, [self.baseline, self.candidate])

    def test_valid_pair_and_totals(self):
        result = self.result()
        self.assertTrue(result["passed"])
        self.assertEqual(result["modes"][1]["totals"], {"reports": 1, "accept": 1, "reject": 0, "undefined": 0, "errors": 0, "warnings": 1, "failed_cases": 0})

    def test_allowed_metadata_changes(self):
        def change(root):
            root.find("r:engine/r:name", NS).text = "SaxonC"
            root.find("r:timestamp", NS).text = "2026-11-01T10:00:00Z"
            root.find("r:documentIdentification/r:documentReference", NS).text = "file:///D:/Anderer%20Pfad/Rechnung.XML"
        self.mutate(change)
        path = self.candidate / "Rechnung-report.html"
        path.write_text(path.read_text().replace("31.10.2026 20:00:00", "01.11.2026 10:00:00")
                        .replace("<dd>Rechnung.XML", "<dd>D:/Pfad/Rechnung.XML").replace("erstellt mit Java.", "erstellt mit SaxonC."))
        self.assertTrue(self.result()["passed"])

    def test_missing_finding(self):
        self.mutate(lambda root: root.find(".//r:validationStepResult[@id='val-sch.1']", NS).remove(root.find(".//r:message", NS)))
        self.assertFalse(self.result()["passed"])

    def test_changed_finding_attributes(self):
        for attribute, value in (("code", "OTHER"), ("level", "error"), ("xpathLocation", "/Invoice/ID"), ("test", "false()")):
            with self.subTest(attribute=attribute):
                self.mutate(lambda root: root.find(".//r:message", NS).set(attribute, value))
                self.assertFalse(self.result()["passed"])
                self.mutate(lambda root: root.find(".//r:message", NS).set(attribute, {"code": "BR-01", "level": "warning", "xpathLocation": "/Invoice", "test": "exists(ID)"}[attribute]))

    def test_acceptance_changed(self):
        self.mutate(lambda root: setattr(root.find("r:assessment/r:accept", NS), "tag", "{" + NS["r"] + "}reject"))
        self.assertFalse(self.result()["passed"])

    def test_schema_decision_changed(self):
        self.mutate(lambda root: root.find(".//r:validationStepResult[@id='val-xsd']", NS).set("valid", "false"))
        self.assertFalse(self.result()["passed"])

    def test_assessment_explanation_changed(self):
        self.mutate(lambda root: setattr(root.find("r:assessment/r:accept/r:explanation", NS), "text", "Andere Entscheidung"))
        self.assertFalse(self.result()["passed"])

    def test_non_schematron_finding_detected(self):
        def change(root):
            step = root.find(".//r:validationStepResult[@id='val-xsd']", NS)
            ET.SubElement(step, "{" + NS["r"] + "}message", {"code": "XSD", "level": "error"}).text = "Schemafehler"
        self.mutate(change)
        self.assertFalse(self.result()["passed"])

    def test_missing_xml_or_html(self):
        for extension in ("xml", "html"):
            with self.subTest(extension=extension):
                path = self.candidate / ("Rechnung-report." + extension)
                data = path.read_bytes()
                path.unlink()
                self.assertFalse(self.result()["passed"])
                path.write_bytes(data)

    def test_unexpected_report(self):
        (self.candidate / "Fremd-report.xml").write_text("<report/>")
        self.assertFalse(self.result()["passed"])

    def test_input_hash_changed(self):
        self.source.write_bytes(b"<Changed/>")
        result = self.result()
        self.assertFalse(result["passed"])
        self.assertFalse(result["cases"][0]["passed"])
        self.assertTrue(result["cases"][0]["input_differences"])

    def test_nested_unexpected_report(self):
        directory = self.candidate / "foreign"
        directory.mkdir()
        (directory / "Fremd-report.xml").write_text("<report/>")
        self.assertFalse(self.result()["passed"])

    def test_missing_input(self):
        self.source.unlink()
        self.assertFalse(self.result()["passed"])

    def test_unexpected_input(self):
        (self.inputs / "Fremd.XML").write_bytes(b"<Other/>")
        self.assertFalse(self.result()["passed"])

    def test_input_size_changed(self):
        manifest = json.loads(self.manifest.read_text())
        manifest["cases"][0]["size"] += 1
        self.manifest.write_text(json.dumps(manifest))
        self.assertFalse(self.result()["passed"])

    def test_report_hash_changed_in_both_modes(self):
        self.mutate(lambda root: setattr(root.find("r:documentIdentification/r:documentHash/r:hashValue", NS), "text", base64.b64encode(b"X" * 32).decode()))
        (self.baseline / "Rechnung-report.xml").write_bytes((self.candidate / "Rechnung-report.xml").read_bytes())
        self.assertFalse(self.result()["passed"])

    def test_foreign_reference(self):
        self.mutate(lambda root: setattr(root.find("r:documentIdentification/r:documentReference", NS), "text", "Andere.XML"))
        self.assertFalse(self.result()["passed"])

    def test_html_finding_changed(self):
        path = self.candidate / "Rechnung-report.html"
        path.write_text(path.read_text().replace("BR-01: Hinweis", "BR-01: Entfernt"))
        self.assertFalse(self.result()["passed"])

    def test_unknown_semantic_field_changed(self):
        self.mutate(lambda root: ET.SubElement(root, "{" + NS["r"] + "}additionalDecision", {"value": "different"}))
        self.assertFalse(self.result()["passed"])

    def test_cli_exit_codes(self):
        output = self.root / "comparison.json"
        arguments = [str(self.manifest), str(self.baseline), str(self.candidate), "--output", str(output)]
        with redirect_stdout(io.StringIO()):
            self.assertEqual(main(arguments), 0)
        self.assertTrue(json.loads(output.read_text())["passed"])
        (self.candidate / "Rechnung-report.html").unlink()
        with redirect_stdout(io.StringIO()):
            self.assertEqual(main(arguments), 1)
        self.assertFalse(json.loads(output.read_text())["passed"])


if __name__ == "__main__":
    unittest.main()
