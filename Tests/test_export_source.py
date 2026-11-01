"""Prüft den isolierten Quelleexport ohne Builddateien oder Git-Historie."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import export_source


class SourceExportTests(unittest.TestCase):
    """Eine kleine Git-Dateiliste bildet erlaubte und erzeugte Dateien nach."""

    def setUp(self):
        """Nur temporäre Testdaten werden verändert."""
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "source"
        self.target = self.root.parent / "export"
        self.root.mkdir()
        self.addCleanup(patch.stopall)
        patch.object(export_source, "ROOT", self.root).start()

    def listing(self, names):
        """Die Dateiliste ersetzt ausschließlich den lokalen Git-Leseaufruf."""
        return patch.object(export_source.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "\0".join(names).encode()))

    def test_only_source_files_are_copied_byte_identically(self):
        """Binärbytes und erlaubte Unterordner bleiben erhalten; Buildordner fehlen."""
        projects = ["MGGMXmlValidator.dpr", "MGGMXmlValidator.dproj", "MGGMXmlValidatorBatch.dpr", "MGGMXmlValidatorBatch.dproj"]
        names = ["README.md", "Source/schema.xsd", "Tests/build/Test.exe", "build/App.exe", "Evidence/result.json", "App.exe", *projects]
        for name in names:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture\r\n")
        with self.listing(names):
            self.assertEqual(export_source.export_source(self.target), 6)
        for project in projects:
            self.assertEqual((self.target / project).read_bytes(), b"fixture\r\n")
        self.assertEqual((self.target / "Source/schema.xsd").read_bytes(), b"fixture\r\n")
        self.assertFalse((self.target / "build").exists())
        self.assertFalse((self.target / "Tests/build").exists())
        self.assertFalse((self.target / "Evidence").exists())
        self.assertFalse((self.target / "App.exe").exists())
        self.assertFalse((self.target / ".git").exists())

    def test_existing_target_and_nested_target_are_rejected(self):
        """Vorhandene Dateien und das Arbeitsverzeichnis dürfen nicht überschrieben werden."""
        self.target.mkdir()
        for target in [self.target, self.root, self.root / "nested"]:
            with self.subTest(target=target), self.assertRaises(ValueError):
                export_source.export_source(target)

    def test_path_traversal_is_rejected_before_creating_target(self):
        """Ein unzulässiger Listeneintrag darf nicht außerhalb der Quelle lesen."""
        with self.listing(["../outside.txt"]), self.assertRaisesRegex(ValueError, "Ungültiger Quellpfad"):
            export_source.export_source(self.target)
        self.assertFalse(self.target.exists())

    def test_build_artifacts_beside_sources_are_excluded(self):
        """Compiler- und Laufzeitdateien bleiben auch außerhalb von Buildordnern ausgeschlossen."""
        names = ["README.md"]
        for suffix in (".exe", ".DLL", ".dcu", ".dcp", ".bpl", ".obj", ".o", ".lib", ".a", ".res", ".pdb", ".map", ".tds", ".rsm", ".pyc", ".so", ".dylib", ".jar", ".zip"):
            names.append("Source/generated" + suffix)
            names.append("Tests/generated" + suffix)
        for name in names:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"build-fixture")
        with self.listing(names):
            self.assertEqual(export_source.export_source(self.target), 1)
        self.assertEqual([path.name for path in self.target.rglob("*") if path.is_file()], ["README.md"])

    def test_linked_source_ancestor_outside_root_is_rejected(self):
        """Ein indexierter Unterpfad darf nach einem Verzeichnislink keine externen Daten exportieren."""
        outside = self.root.parent / "outside"
        outside.mkdir()
        (outside / "history.txt").write_bytes(b"outside-fixture")
        (self.root / "Source").mkdir()
        (self.root / "Source/linked").symlink_to(outside, target_is_directory=True)
        with self.listing(["Source/linked/history.txt"]), self.assertRaisesRegex(ValueError, "Verweis|Repository"):
            export_source.export_source(self.target)
        self.assertFalse(self.target.exists())

    def test_linked_source_ancestor_inside_root_is_rejected(self):
        """Auch interne Verzeichnislinks sind keine eigenständigen versionierbaren Quelldateien."""
        actual = self.root / "Source/actual"
        actual.mkdir(parents=True)
        (actual / "unit.pas").write_bytes(b"unit-fixture")
        (self.root / "Source/linked").symlink_to(actual, target_is_directory=True)
        with self.listing(["Source/linked/unit.pas"]), self.assertRaisesRegex(ValueError, "Verweis"):
            export_source.export_source(self.target)
        self.assertFalse(self.target.exists())

    def test_resolved_source_outside_root_is_rejected(self):
        """Die aufgelöste Quelle muss unabhängig von der Verweiserkennung im Repository liegen."""
        source = self.root / "Source/unit.pas"
        source.parent.mkdir()
        source.write_bytes(b"source-fixture")
        original_resolve = Path.resolve

        def resolved_path(path, *arguments, **keywords):
            """Simuliert einen extern aufgelösten Pfad, etwa bei einem Verzeichnisübergang."""
            if path == source:
                return self.root.parent / "outside/unit.pas"
            return original_resolve(path, *arguments, **keywords)

        with self.listing(["Source/unit.pas"]), patch.object(Path, "resolve", resolved_path):
            with self.assertRaisesRegex(ValueError, "Repository"):
                export_source.export_source(self.target)
        self.assertFalse(self.target.exists())

    def test_git_index_with_ignored_linked_ancestor_is_rejected(self):
        """Eine echte Git-Dateiliste darf indexierte Pfade nicht durch einen ignorierten Link verfolgen."""
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        directory = self.root / "Source/linked"
        directory.mkdir(parents=True)
        (directory / "unit.pas").write_bytes(b"tracked-fixture")
        subprocess.run(["git", "-C", str(self.root), "add", "--", "Source/linked/unit.pas"], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        directory.rename(self.root / "original")
        outside = self.root.parent / "outside"
        outside.mkdir()
        (outside / "unit.pas").write_bytes(b"external-fixture")
        directory.symlink_to(outside, target_is_directory=True)
        (self.root / ".gitignore").write_text("Source/linked\noriginal/\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Verweis"):
            export_source.export_source(self.target)
        self.assertFalse(self.target.exists())


if __name__ == "__main__":
    unittest.main()
