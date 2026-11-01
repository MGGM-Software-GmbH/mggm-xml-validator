"""Lokaler, versionierter Referenzlauf mit unveränderten Eingabebytes."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import sys
import uuid


FIXTURES = Path(__file__).parent / "Fixtures" / "reference"


def sha256(path):
    """Berechnet die Identität der tatsächlichen Dateibytes."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_json(path):
    """Liest UTF-8-JSON ohne stillschweigende Ersatzwerte."""
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write_json(path, value):
    """Verhindert das Überschreiben bereits vorhandener Laufnachweise."""
    with Path(path).open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def safe_path(root, relative):
    """Beschränkt Manifestpfade auf das jeweilige lokale Wurzelverzeichnis."""
    parsed = PurePosixPath(relative)
    if not relative or parsed.is_absolute() or ".." in parsed.parts or "\\" in relative or ":" in relative:
        raise ValueError(f"Unsicherer Manifestpfad: {relative}")
    target = (Path(root) / relative).resolve()
    if not target.is_relative_to(Path(root).resolve()):
        raise ValueError(f"Pfad außerhalb der Wurzel: {relative}")
    return target


def validate_fixtures(directory):
    """Prüft Fallidentität, Provenienz, Lizenz und unveränderte Originalbytes."""
    directory = Path(directory).resolve()
    manifest = read_json(directory / "fixture-manifest.json")
    cases = manifest.get("cases", [])
    if not cases:
        raise ValueError("Leeres Fixture-Manifest")
    names, filenames = set(), set()
    for case in cases:
        name = case["name"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name):
            raise ValueError(f"Unsicherer Fallname: {name}")
        path = safe_path(directory, case["file"])
        basename = path.name.casefold()
        if name.casefold() in names or basename in filenames:
            raise ValueError(f"Doppelter Fallname oder Dateiname: {name}")
        names.add(name.casefold())
        filenames.add(basename)
        if not path.is_file() or not path.stat().st_size or sha256(path) != case["sha256"]:
            raise ValueError(f"Fixture fehlt, ist leer oder hat anderen SHA-256: {name}")
        expected = case["expected"]
        if expected["status"] not in {"V", "W", "E", "F"}:
            raise ValueError(f"Ungültiger erwarteter Status: {name}")
        for key in ("accepted", "schema_valid", "processing_error", "report_valid"):
            if not isinstance(expected[key], bool):
                raise ValueError(f"Erwartungswert {key} muss boolesch sein: {name}")
        if not isinstance(expected["required_findings"], list):
            raise ValueError(f"Befunderwartungen fehlen: {name}")
        source = case["source"]
        # Lizenzpfade dürfen ausdrücklich auf die gemeinsame Repository-Lizenz verweisen.
        license_path = (directory / source["license_file"]).resolve()
        if not source["license"] or not license_path.is_file() or not license_path.stat().st_size:
            raise ValueError(f"Lizenz fehlt: {name}")
        if sha256(license_path) != source["license_sha256"]:
            raise ValueError(f"Lizenz-SHA-256 abweichend: {name}")
    return manifest


def validate_rules(validation_root, rule_lock):
    """Vergleicht die gesamte Regeldateimenge einschließlich zusätzlicher Dateien."""
    root = Path(validation_root).resolve()
    files = rule_lock["files"]
    if not files or not rule_lock.get("scenarios"):
        raise ValueError("Leerer Regelbestand")
    lock_hash = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if lock_hash != rule_lock["sha256"]:
        raise ValueError("Regelmanifest-SHA-256 stimmt nicht")
    actual = {path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file()}
    if actual != set(files):
        raise ValueError(f"Regeldateimenge abweichend: fehlt={sorted(set(files) - actual)}, zusätzlich={sorted(actual - set(files))}")
    for relative, digest in files.items():
        if sha256(safe_path(root, relative)) != digest:
            raise ValueError(f"Regel-SHA-256 abweichend: {relative}")
    return [str(safe_path(root, relative)) for relative in rule_lock["scenarios"]]


def prepare(run, validation_root, jar, fixtures=FIXTURES):
    """Erzeugt einen neuen Lauf erst nach Prüfung aller Voraussetzungen."""
    run, validation_root, jar, fixtures = [Path(value).resolve() for value in (run, validation_root, jar, fixtures)]
    source = validate_fixtures(fixtures)
    lock = read_json(safe_path(fixtures, source["rule_hashes"]))
    configs = validate_rules(validation_root, lock)
    if sha256(jar) != source["java_validator"]["sha256"]:
        raise ValueError("Java-JAR-SHA-256 abweichend")
    run.mkdir(parents=True, exist_ok=False)
    (run / "input").mkdir()
    cases = []
    for original in source["cases"]:
        case = dict(original)
        target = run / "input" / Path(original["file"]).name
        shutil.copyfile(safe_path(fixtures, original["file"]), target)
        case["file"] = str(target)
        cases.append(case)
    manifest = {
        "format_version": 1, "run_id": run.name + "-" + uuid.uuid4().hex,
        "prepared_at": datetime.now(timezone.utc).isoformat(), "python_version": platform.python_version(),
        "fixture_directory": str(fixtures), "fixture_manifest_sha256": sha256(fixtures / "fixture-manifest.json"),
        "validation_root": str(validation_root), "configs": configs, "rule_hashes": lock,
        "java_validator": dict(source["java_validator"], file=str(jar)), "cases": cases,
        "notes": ["Lokaler JAR-Lauf ohne Maven; alle Regeln und Eingaben sind vor jedem Lauf hashgeprüft."]
    }
    write_json(run / "manifest.json", manifest)
    return manifest


def load_manifest(run):
    """Prüft Voraussetzungen und kopierte Eingaben erneut vor jeder Ausführung."""
    run = Path(run).resolve()
    manifest = read_json(run / "manifest.json")
    fixtures = Path(manifest["fixture_directory"])
    if sha256(fixtures / "fixture-manifest.json") != manifest["fixture_manifest_sha256"]:
        raise ValueError("Fixture-Manifest nach Vorbereitung verändert")
    source = validate_fixtures(fixtures)
    lock = read_json(safe_path(fixtures, source["rule_hashes"]))
    if lock != manifest["rule_hashes"]:
        raise ValueError("Regelmanifest nach Vorbereitung verändert")
    if validate_rules(manifest["validation_root"], lock) != manifest["configs"]:
        raise ValueError("Konfigurationspfade verändert")
    if manifest["java_validator"] != dict(source["java_validator"], file=manifest["java_validator"]["file"]):
        raise ValueError("JAR-Identität im Laufmanifest verändert")
    if sha256(manifest["java_validator"]["file"]) != source["java_validator"]["sha256"]:
        raise ValueError("Java-JAR nach Vorbereitung verändert")
    if len(manifest["cases"]) != len(source["cases"]):
        raise ValueError("Fallmenge im Laufmanifest verändert")
    for case, original in zip(manifest["cases"], source["cases"]):
        target = run / "input" / Path(original["file"]).name
        checked = dict(case)
        aliases = checked.pop("input_aliases", [])
        # Eine getrennte Linux-/Windows-Ausführung kann denselben Eingang unter zwei Pfaden sehen.
        # Diese Transportangabe verändert weder die CLI-Eingabe noch Hash oder fachliche Erwartungen.
        if not isinstance(aliases, list) or any(not isinstance(alias, str) or not alias for alias in aliases):
            raise ValueError(f"Ungültige Eingabepfadzuordnung: {original['name']}")
        if checked != dict(original, file=str(target)) or sha256(target) != original["sha256"]:
            raise ValueError(f"Laufeingabe oder Erwartung verändert: {original['name']}")
    return manifest


def engine_arguments(manifest, output, library):
    """Liefert identische Delphi-Argumente für CLI und dokumentierten Buildzugang."""
    arguments = ["--json", "--html", "--serialize-report-input", "--saxon-library", str(library)]
    for config in manifest["configs"]:
        arguments.extend(["-s", config])
    arguments.extend(["-o", str(output)])
    return arguments + [case["file"] for case in manifest["cases"]]


def record_execution(output, arguments, stdout, stderr, returncode, started_at, metadata=None):
    """Sichert frische Ausgaben auch für fehlgeschlagene oder externe Prozessstarts."""
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    execution = {
        "execution_id": uuid.uuid4().hex, "started_at": started_at,
        "finished_at": datetime.now(timezone.utc).isoformat(), "arguments": arguments,
        "returncode": returncode, "python_version": platform.python_version(), **(metadata or {})
    }
    for filename, content in (("stdout.log", stdout), ("stderr.log", stderr)):
        with (output / filename).open("x", encoding="utf-8") as stream:
            stream.write(content)
    write_json(output / "execution.json", execution)
    if metadata and metadata.get("engine") == "delphi" and returncode is not None:
        results = json.loads(stdout)
        if not isinstance(results, list):
            raise ValueError("Delphi-Standardausgabe enthält kein JSON-Array")
        write_json(output / "results.json", results)
    return execution


def execute(run, engine, executable, library=None, name=None, timeout=300):
    """Startet lokale Prozesse ohne Shell und protokolliert technische Fehler."""
    manifest = load_manifest(run)
    output = Path(run).resolve() / (name or engine)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", output.name) or output.parent != Path(run).resolve():
        raise ValueError("Unsicherer Ausgabename")
    output.mkdir(exist_ok=False)
    started_at = datetime.now(timezone.utc).isoformat()
    metadata = {"engine": engine, "maven_used": False, "timeout_seconds": timeout}
    if engine == "java":
        version = subprocess.run([executable, "-version"], capture_output=True, text=True, timeout=30, check=True)
        metadata["java_version"] = (version.stdout + version.stderr).strip()
        arguments = [executable, "-Djavax.xml.accessExternalDTD=", "-Djavax.xml.accessExternalSchema=file",
                     "-Djavax.xml.accessExternalStylesheet=file", "-jar", manifest["java_validator"]["file"],
                     "-h", "--serialize-report-input", "-o", str(output)]
        for config in manifest["configs"]:
            arguments.extend(["-s", config])
        arguments.extend(case["file"] for case in manifest["cases"])
    else:
        if not library or not Path(library).is_file() or not Path(executable).is_file():
            raise ValueError("Delphi-Programm oder Saxon-Bibliothek fehlt")
        metadata.update(executable_sha256=sha256(executable), library_sha256=sha256(library), library=str(Path(library).resolve()))
        arguments = [str(Path(executable).resolve())] + engine_arguments(manifest, output, Path(library).resolve())
    try:
        result = subprocess.run(arguments, cwd=output, capture_output=True, text=True, encoding="utf-8", errors="strict", timeout=timeout)
    except subprocess.TimeoutExpired as error:
        def decode(value):
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else (value or "")
        record_execution(output, arguments, decode(error.stdout), decode(error.stderr), None, started_at, dict(metadata, timed_out=True))
        raise RuntimeError(f"Prozess-Timeout nach {timeout} Sekunden") from error
    execution = record_execution(output, arguments, result.stdout, result.stderr, result.returncode, started_at, metadata)
    expected = sum(not case["expected"]["accepted"] for case in manifest["cases"])
    if result.returncode != expected:
        raise RuntimeError(f"Unerwarteter Exitcode {result.returncode}, erwartet {expected} Ablehnungen")
    return execution


def main():
    """Stellt Vorbereitung und getrennte lokale Engine-Läufe bereit."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("prepare")
    setup.add_argument("run", type=Path)
    setup.add_argument("--validation-root", type=Path, required=True)
    setup.add_argument("--jar", type=Path, required=True)
    setup.add_argument("--fixtures", type=Path, default=FIXTURES)
    java = commands.add_parser("java")
    java.add_argument("run", type=Path)
    java.add_argument("--java", default="java")
    java.add_argument("--timeout", type=int, default=300)
    native = commands.add_parser("delphi")
    native.add_argument("run", type=Path)
    native.add_argument("--executable", required=True)
    native.add_argument("--library", required=True)
    native.add_argument("--name", default="native")
    native.add_argument("--timeout", type=int, default=300)
    options = parser.parse_args()
    try:
        if options.command == "prepare":
            prepare(options.run, options.validation_root, options.jar, options.fixtures)
        elif options.command == "java":
            execute(options.run, "java", options.java, timeout=options.timeout)
        else:
            execute(options.run, "delphi", options.executable, options.library, options.name, options.timeout)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Referenzlauf fehlgeschlagen: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
