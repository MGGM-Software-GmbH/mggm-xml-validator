"""Vergleicht aktuelle Java- und Delphi-Berichte einschließlich kontrollierter Gegenprobe."""

from collections import Counter
from copy import deepcopy
from datetime import datetime, timezone
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
SCHEMA = ROOT / "Source/createReportInput.xsd"
NS = {"r": "http://www.xoev.de/de/validator/varl/1", "s": "http://www.xoev.de/de/validator/framework/1/scenarios"}


def signature(root):
    """Nur absichtlich pro Engine unterschiedliche Diagnosen und Metadaten ausnehmen."""
    findings = []
    for step in root.findall(".//r:validationStepResult", NS):
        if not step.get("id", "").startswith("val-sch"):
            continue
        for message in step.findall("r:message", NS):
            findings.append((step.get("id"), message.get("code"), message.get("level"),
                             message.get("xpathLocation"), " ".join("".join(message.itertext()).split())))
    return {
        "scenario": root.findtext("r:scenarioMatched/s:scenario/s:name", default="", namespaces=NS).strip(),
        "valid": root.get("valid"),
        "accepted": root.find("r:assessment/r:accept", NS) is not None,
        "steps": [(step.get("id"), step.get("valid")) for step in root.findall(".//r:validationStepResult", NS)],
        "schematron_findings": sorted(findings),
        "document_data": [(child.tag, child.text or "") for child in root.findall("r:scenarioMatched/r:documentData/*", NS)],
        "hash": root.findtext("r:documentIdentification/r:documentHash/r:hashValue", default="", namespaces=NS),
    }


def verify(directory, native_directory="native"):
    """Ein fehlender Bericht, Befund oder falscher Prüfentscheid muss den Lauf fehlschlagen lassen."""
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    results = []
    negative_probe = None
    for case in manifest["cases"]:
        name = case["name"]
        java = ET.parse(directory / "java" / (name + "-report.xml")).getroot()
        native = ET.parse(directory / native_directory / (name + "-report.xml")).getroot()
        expected, actual = signature(java), signature(native)
        differences = [key for key in expected if expected[key] != actual[key]]
        # Java DigestInputStream erfasst bei verbotenem DTD nur den gelesenen Präfix.
        # Delphi muss unabhängig davon den Hash sämtlicher Eingabebytes liefern.
        if name == "dtd" and "hash" in differences:
            differences.remove("hash")
        digest = base64.b64encode(hashlib.sha256(Path(case["file"]).read_bytes()).digest()).decode("ascii")
        if actual["hash"] != digest:
            differences.append("input_hash")
        report_input = directory / native_directory / (name + "-reportInput.xml")
        validation = subprocess.run(["xmllint", "--noout", "--schema", str(SCHEMA), str(report_input)], capture_output=True, text=True)
        if validation.returncode:
            differences.append("report_input_schema")
        if not (directory / native_directory / (name + "-report.html")).is_file():
            differences.append("html_missing")
        results.append({"case": name, "passed": not differences, "differences": differences,
                        "scenario": actual["scenario"], "accepted": actual["accepted"],
                        "schematron_findings": len(actual["schematron_findings"]),
                        "report_input_schema_exit": validation.returncode,
                        "schema_diagnostic": validation.stderr if validation.returncode else ""})
        if name == "ubl-business-error":
            corrupted = deepcopy(native)
            step = corrupted.find(".//r:validationStepResult[@id='val-sch.1']", NS)
            step.remove(step.find("r:message", NS))
            negative_probe = signature(corrupted) != expected and actual == expected
    evidence = {"checked_at": datetime.now(timezone.utc).isoformat(), "cases": results,
                "passed": sum(case["passed"] for case in results), "total": len(results),
                "missing_finding_countercheck": negative_probe,
                "diagnostic_exceptions": "XML-Schema- und Wohlgeformtheitsdiagnosen unterscheiden sich zwischen MSXML und JAXP; Entscheidungen werden verglichen. Bei DTD-Verbot hasht Java nur gelesene Bytes; Delphi prüft den gesamten Eingabehash."}
    (directory / "comparison.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in evidence.items() if key != "cases"}, ensure_ascii=False))
    for case in results:
        if not case["passed"]:
            print(json.dumps(case, ensure_ascii=False))
    return 0 if evidence["passed"] == evidence["total"] and negative_probe is not False else 1


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        raise SystemExit("Aufruf: compare_reports.py Laufverzeichnis [Delphi-Unterverzeichnis]")
    raise SystemExit(verify(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) == 3 else "native"))
