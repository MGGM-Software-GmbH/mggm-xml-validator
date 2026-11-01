#!/usr/bin/env python3
"""Prüft die Methodenmatrix gegen den unveränderten Originalquellstand."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


SOURCE_COMMIT = "37cddce28e15ac3a0319db006ab21d3f1064ca8c"
MATRIX = Path(__file__).parent / "docs/prp/test-coverage/original-method-matrix.json"
TOKEN = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', re.S)
TEST = re.compile(r"@Test(?:\s*\([^)]*\))?\s*public\s+void\s+(\w+)\s*\([^)]*\)[^{]*\{")


def mask_literals(source: str) -> str:
    """Erhält Positionen und Zeilen, blendet Kommentare und Zeichenketten aus."""
    return TOKEN.sub(lambda match: re.sub(r"[^\n]", " ", match.group()), source)


def inventory(root: Path) -> dict:
    """Inventarisiert JUnit-4-Methoden und prüft unbekannte Testdatenquellen explizit."""
    directory = root / "src/test/java"
    if not directory.is_dir():
        raise ValueError("Originalverzeichnis src/test/java fehlt")
    methods, helpers, classes = [], [], []
    for path in sorted(directory.rglob("*.java")):
        source = path.read_text(encoding="utf-8")
        masked = mask_literals(source)
        relative = path.relative_to(root).as_posix()
        package = re.search(r"\bpackage\s+([\w.]+)\s*;", masked)
        class_match = re.search(r"\bpublic\s+(?:abstract\s+)?class\s+(\w+)(?:\s+extends\s+(\w+))?", masked)
        if not class_match:
            raise ValueError(f"Keine öffentliche Hauptklasse: {relative}")
        class_name = package[1] + "." + class_match[1]
        parent = class_match[2]
        classes.append({"class": class_name, "extends": parent, "file": relative})
        unsupported = re.findall(r"@(RunWith|Parameters|ParameterizedTest|DataProvider|UseDataProvider|TestFactory|RepeatedTest)\b", masked)
        if unsupported:
            raise ValueError(f"Nicht inventarisierte Testdatenquelle {relative}: {unsupported}")
        matches = list(TEST.finditer(masked))
        if len(matches) != len(re.findall(r"@Test\b", masked)):
            raise ValueError(f"Testannotation ohne inventarisierte Methode: {relative}")
        for match in matches:
            depth, end = 1, match.end()
            while depth and end < len(masked):
                depth += (masked[end] == "{") - (masked[end] == "}")
                end += 1
            if depth:
                raise ValueError(f"Nicht abgeschlossene Methode: {relative}:{match[1]}")
            declaration = re.search(r"public\s+void", masked[match.start():match.end()])
            declaration_start = match.start() + declaration.start()
            methods.append({
                "commit": SOURCE_COMMIT,
                "file": relative,
                "class": class_name,
                "method": match[1],
                "line": source.count("\n", 0, declaration_start) + 1,
                "annotation_line": source.count("\n", 0, match.start()) + 1,
                "body_sha256": hashlib.sha256(source[match.start():end].encode()).hexdigest(),
                "file_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            })
        if not matches:
            helpers.append(relative)
    by_simple = {entry["class"].split(".")[-1]: entry for entry in classes}
    for entry in classes:
        parent = entry["extends"]
        while parent:
            if parent not in by_simple:
                raise ValueError(f"Unbekannte Basisklasse {parent}")
            ancestor = by_simple[parent]
            inherited = [method for method in methods if method["class"] == ancestor["class"]]
            if inherited:
                raise ValueError(f"Geerbte Testmethoden benötigen eigene Ausführungszuordnung: {entry['class']}")
            parent = ancestor["extends"]
    files = {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
             for directory in (root / "src/test/java", root / "src/test/resources")
             for path in sorted(directory.rglob("*")) if path.is_file()}
    return {"methods": methods, "helpers": helpers, "classes": classes, "files": files}


def verify(root: Path, matrix: dict, check_commit: bool = True) -> dict:
    """Verlangt eine eindeutige begründete Zuordnung für jede gefundene Methode."""
    if check_commit and (root / ".git").exists():
        commit = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
        if commit != SOURCE_COMMIT:
            raise ValueError(f"Falscher Originalcommit: {commit}")
    actual = inventory(root)
    if matrix.get("source_commit") != SOURCE_COMMIT:
        raise ValueError("Falscher Matrixcommit")
    identity = lambda source: (source["file"], source["class"], source["method"])
    expected = {identity(source): source for source in actual["methods"]}
    rows = matrix.get("methods", [])
    mapped = {identity(row["source"]): row for row in rows}
    if len(mapped) != len(rows):
        raise ValueError("Doppelte Methoden in der Matrix")
    if set(expected) != set(mapped):
        raise ValueError(f"Abweichende Methoden: fehlend={sorted(set(expected)-set(mapped))}, zusätzlich={sorted(set(mapped)-set(expected))}")
    counts = {name: 0 for name in ("covered", "new", "not_relevant")}
    for key, source in expected.items():
        row = mapped[key]
        if row["source"] != source:
            raise ValueError(f"Geänderte Originalmethode oder Fundstelle: {key}")
        if row.get("classification") not in counts:
            raise ValueError(f"Unzulässige Klassifikation: {key}")
        counts[row["classification"]] += 1
        if not row.get("contract") or not row.get("variants") or not row.get("reason") or not row.get("target"):
            raise ValueError(f"Unbegründete Zuordnung: {key}")
        if row["classification"] == "covered" and not row.get("evidence"):
            raise ValueError(f"Abdeckung ohne Nachweis: {key}")
        if row["classification"] == "covered" and not any(
            evidence.get("kind") != "pending" and evidence.get("run_id")
            and (evidence.get("exit_code") == 0 or evidence.get("passed") is True)
            for evidence in row.get("evidence", [])
        ):
            raise ValueError(f"Abdeckung ohne erfolgreichen Laufnachweis: {key}")
    if matrix.get("helpers") != actual["helpers"] or matrix.get("classes") != actual["classes"]:
        raise ValueError("Hilfsdateien oder Vererbungsinventar weichen ab")
    if matrix.get("files") != actual["files"]:
        raise ValueError("Java-Hilfsquellen oder Testdatenquellen weichen vom inventarisierten Quellstand ab")
    return {"methods": len(rows), "test_classes": len({source["class"] for source in actual["methods"]}), "classifications": counts, "helper_files": len(actual["helpers"])}


def main() -> int:
    """Gibt eine kompakte Prüfausgabe aus; fehlende Quellen sind ein Fehler."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("upstream_root", type=Path)
    parser.add_argument("--matrix", type=Path, default=MATRIX)
    arguments = parser.parse_args()
    try:
        result = verify(arguments.upstream_root, json.loads(arguments.matrix.read_text(encoding="utf-8")))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"FEHLER: {error}")
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
