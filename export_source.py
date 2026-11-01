"""Exportiert ausschließlich versionierbare Projektdateien ohne Git-Historie."""

import argparse
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parent
SOURCE_DIRECTORIES = {"Source", "Examples", "Tests", "ThirdParty", "docs"}
GENERATED_DIRECTORIES = {"build", "obj", "__pycache__", ".git"}
GENERATED_SUFFIXES = {
    ".exe", ".dll", ".dcu", ".dcp", ".bpl", ".bpi", ".obj", ".o", ".lib", ".a", ".res",
    ".pdb", ".map", ".tds", ".rsm", ".drc", ".identcache", ".local", ".pyc", ".pyo",
    ".so", ".dylib", ".class", ".jar", ".zip", ".7z", ".tar", ".gz",
}
ROOT_FILES = {".gitattributes", ".gitignore", "README.md", "LICENSE", "NOTICE", "THIRD_PARTY.md",
              "MGGMXmlValidator.dpr", "MGGMXmlValidator.dproj", "MGGMXmlValidatorBatch.dpr", "MGGMXmlValidatorBatch.dproj", "uKositCli.pas",
              "package_runtime.py", "export_source.py", "compare_reports.py", "compare_benchmark.py", "collect_benchmark.py"}


def validate_source(root, relative):
    """Quellvorfahren und aufgelöste Pfade dürfen keine fremden Dateien einschließen."""
    source = root / relative
    for component in (source, *source.parents):
        if component == root:
            break
        if component.is_symlink():
            raise ValueError("Symbolischer Verweis im Quellpfad: " + str(relative))
    if not source.resolve().is_relative_to(root):
        raise ValueError("Aufgelöste Quelldatei liegt außerhalb des Repository-Verzeichnisses: " + str(relative))
    if source.exists() and not source.is_file():
        raise ValueError("Keine reguläre Quelldatei: " + str(relative))
    return source


def export_source(target):
    """Ein neues Ziel enthält weder Laufzeitpakete noch die übergeordnete Historie."""
    root = ROOT.resolve()
    target = target.resolve()
    if target == root or target.is_relative_to(root):
        raise ValueError("Das Exportziel muss außerhalb des Repository-Verzeichnisses liegen.")
    if target.exists():
        raise ValueError("Das Exportziel existiert bereits: " + str(target))
    listing = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "."],
        cwd=root, check=True, stdout=subprocess.PIPE,
    )
    files = []
    for name in listing.stdout.decode("utf-8").split("\0"):
        if not name:
            continue
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Ungültiger Quellpfad: " + name)
        if any(part.lower() in GENERATED_DIRECTORIES for part in relative.parts):
            continue
        if relative.suffix.lower() in GENERATED_SUFFIXES:
            continue
        if len(relative.parts) == 1 and name not in ROOT_FILES:
            continue
        if len(relative.parts) > 1 and relative.parts[0] not in SOURCE_DIRECTORIES:
            continue
        source = validate_source(root, relative)
        if not source.exists():
            continue
        files.append(relative)
    if not files:
        raise ValueError("Keine Quelldateien für den Export gefunden.")
    target.mkdir(parents=True)
    for relative in files:
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(validate_source(root, relative), destination)
    return len(files)


def main():
    """Der Export erzeugt keinen Remote und führt keinen Push aus."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path)
    args = parser.parse_args()
    try:
        count = export_source(args.target)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")
    print(f"{count} Quelldateien exportiert: {args.target.resolve()}")


if __name__ == "__main__":
    main()
