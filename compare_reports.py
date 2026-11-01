"""Strenger Vergleich von Referenzberichten einschließlich isolierter Gegenproben.

manifest.cases[].expected.status wird gegen den öffentlichen CLI-Status aus
<Delphi-Modus>/results.json geprüft, niemals aus der Annahmeentscheidung abgeleitet.
diagnostic_exception erlaubt ausschließlich die unten dokumentierten Fehlerklassen.
input_aliases benennt explizite zusätzliche Hostpfade derselben Originaleingabe
für svrl:active-pattern/@documents; unbekannte Dokumentkontexte bleiben Fehler.
java_hash_exception="doctype-read-prefix" erlaubt nur einen nachgewiesenen Java-
Präfixhash bei DTD-Verbot. Delphi muss sämtliche Originalbytes hashen.
"""

from collections import Counter
from copy import deepcopy
from datetime import datetime, timezone
import base64
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
SCHEMA = ROOT / "Source/createReportInput.xsd"
NS = {"r": "http://www.xoev.de/de/validator/varl/1",
      "s": "http://www.xoev.de/de/validator/framework/1/scenarios",
      "i": "http://www.xoev.de/de/validator/framework/1/createreportinput",
      "h": "http://www.w3.org/1999/xhtml"}
DIAGNOSTIC_EXCEPTIONS = {
    "schema-unexpected-element": "JAXP cvc-complex-type.2.4.a / MSXML 0xC00CE014: unerwarteter QName und sämtliche erwarteten QNames bleiben erhalten; nur Provider-Code, Wortlaut und unzuverlässige Zeile/Spalte dürfen abweichen.",
    "xml-unclosed-document": "JAXP SXXP0003 Entity-Ende / MSXML 0xC00CE553 ungeschlossene Tags, nur bei tatsächlich unvollständigen Originalbytes. Phase, Code, Schwere und Location bleiben erhalten.",
    "xml-doctype-forbidden": "JAXP disallow-doctype-decl / MSXML 0xC00CE584, nur bei DOCTYPE in den Originalbytes. Phase, Code, Schwere und Location bleiben erhalten.",
}


def compact(value):
    """Darstellungsleerraum in HTML und beschreibenden Szenariotexten vereinheitlichen."""
    return " ".join((value or "").split())


def reference_name(value):
    """Nur der Verzeichnisteil einer Dokumentreferenz ist laufzeitabhängig."""
    value = unquote(value or "").replace("\\", "/")
    return (urlsplit(value).path if value.startswith("file:") else value).rsplit("/", 1)[-1]


def input_reference(value):
    """Datei-URI und expliziten Hostpfad vergleichen, ohne Verzeichnisse abzuschneiden."""
    value = unquote(value).replace("\\", "/")
    if value.startswith("file:"):
        parsed = urlsplit(value)
        if parsed.netloc:
            return "//" + parsed.netloc + parsed.path
        value = parsed.path
    return value[1:] if re.match(r"^/[A-Za-z]:/", value) else value


def tree_value(element, html=False):
    """Präfixe, Attributreihenfolge und reiner Einrückungsleerraum sind irrelevant."""
    if element is None:
        return None
    html = html or element.tag.startswith(f"{{{NS['h']}}}")
    token_tags = {f"{{{NS['s']}}}name", f"{{{NS['s']}}}p"}
    text = compact(element.text) if html or element.tag in token_tags else (element.text or "").strip()
    return (element.tag, tuple(sorted(element.attrib.items())), text,
            tuple((tree_value(child, html), compact(child.tail) if html else (child.tail or "").strip()) for child in element))


def signature(root):
    """Alle Phasen und Befunde erfassen, ohne andere Diagnosen auszublenden.

    Befunde sind eine Multimenge: Ihre Position ist keine fachliche Sortierung.
    Alle Attribute außer der vom Renderer erzeugten Positions-ID bleiben erhalten.
    Die Signatur bleibt für compare_benchmark.py ohne Strukturprüfung verwendbar.
    """
    findings = []
    steps = root.findall(".//r:validationStepResult", NS)
    for step in steps:
        for message in step.findall("r:message", NS):
            findings.append((step.get("id", ""), message.get("code", ""), message.get("level", ""),
                             message.get("xpathLocation", ""), "".join(message.itertext()),
                             tuple(sorted((key, value) for key, value in message.attrib.items()
                                          if key not in ("id", "code", "level", "xpathLocation")))))
    return {
        "scenario": root.findtext("r:scenarioMatched/s:scenario/s:name", default="", namespaces=NS).strip(),
        "scenario_identity": tree_value(root.find("r:scenarioMatched/s:scenario", NS)),
        "valid": root.get("valid"),
        "accepted": root.find("r:assessment/r:accept", NS) is not None,
        "steps": [(step.get("id"), step.get("valid")) for step in steps],
        "phase_details": [(step.get("id"), tuple(sorted(step.attrib.items())),
                           tuple(tree_value(child) for child in step if child.tag != f"{{{NS['r']}}}message")) for step in steps],
        "findings": sorted(findings),
        "schematron_findings": sorted(finding[:5] for finding in findings if finding[0].startswith("val-sch")),
        "document_data": [(child.tag, child.text or "") for child in root.findall("r:scenarioMatched/r:documentData/*", NS)],
        "document_data_structure": tree_value(root.find("r:scenarioMatched/r:documentData", NS)),
        "hash": root.findtext("r:documentIdentification/r:documentHash/r:hashValue", default="", namespaces=NS),
    }


def diagnostic(text, phase, code, data, exception):
    """Nur explizit angeforderte, am Referenzbestand belegte Fehlerklassen übersetzen."""
    text = text.strip()
    if exception == "schema-unexpected-element" and phase == "val-xsd":
        if code == "cvc-complex-type.2.4.a":
            parts = re.findall(r'"([^"\n]+)":([A-Za-z_][\w.-]*)', text)
            wording = (("wird erwartet" in text and "beginnend mit Element" in text)
                       or ("is expected" in text and "Invalid content was found starting with element" in text))
            if len(parts) >= 2 and wording:
                return exception, (parts[0], tuple(sorted(parts[1:])))
        if code == "generic-error" and text.startswith("MSXML 0xC00CE014:") and "Erwartet:" in text:
            before, after = text.split("Erwartet:", 1)
            unexpected = re.findall(r"\{([^}]+)\}([A-Za-z_][\w.-]*)", before)
            expected = re.findall(r"\{([^}]+)\}([A-Za-z_][\w.-]*)", after.split(" [Datei:", 1)[0].removesuffix("."))
            if unexpected and expected and "nicht gültig" in before:
                return exception, (unexpected[0], tuple(sorted(expected)))
    if phase == "val-xml" and code == "generic-error":
        if exception == "xml-doctype-forbidden" and b"<!DOCTYPE" in data and (
                ("SXXP0003" in text and ("DOCTYPE ist nicht zulässig" in text or "DOCTYPE is disallowed" in text) and "disallow-doctype-decl" in text)
                or ("MSXML 0xC00CE584:" in text and "DTD ist nicht zulässig" in text)):
            return exception, ()
        if exception == "xml-unclosed-document":
            try:
                ET.fromstring(data)
            except ET.ParseError as error:
                # Expat 3 ist ausschließlich ein unerwartetes Dokumentende.
                if error.code == 3 and (
                        ("SXXP0003" in text and ("XML-Dokumentstrukturen müssen innerhalb derselben Entity beginnen und enden" in text
                                               or "XML document structures must start and end within the same entity" in text))
                        or ("MSXML 0xC00CE553:" in text and "Tags wurden nicht geschlossen:" in text)):
                    return exception, ()
    return None


class HtmlParser(HTMLParser):
    """HTML und XHTML lesen, ohne eine leere Datei als Bericht zu akzeptieren."""
    VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = ET.Element("html-document")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        tag = tag.split(":")[-1]
        child = ET.SubElement(self.stack[-1], f"{{{NS['h']}}}{tag}", {key: value or "" for key, value in attrs if not key.startswith("xmlns")})
        if tag not in self.VOID:
            self.stack.append(child)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag.split(":")[-1] not in self.VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        tag = tag.split(":")[-1]
        if tag in self.VOID:
            return
        if len(self.stack) < 2 or self.stack[-1].tag.rsplit("}", 1)[-1] != tag:
            raise ValueError("Ungültige HTML-Verschachtelung: " + tag)
        self.stack.pop()

    def handle_data(self, value):
        parent = self.stack[-1]
        if len(parent):
            parent[-1].tail = (parent[-1].tail or "") + value
        else:
            parent.text = (parent.text or "") + value

    def parse(self, value):
        self.feed(value)
        self.close()
        if len(self.stack) != 1 or len(self.root) != 1 or self.root[0].tag != f"{{{NS['h']}}}html":
            raise ValueError("HTML-Wurzel oder geschlossene Struktur fehlt")
        return self.root[0]


def html_encoding(root):
    """Nur die belegte UTF-8-Meta-Serialisierung im HTML-Kopf vereinheitlichen.

    Saxon serialisiert XHTML meta/@charset als vorangestelltes HTML
    meta/@http-equiv. Beide Formen deklarieren exakt denselben Inhaltstyp.
    Andere Metaelemente, Codierungen und zusätzliche Attribute bleiben erhalten.
    """
    root = deepcopy(root)
    head = root.find("h:head", NS)
    if head is None:
        return root
    matches = [child for child in head if child.tag == f"{{{NS['h']}}}meta" and (
        {key.lower(): value.lower() for key, value in child.attrib.items()} == {"charset": "utf-8"}
        or {key.lower(): value.lower() for key, value in child.attrib.items()} == {
            "http-equiv": "content-type", "content": "text/html; charset=utf-8"})]
    if len(matches) == 1:
        head.remove(matches[0])
        head.insert(0, ET.Element(f"{{{NS['h']}}}meta", {"charset": "utf-8"}))
    return root


def normalize(root, data, report, exception, input_aliases=()):
    """Metadaten und nachgewiesene Diagnosen ausschließlich an bekannten Feldern übersetzen."""
    root = deepcopy(root)
    replacements, findings, positions = {}, {}, {}
    for step in report.findall(".//r:validationStepResult", NS):
        for message in step.findall("r:message", NS):
            text = "".join(message.itertext()).strip()
            result = diagnostic(text, step.get("id"), message.get("code"), data, exception)
            if result:
                replacements[text] = repr(result)
                replacements[compact(text)] = repr(result)
                findings[message.get("id")] = repr(result)
                if exception == "schema-unexpected-element" and not message.get("xpathLocation"):
                    positions[message.get("id")] = (("Zeile: " + message.get("lineNumber") + " Spalte: " + message.get("columnNumber"))
                                                   if message.get("lineNumber") and message.get("columnNumber") else "")
    for parent in root.iter():
        if parent.tag == "{http://purl.oclc.org/dsdl/svrl}active-pattern" and parent.get("documents"):
            # documents benennt die Eingabe-URI. Linux- und Windows-Läufe
            # dürfen nur über im Laufmanifest explizit gebundene Aliase
            # desselben unabhängig gehashten Inputs gleichgesetzt werden.
            aliases = {input_reference(value) for value in input_aliases}
            documents = parent.get("documents").split()
            if any(input_reference(value) not in aliases for value in documents):
                raise ValueError("input_reference.svrl_documents")
            parent.set("documents", " ".join("<Originaleingabe>" for value in documents))
        children = list(parent)
        for index, child in enumerate(children):
            # Der Bericht rendert die unzuverlässigen Provider-Koordinaten in
            # der unmittelbar folgenden Tabellenzeile desselben Schemafehlers.
            # Nur der anhand der Originalattribute nachgewiesene Text oder
            # dessen belegtes Fehlen wird vereinheitlicht, kein XPath-Inhalt.
            if child.tag == f"{{{NS['h']}}}tr" and len(child) >= 4 and index + 1 < len(children):
                identifier = compact("".join(child[0].itertext()))
                following = children[index + 1]
                if identifier in positions and following.tag == f"{{{NS['h']}}}tr" and len(following) == 1 and not len(following[0]):
                    if compact(following[0].text) == positions[identifier]:
                        following[0].text = "<Providerposition>"
            if child.tag in (f"{{{NS['r']}}}engine", f"{{{NS['i']}}}engine") and parent is root:
                child.clear()
                child.text = "<Prüfengine>"
            if child.tag in (f"{{{NS['r']}}}timestamp", f"{{{NS['i']}}}timestamp") and parent is root:
                child.text = "<Prüfzeitpunkt>"
            if child.tag in (f"{{{NS['r']}}}documentReference", f"{{{NS['i']}}}documentReference"):
                child.text = reference_name(child.text)
            if child.tag == f"{{{NS['h']}}}dt" and index + 1 < len(children) and children[index + 1].tag == f"{{{NS['h']}}}dd":
                following = children[index + 1]
                label = compact("".join(child.itertext()))
                if label in ("Zeitpunkt der Prüfung:", "Referenz:"):
                    value = "<Prüfzeitpunkt>" if label.startswith("Zeitpunkt") else reference_name("".join(following.itertext()))
                    following.clear()
                    following.text = value
        if parent.tag == f"{{{NS['h']}}}p" and not len(parent) and compact(parent.text).startswith("Dieser Prüfbericht wurde erstellt mit "):
            parent.text = "Dieser Prüfbericht wurde erstellt mit <Prüfengine>."
        if parent.tag == f"{{{NS['h']}}}tr" and len(parent) >= 4 and compact("".join(parent[0].itertext())) in findings:
            parent[1].text = findings[compact("".join(parent[0].itertext()))]
        if parent.text and parent.text.strip() in replacements:
            parent.text = replacements[parent.text.strip()]
        elif parent.text and compact(parent.text) in replacements:
            parent.text = replacements[compact(parent.text)]
        if parent.tag == f"{{{NS['r']}}}message" and parent.get("id") in findings:
            parent.set("code", findings[parent.get("id")])
            if exception == "schema-unexpected-element":
                parent.attrib.pop("lineNumber", None)
                parent.attrib.pop("columnNumber", None)
        if parent.tag == f"{{{NS['i']}}}xmlSyntaxError":
            message = parent.find("i:message", NS)
            if message is not None:
                original = (message.text or "").removeprefix("cvc-complex-type.2.4.a: ")
                phase = "val-xsd" if exception == "schema-unexpected-element" else "val-xml"
                code = "cvc-complex-type.2.4.a" if (message.text or "").startswith("cvc-complex-type.2.4.a:") else "generic-error"
                result = diagnostic(original, phase, code, data, exception)
                if result:
                    message.text = repr(result)
                    if exception == "schema-unexpected-element":
                        for field in ("rowNumber", "columnNumber"):
                            item = parent.find("i:" + field, NS)
                            if item is not None:
                                parent.remove(item)
    return root


def required(root, paths):
    """Pflichtelemente dürfen auch bei beidseitig defekten Berichten nicht fehlen."""
    for path in paths:
        elements = root.findall(path, NS)
        if len(elements) != 1 or not "".join(elements[0].itertext()).strip():
            raise ValueError("required_structure." + path)


def snapshot(bundle, case, data, engine):
    """Bericht, Berichtseingabe, HTML und öffentlichen Status unabhängig prüfen."""
    report, report_input, html = (deepcopy(bundle[key]) for key in ("report", "report_input", "html"))
    exception = case.get("diagnostic_exception")
    if exception is not None and exception not in DIAGNOSTIC_EXCEPTIONS:
        raise ValueError("unknown_diagnostic_exception")
    if case.get("java_hash_exception") not in (None, "doctype-read-prefix") or (case.get("java_hash_exception") and exception != "xml-doctype-forbidden"):
        raise ValueError("unknown_java_hash_exception")
    if report.tag != f"{{{NS['r']}}}report" or report_input.tag != f"{{{NS['i']}}}createReportInput":
        raise ValueError("report_structure.root")
    if not report.get("varlVersion"):
        raise ValueError("report_structure.varlVersion")
    for root, prefix in ((report, "r"), (report_input, "i")):
        paths = (prefix + ":engine/" + prefix + ":name", prefix + ":timestamp",
                 prefix + ":documentIdentification/" + prefix + ":documentHash/" + prefix + ":hashAlgorithm",
                 prefix + ":documentIdentification/" + prefix + ":documentHash/" + prefix + ":hashValue",
                 prefix + ":documentIdentification/" + prefix + ":documentReference")
        required(root, paths)
        datetime.fromisoformat(root.findtext(prefix + ":timestamp", namespaces=NS).replace("Z", "+00:00"))
        digest = base64.b64encode(hashlib.sha256(data).digest()).decode("ascii")
        hash_element = root.find(paths[3], NS)
        if root.findtext(paths[2], namespaces=NS) != "SHA-256":
            raise ValueError("input_hash.algorithm")
        if hash_element.text != digest:
            # Java DigestInputStream erfasst beim DTD-Verbot nur gelesene Bytes.
            # Die Ausnahme ist explizit, an die Diagnose gebunden und prüft den
            # Hash gegen einen echten, nicht leeren Präfix der Originalbytes.
            allowed = engine == "java" and case.get("java_hash_exception") == "doctype-read-prefix" and exception == "xml-doctype-forbidden" and any(
                diagnostic("".join(message.itertext()), "val-xml", message.get("code"), data, exception)
                for message in report.findall(".//r:validationStepResult[@id='val-xml']/r:message", NS))
            hasher, matched = hashlib.sha256(), False
            if allowed:
                for byte in data[:-1]:
                    hasher.update(bytes((byte,)))
                    if base64.b64encode(hasher.digest()).decode("ascii") == hash_element.text:
                        matched = True
                        break
            if not matched:
                raise ValueError("input_hash." + prefix)
        hash_element.text = digest
        if reference_name(root.findtext(paths[4], namespaces=NS)) != Path(case["file"]).name:
            raise ValueError("input_reference." + prefix)
    branches = report.findall("r:scenarioMatched", NS) + report.findall("r:noScenarioMatched", NS)
    assessment = report.findall("r:assessment/*", NS)
    steps = report.findall(".//r:validationStepResult", NS)
    if len(branches) != 1 or len(assessment) != 1 or assessment[0].tag not in (f"{{{NS['r']}}}accept", f"{{{NS['r']}}}reject"):
        raise ValueError("report_structure.scenario_or_assessment")
    if report.get("valid") not in ("true", "false") or not steps or len({step.get("id") for step in steps}) != len(steps):
        raise ValueError("report_structure.steps_or_valid")
    if not any(step.get("id") == "val-xml" for step in steps):
        raise ValueError("report_structure.val-xml")
    for step in steps:
        if not step.get("id") or step.get("valid") not in ("true", "false"):
            raise ValueError("report_structure.step")
        for message in step.findall("r:message", NS):
            if not message.get("code") or not message.get("level") or not "".join(message.itertext()).strip():
                raise ValueError("report_structure.finding")
    if report.find("r:scenarioMatched", NS) is not None:
        required(report, ("r:scenarioMatched/s:scenario/s:name",))
        if tree_value(report.find("r:scenarioMatched/s:scenario", NS)) != tree_value(report_input.find("s:scenario", NS)):
            raise ValueError("report_input.scenario")
    phase_counts = (("val-xml", "i:validationResultsWellformedness"), ("val-xsd", "i:validationResultsXmlSchema"),
                    ("val-sch", "i:validationResultsSchematron"))
    for phase, path in phase_counts:
        if sum(step.get("id", "").split(".")[0] == phase for step in steps) != len(report_input.findall(path, NS)):
            raise ValueError("report_input.phase." + phase)
    if exception and not any(diagnostic("".join(message.itertext()), step.get("id"), message.get("code"), data, exception)
                             for step in steps for message in step.findall("r:message", NS)):
        raise ValueError("diagnostic_exception.semantic_features_missing")
    expected = case.get("expected", {})
    if "report_valid" in expected and (report.get("valid") == "true") != expected["report_valid"]:
        raise ValueError("expected.report_valid")
    if "accepted" in expected and (assessment[0].tag == f"{{{NS['r']}}}accept") != expected["accepted"]:
        raise ValueError("expected.accepted")
    messages = [message for step in steps for message in step.findall("r:message", NS)]
    for finding in expected.get("required_findings", []):
        if not any(all(message.get(key) == value for key, value in finding.items()) for message in messages):
            raise ValueError("expected.required_findings." + finding.get("code", ""))
    if engine == "native":
        public = bundle.get("public", {})
        if expected.get("status") not in ("V", "W", "E", "F") or public.get("status") != expected["status"]:
            raise ValueError("public_status")
        accepted = report.find("r:assessment/r:accept", NS) is not None
        if public.get("acceptance") != ("ACCEPTABLE" if accepted else "REJECT"):
            raise ValueError("public_acceptance")
        for field in ("accepted", "schema_valid", "processing_error"):
            if field in expected:
                actual = accepted if field == "accepted" else public.get(field)
                if actual != expected[field]:
                    raise ValueError("expected." + field)
    if html.tag != f"{{{NS['h']}}}html":
        raise ValueError("html.root")
    required(html, ("h:head/h:title", "h:body"))
    if not html.findall(".//h:table", NS) or not html.findall(".//h:h1", NS):
        raise ValueError("html.content")
    explanations = report.findall("r:assessment/*/r:explanation/h:html", NS)
    if len(explanations) != 1 or tree_value(html_encoding(explanations[0]), True) != tree_value(html_encoding(html), True):
        raise ValueError("html.report_content")
    validation = subprocess.run(["xmllint", "--nonet", "--noout", "--schema", str(SCHEMA), "-"],
                                input=ET.tostring(report_input, encoding="utf-8"), capture_output=True, timeout=30)
    if validation.returncode:
        raise ValueError("report_input_schema: " + validation.stderr.decode("utf-8", errors="replace")[:800])
    aliases = [case["file"], *case.get("input_aliases", [])]
    normalized = normalize(report, data, report, exception, aliases)
    known = signature(normalized)
    # Die Multimenge prüft auch Dubletten. Der restliche XML-Baum prüft
    # Phasenreihenfolge, Skip-Verhalten und unbekannte Erweiterungen.
    for step in normalized.findall(".//r:validationStepResult", NS):
        for message in step.findall("r:message", NS):
            step.remove(message)
    known.update({"xml_structure": tree_value(normalized),
                  "report_input": tree_value(normalize(report_input, data, report, exception, aliases)),
                  "html": tree_value(normalize(html, data, report, exception, aliases), True)})
    return known


def compare_pair(java, native, case, data):
    """Unabhängige Validierung und fachliche Feldnamen für jede Abweichung liefern."""
    values, issues = {}, []
    for engine, bundle in (("java", java), ("native", native)):
        try:
            values[engine] = snapshot(bundle, case, data, engine)
        except (ValueError, OSError, subprocess.TimeoutExpired) as error:
            issues.append(engine + "." + str(error))
    if len(values) == 2:
        expected, actual = values["java"], values["native"]
        issues.extend(key for key in expected if expected[key] != actual[key] and key not in ("findings", "schematron_findings"))
        if expected["findings"] != actual["findings"]:
            issues.append("findings.multiset")
            for index, field in enumerate(("phase", "code", "level", "location", "text", "attributes")):
                if Counter(finding[index] for finding in expected["findings"]) != Counter(finding[index] for finding in actual["findings"]):
                    issues.append("findings." + field)
    return issues


def counterchecks(java, native, case, data):
    """Jede Mutation beginnt mit einem unveränderten gültigen Paar im Speicher."""
    if compare_pair(java, native, case, data) or not native["report"].findall(".//r:message", NS):
        return {}

    def message(bundle):
        return bundle["report"].find(".//r:message", NS)

    def remove_finding(bundle):
        for step in bundle["report"].findall(".//r:validationStepResult", NS):
            if step.find("r:message", NS) is not None:
                step.remove(step.find("r:message", NS))
                return

    def add_finding(bundle):
        item = deepcopy(message(bundle))
        item.set("code", "countercheck-added")
        bundle["report"].find(".//r:validationStepResult", NS).append(item)

    def assessment(bundle):
        branch = bundle["report"].find("r:assessment/*", NS)
        branch.tag = f"{{{NS['r']}}}" + ("reject" if branch.tag.endswith("accept") else "accept")

    probes = {
        "acceptance": assessment,
        "status": lambda bundle: bundle["public"].update(status="changed"),
        "validity": lambda bundle: bundle["report"].set("valid", "false" if bundle["report"].get("valid") == "true" else "true"),
        "finding_removed": remove_finding,
        "finding_added": add_finding,
        "finding_duplicated": lambda bundle: next(step for step in bundle["report"].findall(".//r:validationStepResult", NS) if step.find("r:message", NS) is not None).append(deepcopy(message(bundle))),
        "finding_code": lambda bundle: message(bundle).set("code", "countercheck-code"),
        "finding_level": lambda bundle: message(bundle).set("level", "countercheck-level"),
        "finding_location": lambda bundle: message(bundle).set("xpathLocation", "/countercheck"),
        "finding_text": lambda bundle: setattr(message(bundle), "text", "countercheck-text"),
        "phase": lambda bundle: bundle["report"].find(".//r:validationStepResult", NS).set("id", "countercheck-phase"),
        "structure": lambda bundle: bundle["report"].remove(bundle["report"].find("r:assessment", NS)),
        "hash": lambda bundle: setattr(bundle["report"].find("r:documentIdentification/r:documentHash/r:hashValue", NS), "text", base64.b64encode(bytes(32)).decode()),
        "report_input_hash": lambda bundle: setattr(bundle["report_input"].find("i:documentIdentification/i:documentHash/i:hashValue", NS), "text", base64.b64encode(bytes(32)).decode()),
        "report_input_schema": lambda bundle: bundle["report_input"].set("countercheck", "invalid"),
        "html": lambda bundle: bundle["html"].find("h:body", NS).clear(),
    }
    results = {}
    for name, mutation in probes.items():
        altered = deepcopy(native)
        mutation(altered)
        results[name] = bool(compare_pair(java, altered, case, data))
    altered = deepcopy(native)
    altered["report"].find("r:timestamp", NS).text = "2030-01-01T00:00:00Z"
    results["allowed_timestamp"] = not compare_pair(java, altered, case, data)
    return results


def load_bundle(directory, name, public=None):
    """Fehlende Artefakte und ungültiges HTML sind harte Vergleichsfehler."""
    return {"report": ET.parse(directory / (name + "-report.xml")).getroot(),
            "report_input": ET.parse(directory / (name + "-reportInput.xml")).getroot(),
            "html": HtmlParser().parse((directory / (name + "-report.html")).read_text(encoding="utf-8-sig")),
            "public": public or {}}


def verify(directory, native_directory="native"):
    """Ein fehlender Bericht, Befund oder falscher Prüfentscheid lässt den Lauf fehlschlagen."""
    directory = Path(directory)
    results, errors, probes = [], [], {}
    try:
        manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8-sig"))
        cases = manifest["cases"]
        if not isinstance(cases, list) or not cases:
            raise ValueError("empty_manifest")
        names = [case["name"] for case in cases]
        if len(set(name.casefold() for name in names)) != len(names) or any(Path(name).name != name or "\\" in name or name in (".", "..") for name in names):
            raise ValueError("invalid_case_names")
        public_results = json.loads((directory / native_directory / "results.json").read_text(encoding="utf-8-sig"))
        if not isinstance(public_results, list):
            raise ValueError("public_results.array_required")
        public = {}
        for result in public_results:
            name = reference_name(result["input"])
            if name in public:
                raise ValueError("duplicate_public_results")
            public[name] = result
        for case in cases:
            name, differences = case["name"], []
            audit = {}
            try:
                input_path = Path(case["file"])
                if not input_path.is_absolute():
                    input_path = directory / input_path
                data = input_path.read_bytes()
                if case.get("sha256", "").lower() != hashlib.sha256(data).hexdigest():
                    raise ValueError("manifest.input_hash")
                java = load_bundle(directory / "java", name)
                native = load_bundle(directory / native_directory, name, public.get(input_path.name))
                audit = {"input_sha256": hashlib.sha256(data).hexdigest(), "input_bytes": len(data),
                         "java_input_hash": signature(java["report"])["hash"],
                         "native_input_hash": signature(native["report"])["hash"],
                         "diagnostic_exception": case.get("diagnostic_exception"),
                         "java_hash_exception": case.get("java_hash_exception")}
                differences = compare_pair(java, native, case, data)
                if not differences and not probes:
                    probes = counterchecks(java, native, case, data)
            except (ValueError, OSError, ET.ParseError, KeyError, TypeError) as error:
                differences.append(str(error))
            results.append({"case": name, "passed": not differences, "differences": differences, **audit})
    except (ValueError, OSError, KeyError, TypeError) as error:
        errors.append(str(error))
    if not probes or not all(probes.values()):
        errors.append("required_counterchecks_missing_or_failed")
    evidence = {"checked_at": datetime.now(timezone.utc).isoformat(), "cases": results,
                "passed": sum(case["passed"] for case in results), "total": len(results), "errors": errors,
                "counterchecks": probes, "missing_finding_countercheck": probes.get("finding_removed"),
                "diagnostic_exceptions": DIAGNOSTIC_EXCEPTIONS}
    serialized = json.dumps(evidence, ensure_ascii=False, indent=2)
    (directory / "comparison.json").write_text(serialized, encoding="utf-8")
    # Getrennte Compilerläufe behalten ihren eigenen Nachweis beim jeweiligen Ergebnisbestand.
    if (directory / native_directory).is_dir():
        (directory / native_directory / "comparison.json").write_text(serialized, encoding="utf-8")
    print(json.dumps({key: value for key, value in evidence.items() if key not in ("cases", "diagnostic_exceptions")}, ensure_ascii=False))
    for case in results:
        if not case["passed"]:
            print(json.dumps(case, ensure_ascii=False))
    return 0 if results and not errors and evidence["passed"] == evidence["total"] else 1


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        raise SystemExit("Aufruf: compare_reports.py Laufverzeichnis [Delphi-Unterverzeichnis]")
    raise SystemExit(verify(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) == 3 else "native"))
