"""Vergleicht Benchmark-Berichte mit dem unveränderten Eingabemanifest."""

import argparse
import base64
from copy import deepcopy
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

from compare_reports import NS, signature


VARL = NS["r"]
HTML = "http://www.w3.org/1999/xhtml"


def compact(text):
    """Formatierungsleerraum verändert keine fachlichen Textinhalte."""
    return " ".join((text or "").split())


def local_name(tag):
    """HTML-Serialisierung und eingebettetes XHTML verwenden dieselben Elementnamen."""
    return tag.rsplit("}", 1)[-1]


def reference_name(text):
    """Nur das Verzeichnis einer Dokumentreferenz ist laufzeitabhängig."""
    value = unquote((text or "").strip()).replace("\\", "/")
    if value.startswith("file:"):
        value = urlsplit(value).path
    return value.rsplit("/", 1)[-1]


def normalize_metadata(root):
    """Nur explizite Prüfmetadaten ausnehmen; Rechnungsdaten und Befundtexte bleiben erhalten."""
    for parent in root.iter():
        children = list(parent)
        for index, child in enumerate(children):
            if (local_name(parent.tag) == "body" and local_name(child.tag) == "p" and not len(child)
                    and compact(child.text).startswith("Dieser Prüfbericht wurde erstellt mit ") and compact(child.text).endswith(".")):
                child.text = "Dieser Prüfbericht wurde erstellt mit <Prüfengine>."
            if child.tag in (f"{{{VARL}}}engine", f"{{{VARL}}}timestamp") and parent is root:
                parent.remove(child)
            elif child.tag == f"{{{VARL}}}documentReference":
                child.text = reference_name(child.text)
            if local_name(child.tag) != "dt" or index + 1 >= len(children):
                continue
            following = children[index + 1]
            if local_name(following.tag) != "dd":
                continue
            label = compact("".join(child.itertext()))
            if label == "Zeitpunkt der Prüfung:":
                following.clear()
                following.text = "<Prüfzeitpunkt>"
            elif label == "Referenz:":
                value = reference_name("".join(following.itertext()))
                following.clear()
                following.text = value
    return root


def flattened_tree(root):
    """Alle Attribute, Texte und unbekannten Erweiterungen mit genauer Fundstelle vergleichen."""
    values = {}

    def visit(element, path):
        tag = element.tag
        if tag.startswith(f"{{{HTML}}}"):
            tag = "html:" + local_name(tag)
        path = path + "/" + tag
        values[path + "/#element"] = True
        for key, value in element.attrib.items():
            values[path + "/@" + key] = value
        text = compact(element.text)
        if text:
            values[path + "/#text"] = text
        counts = {}
        for index, child in enumerate(element):
            counts[child.tag] = counts.get(child.tag, 0) + 1
            visit(child, path + "[" + str(counts[child.tag]) + "]")
            tail = compact(child.tail)
            if tail:
                values[path + "/#tail[" + str(index) + "]"] = tail

    visit(normalize_metadata(deepcopy(root)), "")
    return values


class ReportHtmlParser(HTMLParser):
    """HTML-Berichte unabhängig von XML-Deklaration, Präfixen und Void-Serialisierung lesen."""

    VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = ET.Element("html-document")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        tag = tag.split(":")[-1]
        attributes = {key: value or "" for key, value in attrs if not key.startswith("xmlns")}
        element = ET.SubElement(self.stack[-1], f"{{{HTML}}}{tag}", attributes)
        if tag not in self.VOID:
            self.stack.append(element)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag.split(":")[-1] not in self.VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        tag = tag.split(":")[-1]
        if tag in self.VOID:
            return
        if len(self.stack) == 1 or local_name(self.stack[-1].tag) != tag:
            raise ValueError("Ungültige HTML-Verschachtelung bei " + tag)
        self.stack.pop()

    def handle_data(self, data):
        parent = self.stack[-1]
        if len(parent):
            parent[-1].tail = (parent[-1].tail or "") + data
        else:
            parent.text = (parent.text or "") + data

    def report_tree(self, text):
        self.feed(text)
        self.close()
        if len(self.stack) != 1:
            raise ValueError("Nicht geschlossene HTML-Elemente")
        if not any(local_name(element.tag) == "html" for element in self.root):
            raise ValueError("HTML-Wurzelelement fehlt")
        return self.root


def differences(expected, actual, prefix):
    """Jede abweichende Fundstelle mit beiden beobachteten Werten ausgeben."""
    return [{"field": prefix + key, "expected": expected.get(key), "actual": actual.get(key)}
            for key in sorted(expected.keys() | actual.keys()) if expected.get(key) != actual.get(key)]


def verify_inputs(manifest):
    """Dateimenge, Größe und SHA-256 prüfen, damit Berichte wirklich denselben Bestand betreffen."""
    directory = Path(manifest["input_directory"])
    expected_names = {case["name"] for case in manifest["cases"]}
    actual_names = {path.name for path in directory.iterdir() if path.is_file() and path.suffix.lower() == ".xml"}
    issues = []
    for name in sorted(expected_names - actual_names):
        issues.append({"file": name, "field": "input_missing"})
    for name in sorted(actual_names - expected_names):
        issues.append({"file": name, "field": "input_unexpected"})
    for case in manifest["cases"]:
        path = directory / case["name"]
        if not path.is_file():
            continue
        data = path.read_bytes()
        for field, expected, actual in (("size", case["size"], len(data)), ("sha256", case["sha256"], hashlib.sha256(data).hexdigest())):
            if expected != actual:
                issues.append({"file": case["name"], "field": "input_" + field, "expected": expected, "actual": actual})
    return {"passed": not issues, "directory": str(directory), "differences": issues}


def report_signature(path, case):
    """Bekannte Signatur erweitern, ohne Befunde anderer Prüfschritte auszublenden."""
    root = ET.parse(path).getroot()
    if root.tag != f"{{{VARL}}}report":
        raise ValueError("Kein VARL-Bericht")
    known = signature(root)
    messages = root.findall(".//r:validationStepResult/r:message", NS)
    levels = [message.get("level", "").lower() for message in messages]
    accepted = root.find("r:assessment/r:accept", NS) is not None
    rejected = root.find("r:assessment/r:reject", NS) is not None
    issues = []
    if accepted == rejected:
        issues.append({"field": "assessment", "error": "Genau eine Annahme- oder Ablehnungsentscheidung erforderlich"})
    algorithm = compact(root.findtext("r:documentIdentification/r:documentHash/r:hashAlgorithm", default="", namespaces=NS))
    expected_hash = base64.b64encode(bytes.fromhex(case["sha256"])).decode("ascii")
    actual_hash = compact(known["hash"])
    if algorithm.upper().replace("-", "") != "SHA256" or actual_hash != expected_hash:
        issues.append({"field": "report_input_hash", "expected": expected_hash, "actual": actual_hash, "algorithm": algorithm})
    actual_reference = reference_name(root.findtext("r:documentIdentification/r:documentReference", default="", namespaces=NS))
    if actual_reference != case["name"]:
        issues.append({"field": "report_input_reference", "expected": case["name"], "actual": actual_reference})
    return {
        "known": known,
        "xml": flattened_tree(root),
        "accepted": accepted,
        "rejected": rejected,
        "errors": sum(level in ("error", "fatal") for level in levels),
        "warnings": sum(level in ("warning", "warn") for level in levels),
        "issues": issues,
    }


def compare(manifest_path, directories):
    """Jeder Modus wird gegen dieselbe Baseline und unabhängig gegen das Eingabemanifest geprüft."""
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8-sig"))
    cases = manifest["cases"]
    names = [case["name"] for case in cases]
    if not names or len(set(name.casefold() for name in names)) != len(names):
        raise ValueError("Manifest enthält keine oder doppelte Eingaben")
    if any(Path(name).name != name or "\\" in name or Path(name).suffix.lower() != ".xml" for name in names):
        raise ValueError("Manifest enthält ungültige XML-Dateinamen")
    mode_names = [str(Path(directory).resolve()) for directory in directories]
    if len(set(mode_names)) != len(mode_names):
        raise ValueError("Modusverzeichnisse müssen verschieden sein")
    expected_reports = {Path(name).stem + "-report." + extension for name in names for extension in ("xml", "html")}
    result = {"passed": True, "case_count": len(cases), "baseline": mode_names[0], "input_verification": verify_inputs(manifest), "modes": [], "cases": []}
    for mode in mode_names:
        directory = Path(mode)
        found = {str(path.relative_to(directory)) for path in directory.rglob("*")
                 if path.is_file() and path.suffix.lower() in (".xml", ".html")} if directory.is_dir() else set()
        unexpected = sorted(found - expected_reports)
        mode_result = {"directory": mode, "passed": not unexpected, "unexpected_reports": unexpected,
                       "totals": {"reports": 0, "accept": 0, "reject": 0, "undefined": 0, "errors": 0, "warnings": 0, "failed_cases": 0}}
        result["modes"].append(mode_result)
    for case in cases:
        name = case["name"]
        input_issues = [issue for issue in result["input_verification"]["differences"] if issue["file"] == name]
        case_result = {"name": name, "passed": not input_issues, "input_differences": input_issues, "modes": []}
        baseline = None
        for index, mode_result in enumerate(result["modes"]):
            directory = Path(mode_result["directory"])
            report = None
            issues = list(input_issues)
            xml_path = directory / (Path(name).stem + "-report.xml")
            html_path = directory / (Path(name).stem + "-report.html")
            for path in (xml_path, html_path):
                if not path.is_file():
                    issues.append({"field": "report_missing", "file": str(path)})
            if xml_path.is_file():
                try:
                    report = report_signature(xml_path, case)
                    issues.extend(report["issues"])
                    totals = mode_result["totals"]
                    totals["reports"] += 1
                    totals["accept"] += report["accepted"]
                    totals["reject"] += report["rejected"]
                    totals["undefined"] += not (report["accepted"] or report["rejected"])
                    totals["errors"] += report["errors"]
                    totals["warnings"] += report["warnings"]
                    if html_path.is_file():
                        report["html"] = flattened_tree(ReportHtmlParser().report_tree(html_path.read_text(encoding="utf-8-sig")))
                except (OSError, ValueError, ET.ParseError, TypeError) as error:
                    issues.append({"field": "report_parse", "error": str(error)})
            if index == 0:
                baseline = report
            if index and baseline is not None and report is not None:
                issues.extend(differences(baseline["known"], report["known"], "signature."))
                issues.extend(differences(baseline["xml"], report["xml"], "xml:"))
                if "html" in baseline and "html" in report:
                    issues.extend(differences(baseline["html"], report["html"], "html:"))
            elif index and baseline is None:
                issues.append({"field": "baseline_unavailable"})
            mode_case = {"directory": str(directory), "passed": not issues, "differences": issues}
            if report is not None:
                mode_case.update({key: report[key] for key in ("accepted", "rejected", "errors", "warnings")})
            case_result["modes"].append(mode_case)
            if issues:
                mode_result["passed"] = False
                mode_result["totals"]["failed_cases"] += 1
                case_result["passed"] = False
        result["cases"].append(case_result)
    result["passed"] = result["input_verification"]["passed"] and all(mode["passed"] for mode in result["modes"])
    return result


def main(argv=None):
    """Maschinenlesbares Ergebnis immer schreiben; jede fachliche Differenz ergibt Exitcode 1."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("directories", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    if len(args.directories) < 2:
        parser.error("Mindestens Baseline und ein Kandidatenverzeichnis erforderlich")
    try:
        result = compare(args.manifest, args.directories)
        exit_code = 0 if result["passed"] else 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        result = {"passed": False, "error": str(error)}
        exit_code = 2
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key not in ("cases", "input_verification")}, ensure_ascii=False))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
