"""Stellt ein eigenständiges Win64-Paket mit SDK-DLL und Regelpaketen zusammen."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parent
DLL_SHA256 = "2a15c4631efa5b45a86b63b0618da32acf5552abf653c36b54f1b2932df94a6c"
SDK_NAME = "SaxonC-HE 12.10.1 Windows x86_64"
SCENARIOS = (
    "validator-configuration-zugferd/scenarios.xml",
    "validator-configuration-zugferd/scenarios_zugferd1.xml",
    "validator-configuration-xrechnung/3.0.2/scenarios.xml",
)
LEGAL_FILES = (
    "ThirdParty/KoSIT/LICENSE", "ThirdParty/KoSIT/NOTICE",
    "ThirdParty/SaxonC/LICENSE.txt", "ThirdParty/SaxonC/JAMESCLARK.txt",
    "ThirdParty/SaxonC/JLINE2.txt", "ThirdParty/SaxonC/SOURCE.md",
    "ThirdParty/Validation/XRechnung-LICENSE", "ThirdParty/Validation/XRechnung-NOTICE",
    "ThirdParty/Validation/EN16931-EUPL.txt", "ThirdParty/Validation/SOURCES.md",
    "LICENSE", "NOTICE", "THIRD_PARTY.md",
)


def digest(path):
    """Hash der tatsächlich kopierten Bytes, unabhängig vom Dateinamen."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_file(path):
    """Fehlende Dateien und symbolische Verweise vor jeder Zieländerung ablehnen."""
    if path.is_symlink() or not path.is_file():
        raise SystemExit("Erforderliche Datei fehlt oder ist ein symbolischer Verweis: " + str(path))


def validate_notice(path):
    """Nur lesbare Hinweis- und Lizenztexte dürfen als Rechtshinweise verteilt werden."""
    name = path.name.upper()
    if (path.suffix.lower() not in (".txt", ".md", ".rst") and name not in ("LICENSE", "NOTICE", "COPYING", "COPYRIGHT", "AUTHORS")
            and not name.endswith(("-LICENSE", "-NOTICE", "-COPYING"))):
        raise SystemExit("Unerwarteter Dateityp einer Hinweisdatei: " + str(path))
    try:
        content = path.read_bytes().decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise SystemExit("Hinweisdatei ist kein UTF-8-Text: " + str(path)) from error
    if any((ord(character) < 32 and character not in "\t\r\n\f") or ord(character) == 127 for character in content):
        raise SystemExit("Hinweisdatei enthält binäre Steuerzeichen: " + str(path))


def add_tree(sources, source, relative, rules=False, notices=False):
    """Regeldateien behalten eingebettete Hinweise; Referenztabellen gehören nicht zur Laufzeit."""
    if source.is_symlink() or not source.is_dir():
        raise SystemExit("Erforderliches Verzeichnis fehlt oder ist ein symbolischer Verweis: " + str(source))
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise SystemExit("Symbolischer Verweis im Paketinhalt: " + str(path))
        if path.is_file():
            if notices:
                validate_notice(path)
            if rules:
                if path.suffix.lower() == ".xlsx":
                    continue
                if path.suffix.lower() not in (".xml", ".xsd", ".xsl", ".xslt", ".sch", ".scmt", ".md") and path.name not in ("LICENSE", "NOTICE"):
                    raise SystemExit("Unerwartete Datei im technischen Regelpaket: " + str(path))
                if path.suffix.lower() == ".xml":
                    try:
                        root_tag = ElementTree.parse(path).getroot().tag.rsplit("}", 1)[-1]
                    except (OSError, ElementTree.ParseError) as error:
                        raise SystemExit("Ungültige XML-Regeldatei: " + str(path)) from error
                    if root_tag not in ("scenarios", "codedb"):
                        raise SystemExit("XML-Datei gehört nicht zu Szenarien oder Codelisten: " + str(path))
            sources[(relative / path.relative_to(source)).as_posix()] = path


def validate_target_path(target, relative):
    """Ein Paket darf weder über Traversal noch über Verweise sein Ziel verlassen."""
    path = Path(relative)
    if (not relative or path.is_absolute() or "\\" in relative or ":" in relative
            or any(part in ("", ".", "..") or part.endswith((" ", ".")) for part in relative.split("/"))):
        raise SystemExit("Ungültiger relativer Paketpfad: " + relative)
    destination = target / path
    for parent in (destination, *destination.parents):
        if parent.is_symlink():
            raise SystemExit("Symbolischer Verweis im Zielpfad: " + str(parent))
    return destination


def previous_files(target):
    """Nur ein gültiges Manifest weist bestehende Dateien als Paketinhalt aus."""
    manifest_path = validate_target_path(target, "manifest.json")
    if not manifest_path.exists():
        return {}
    require_file(manifest_path)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if not isinstance(manifest, dict) or manifest.get("sdk") != SDK_NAME:
            raise ValueError("Datei ist kein Manifest für das geprüfte Laufzeitpaket")
        files = manifest["files"]
        if not isinstance(files, dict):
            raise ValueError("files ist kein Objekt")
        for relative, checksum in files.items():
            validate_target_path(target, relative)
            if (relative == "manifest.json" or not isinstance(checksum, str) or len(checksum) != 64
                    or any(character not in "0123456789abcdef" for character in checksum)):
                raise ValueError("Ungültiger Hash oder Manifestpfad")
        return files
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit("Ungültiges Paketmanifest: " + str(error)) from error


def package(argv=None):
    """Quellen und Zielkonflikte prüfen, dann ausschließlich definierte Paketdateien schreiben."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=ROOT / "build/MGGMXmlValidator.exe")
    parser.add_argument("--batch-executable", type=Path, default=ROOT / "build/MGGMXmlValidatorBatch.exe")
    parser.add_argument("--example-executable", type=Path, default=ROOT / "build/ValidateXmlExample.exe")
    parser.add_argument("--sdk", type=Path, default=ROOT / "Vendor/SaxonC")
    parser.add_argument("--validation-root", type=Path, default=ROOT / "build/Validation")
    parser.add_argument("--target", type=Path, default=ROOT / "build")
    args = parser.parse_args(argv)
    target = args.target.absolute()
    library = args.sdk / "SaxonCCoreHE/bin/saxonc-core-he.dll"
    if not args.executable.is_file():
        raise SystemExit("Gebautes Delphi-Programm fehlt: " + str(args.executable))
    if not args.batch_executable.is_file():
        raise SystemExit("Gebautes Delphi-Batchprogramm fehlt: " + str(args.batch_executable))
    if not args.example_executable.is_file():
        raise SystemExit("Gebautes Delphi-Beispielprogramm fehlt: " + str(args.example_executable))
    if not library.is_file() or digest(library) != DLL_SHA256:
        raise SystemExit("SaxonC-Core-DLL fehlt oder entspricht nicht dem geprüften SDK.")
    notices = args.sdk / "notices"
    for name in ("LICENSE.txt", "JAMESCLARK.txt", "JLINE2.txt"):
        require_file(notices / name)
    for relative in SCENARIOS:
        require_file(args.validation_root / relative)
    require_file(args.validation_root / "validator-configuration-zugferd/LICENSE")
    require_file(args.validation_root / "validator-configuration-xrechnung/3.0.2/README.md")
    for relative in LEGAL_FILES:
        require_file(ROOT / relative)
    sources = {
        "MGGMXmlValidator.exe": args.executable,
        "MGGMXmlValidatorBatch.exe": args.batch_executable,
        "ValidateXmlExample.exe": args.example_executable,
        library.name: library,
        "validate.cmd": ROOT / "Examples/validate.cmd",
    }
    add_tree(sources, notices, Path("Notices/SaxonC/SDK"), notices=True)
    add_tree(sources, ROOT / "ThirdParty", Path("Notices"), notices=True)
    for name in ("LICENSE", "NOTICE", "THIRD_PARTY.md"):
        validate_notice(ROOT / name)
        sources["Notices/" + name] = ROOT / name
    for name in ("validator-configuration-zugferd", "validator-configuration-xrechnung/3.0.2"):
        source = args.validation_root / name
        # Die versionierten Regeln liegen im Standardziel bereits an ihrem Laufzeitpfad.
        # Diese Dateien werden eingefroren und gehasht, ohne Benutzeränderungen zu ersetzen.
        in_place = source.resolve() == (target / "Validation" / name).resolve()
        if not in_place and (target.resolve().is_relative_to(source.resolve()) or source.resolve().is_relative_to(target.resolve())):
            raise SystemExit("Regelquelle und Laufzeitziel dürfen sich nicht überlappen.")
        add_tree(sources, source, Path("Validation") / name, rules=True)
    for source in sources.values():
        require_file(source)
    if target.exists() and not target.is_dir():
        raise SystemExit("Laufzeitziel ist kein Verzeichnis: " + str(target))
    old_files = previous_files(target)
    if set(old_files) - set(sources):
        raise SystemExit("Manifest enthält nicht mehr vorgesehene Paketdateien; Ziel zuerst ausdrücklich bereinigen.")

    # Quellen vor dem ersten Schreibzugriff einfrieren und ihre kopierten Bytes prüfen.
    with tempfile.TemporaryDirectory(prefix="kosit-package-") as temporary:
        stage = Path(temporary)
        files = {}
        for relative, source in sources.items():
            staged = stage / relative
            staged.parent.mkdir(parents=True, exist_ok=True)
            source_hash = digest(source)
            shutil.copy2(source, staged)
            files[relative] = digest(staged)
            if files[relative] != source_hash:
                raise SystemExit("Kopierte Laufzeitdatei stimmt nicht mit ihrer Quelle überein: " + relative)
        if files[library.name] != DLL_SHA256:
            raise SystemExit("SaxonC-Core-DLL wurde während der Paketierung verändert.")
        for relative, checksum in files.items():
            destination = validate_target_path(target, relative)
            for parent in destination.parents:
                if parent.exists() and not parent.is_dir():
                    raise SystemExit("Datei blockiert ein Zielverzeichnis: " + str(parent))
            if destination.exists():
                require_file(destination)
                current = digest(destination)
                if current != checksum and old_files.get(relative) != current:
                    raise SystemExit("Unverwaltete oder veränderte Zieldatei wird nicht überschrieben: " + relative)
        for relative, checksum in files.items():
            destination = target / relative
            if not destination.exists() or digest(destination) != checksum:
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(stage / relative, destination)
            if digest(destination) != checksum:
                raise SystemExit("Zieldatei stimmt nicht mit dem Paket überein: " + relative)
        manifest = {"sdk": SDK_NAME, "scenarios": list(SCENARIOS), "files": files}
        (target / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"directory": str(target), "files": len(files)}, ensure_ascii=False))


if __name__ == "__main__":
    package()
