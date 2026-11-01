"""Führt abgeschlossene Java-Einzelmessungen ohne Hochrechnung zusammen."""

import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import shutil
import sys

from compare_benchmark import verify_inputs


def read_json(path):
    """Windows- und Linux-Nachweise einschließlich optionaler UTF-8-BOM lesen."""
    with path.open(encoding="utf-8-sig") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"JSON-Objekt erwartet: {path}")
    return value


def finite_duration(value, field, process_path):
    """Zeitwerte dürfen weder boolesch, negativ noch nicht endlich sein."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError(f"Ungültiger Zeitwert {field} in {process_path}: {value!r}")
    return value


def process_identity(process, process_path):
    """Nur Eingabename und Ausgabepfad sind zwischen identischen Java-Einzelaufrufen variabel."""
    for field in ("executable", "working_directory"):
        if not isinstance(process.get(field), str) or not process[field].strip():
            raise ValueError(f"{field} fehlt oder ist ungültig: {process_path}")
    arguments = process.get("arguments")
    if not isinstance(arguments, list) or not arguments or any(not isinstance(argument, str) for argument in arguments):
        raise ValueError(f"Ungültige Prozessargumente: {process_path}")
    if arguments.count("-o") != 1:
        raise ValueError(f"Genau eine -o-Ausgabeoption erforderlich: {process_path}")
    output_index = arguments.index("-o") + 1
    if output_index >= len(arguments) - 1 or not arguments[output_index].strip() or arguments[output_index].startswith("-"):
        raise ValueError(f"Ausgabepfad oder abschließende Eingabe fehlt: {process_path}")
    options = arguments[:-1].copy()
    options[output_index] = "<Ausgabepfad>"
    return {"executable": process["executable"], "working_directory": process["working_directory"], "arguments": options}


def validate_manifest(manifest):
    """Die erwartete Dateimenge muss eindeutig sein und sichere direkte Dateinamen enthalten."""
    cases = manifest.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ValueError("Manifest enthält keine Eingaben")
    names = set()
    for case in cases:
        name = case["name"]
        if not isinstance(name, str) or Path(name).name != name or "\\" in name or Path(name).suffix.lower() != ".xml":
            raise ValueError(f"Ungültiger XML-Dateiname im Manifest: {name!r}")
        if name.casefold() in names:
            raise ValueError(f"Doppelter Eingabename im Manifest: {name}")
        names.add(name.casefold())
        digest = case["sha256"]
        if not isinstance(digest, str) or len(digest) != 64 or len(bytes.fromhex(digest)) != 32:
            raise ValueError(f"Ungültiger SHA-256 im Manifest: {name}")
        size = case["size"]
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise ValueError(f"Ungültige Dateigröße im Manifest: {name}")
    return {case["name"]: case for case in cases}


def collect(manifest_path, output_directory, source_directories):
    """Erst sämtliche Voraussetzungen prüfen, danach einen neuen Ergebnisordner anlegen."""
    manifest_path = Path(manifest_path).resolve()
    output_directory = Path(output_directory)
    if output_directory.exists() or output_directory.is_symlink():
        raise ValueError(f"Ausgabeziel existiert bereits: {output_directory}")
    manifest = read_json(manifest_path)
    expected = validate_manifest(manifest)
    source_directories = [Path(directory).resolve() for directory in source_directories]
    if not source_directories or len(set(source_directories)) != len(source_directories):
        raise ValueError("Quellverzeichnisse fehlen oder sind doppelt angegeben")
    completed = {}
    excluded = []
    report_files = []
    source_runs = []
    identity = None
    for source in source_directories:
        if not source.is_dir():
            raise ValueError(f"Quellverzeichnis fehlt: {source}")
        source_names = set()
        process_directories = sorted(source.glob("process-*"))
        if not process_directories:
            raise ValueError(f"Keine Prozessnachweise im Quellverzeichnis: {source}")
        for process_directory in process_directories:
            if not process_directory.is_dir() or not process_directory.name.removeprefix("process-").isdigit():
                raise ValueError(f"Ungültiger Prozessordner: {process_directory}")
            process_path = process_directory / "process.json"
            if not process_path.exists():
                excluded.append({"source_run_directory": str(source), "process_directory": str(process_directory),
                                 "reason": "process.json fehlt; Prozess nicht abgeschlossen",
                                 "artifacts": [str(path) for path in sorted(process_directory.rglob("*")) if path.is_file()]})
                continue
            process = read_json(process_path)
            actual_identity = process_identity(process, process_path)
            if identity is None:
                identity = actual_identity
            elif actual_identity != identity:
                changed = [field for field in identity if identity[field] != actual_identity[field]]
                raise ValueError(f"Abweichendes Programm, Arbeitsverzeichnis oder Prüfoptionen ({', '.join(changed)}): {process_path}")
            name = process["arguments"][-1]
            if name not in expected:
                raise ValueError(f"Unbekannte Eingabe {name!r}: {process_path}")
            if name in completed:
                raise ValueError(f"Doppelte abgeschlossene Messung für {name}: {completed[name]['source_process_json']} und {process_path}")
            exit_code = process.get("exit_code")
            if isinstance(exit_code, bool) or not isinstance(exit_code, int) or exit_code not in (0, 1):
                raise ValueError(f"Ungültiger Kindprozess-Exitcode {exit_code!r}: {process_path}")
            for field in ("wall_ms", "cpu_user_ms", "cpu_kernel_ms"):
                finite_duration(process.get(field), field, process_path)
            for extension in ("xml", "html"):
                report_name = Path(name).stem + "-report." + extension
                report = source / "reports" / report_name
                if not report.is_file() or report.stat().st_size == 0:
                    raise ValueError(f"Report fehlt oder ist leer: {report}")
                report_files.append((report, report_name))
                source_names.add(report_name)
            original = dict(process)
            original.update({"input": name, "source_run_directory": str(source), "source_process_json": str(process_path)})
            completed[name] = original
        reports_directory = source / "reports"
        found = {str(path.relative_to(reports_directory)) for path in reports_directory.rglob("*")
                 if path.is_file() and path.suffix.lower() in (".xml", ".html")} if reports_directory.is_dir() else set()
        unexpected = found - source_names
        if unexpected:
            raise ValueError(f"Berichte ohne abgeschlossenen Prozess in {source}: {', '.join(sorted(unexpected))}")
        source_measurement = source / "measurement.json"
        source_runs.append({"directory": str(source), "measurement_json": str(source_measurement) if source_measurement.is_file() else None})
    missing = set(expected) - completed.keys()
    if missing:
        raise ValueError("Abgeschlossene Messungen fehlen für: " + ", ".join(sorted(missing)))
    input_verification = verify_inputs(manifest)
    if not input_verification["passed"]:
        raise ValueError("Originaleingaben weichen vom Manifest ab: " + json.dumps(input_verification["differences"], ensure_ascii=False))
    # Die Einzelwerte bleiben nachvollziehbar; MCP-Pausen und abgebrochene Prozesse haben keinen Anteil an den Summen.
    ordered_processes = [completed[case["name"]] for case in manifest["cases"]]
    totals = {field: math.fsum(process[field] for process in ordered_processes) for field in ("wall_ms", "cpu_user_ms", "cpu_kernel_ms")}
    for field, value in totals.items():
        finite_duration(value, field, manifest_path)
    measurement = {
        "mode": "java-per-file",
        "manifest": str(manifest_path),
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "input_directory": identity["working_directory"],
        "verified_input_directory": input_verification["directory"],
        "file_count": len(expected),
        "input_file_count": len(expected),
        "process_count": len(ordered_processes),
        "process_wall_ms": totals["wall_ms"],
        "cpu_user_ms": totals["cpu_user_ms"],
        "cpu_kernel_ms": totals["cpu_kernel_ms"],
        "measurement_scope": "Summe der abgeschlossenen Kindprozesse; keine Gesamt-Walltime einschließlich MCP-Pausen",
        "process_identity": identity,
        "source_runs": source_runs,
        "excluded_processes": excluded,
        "processes": ordered_processes,
    }
    serialized = json.dumps(measurement, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    output_directory.mkdir()
    reports_output = output_directory / "reports"
    reports_output.mkdir()
    for source_report, report_name in report_files:
        with source_report.open("rb") as source_stream, (reports_output / report_name).open("xb") as output_stream:
            shutil.copyfileobj(source_stream, output_stream)
    with (output_directory / "measurement.json").open("x", encoding="utf-8") as stream:
        stream.write(serialized)
    return measurement


def main(argv=None):
    """Eine fehlerhafte oder unvollständige Sammlung erzeugt vor der Ausgabe einen Fehlerstatus."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("source_directories", nargs="+", type=Path)
    arguments = parser.parse_args(argv)
    try:
        result = collect(arguments.manifest, arguments.output_directory, arguments.source_directories)
    except (OSError, ValueError, KeyError, TypeError, OverflowError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps({key: result[key] for key in ("mode", "process_count", "process_wall_ms", "cpu_user_ms", "cpu_kernel_ms")}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
