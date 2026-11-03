"""Prüft den PowerShell-Downloader mit isolierten ZIPs ohne Herstellerzugriff."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
POWERSHELL = shutil.which("pwsh") or shutil.which("powershell.exe")
LIBRARY = b"SaxonC-library-fixture"
NOTICES = {
    "LICENSE.txt": b"license-fixture\r\n",
    "JAMESCLARK.txt": b"james-clark-fixture\r\n",
    "JLINE2.txt": b"jline-fixture\r\n",
}


def ps_literal(value):
    """Pfade und Hashes als PowerShell-Stringliteral übergeben."""
    return "'" + str(value).replace("'", "''") + "'"


@unittest.skipUnless(POWERSHELL, "PowerShell ist für die Downloader-Ausführung erforderlich")
class SaxonDownloadTests(unittest.TestCase):
    """Gültige Inhalte und jede Abbruchursache im echten Helper ausführen."""

    def setUp(self):
        """Herstellerstruktur durch ein kleines isoliertes Archiv ersetzen."""
        self.temporary = tempfile.TemporaryDirectory(prefix="saxon download tests ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repository with spaces"
        self.repository.mkdir()
        self.helper = self.repository / "download-saxon.ps1"
        shutil.copyfile(ROOT / "download-saxon.ps1", self.helper)
        self.archive = self.root / "fixture.zip"
        self.write_archive()
        self.archive_hash = self.hash_file(self.archive)
        self.library_hash = hashlib.sha256(LIBRARY).hexdigest()
        self.target = self.repository / "build"

    @staticmethod
    def hash_file(path):
        """Fixture-Hashes unabhängig vom getesteten PowerShell-Code berechnen."""
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def write_archive(self, missing=None):
        """Nur ausgewählte Dateien dürfen aus diesem Archiv installiert werden."""
        entries = {"SaxonCCoreHE/bin/saxonc-core-he.dll": LIBRARY}
        entries.update({f"notices/{name}": content for name, content in NOTICES.items()})
        entries["../../outside.txt"] = b"must-never-be-extracted"
        entries["SaxonCCoreHE/bin/unrelated.exe"] = b"must-never-be-installed"
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name, content in entries.items():
                if name != missing:
                    archive.writestr(name, content)

    def run_download(self, destination="build", download_failure=False):
        """Nur die Transportfunktion im Test ersetzen; produktive Parameter bleiben fest."""
        transport = (
            "throw 'Simulierter Downloadfehler'"
            if download_failure
            else f"[IO.File]::Copy({ps_literal(self.archive)}, $Path, $false)"
        )
        harness = self.root / "invoke.ps1"
        harness.write_text(
            f". {ps_literal(self.helper)}\n"
            f"$SaxonArchiveHash = {ps_literal(self.archive_hash)}\n"
            f"$SaxonLibraryHash = {ps_literal(self.library_hash)}\n"
            "function Receive-SaxonArchive { param([string]$Path) " + transport + " }\n"
            "try { Invoke-SaxonDownload " + ps_literal(destination) + " }\n"
            "catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }\n",
            encoding="utf-8-sig",
        )
        temp_root = self.root / "temporary downloads"
        temp_root.mkdir(exist_ok=True)
        environment = dict(os.environ)
        environment.update(TMPDIR=str(temp_root), TEMP=str(temp_root), TMP=str(temp_root))
        result = subprocess.run(
            [POWERSHELL, "-NoLogo", "-NoProfile", "-File", str(harness)],
            cwd=self.root,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(list(temp_root.iterdir()), [], result.stderr)
        return result

    def test_success_default_target_foreign_cwd_and_idempotence(self):
        """Standardziel, Leerzeichen, selektive Kopie und Wiederholung zusammen prüfen."""
        for _ in range(2):
            result = self.run_download()
            self.assertEqual(result.returncode, 0, result.stderr)
        expected = {"saxonc-core-he.dll": LIBRARY}
        expected.update({f"Notices/SaxonC/SDK/{name}": content for name, content in NOTICES.items()})
        actual = {path.relative_to(self.target).as_posix(): path.read_bytes()
                  for path in self.target.rglob("*") if path.is_file()}
        self.assertEqual(actual, expected)
        self.assertFalse((self.root / "outside.txt").exists())

    def test_explicit_relative_and_absolute_target(self):
        """Beide Zielformen funktionieren unabhängig vom Arbeitsverzeichnis."""
        for destination in ("build/Delphi13", str(self.root / "absolute target")):
            result = self.run_download(destination)
            self.assertEqual(result.returncode, 0, result.stderr)
            target = Path(destination)
            if not target.is_absolute():
                target = self.repository / target
            self.assertEqual((target / "saxonc-core-he.dll").read_bytes(), LIBRARY)

    def test_archive_and_library_hash_failure_write_no_targets(self):
        """Beide unabhängigen Hashkontrollen müssen falsche Inhalte zurückweisen."""
        for attribute in ("archive_hash", "library_hash"):
            with self.subTest(attribute=attribute):
                previous = getattr(self, attribute)
                setattr(self, attribute, "0" * 64)
                result = self.run_download()
                setattr(self, attribute, previous)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SHA256", result.stderr)
                self.assertFalse(self.target.exists())

    def test_download_failure_writes_no_targets(self):
        """Ein Transportfehler bleibt ein sichtbarer Fehler ohne Installationsreste."""
        result = self.run_download(download_failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Downloadfehler", result.stderr)
        self.assertFalse(self.target.exists())

    def test_missing_notice_writes_no_targets(self):
        """Auch fehlende Originalhinweise verhindern die DLL-Installation."""
        self.write_archive(missing="notices/JLINE2.txt")
        self.archive_hash = self.hash_file(self.archive)
        result = self.run_download()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("JLINE2.txt", result.stderr)
        self.assertFalse(self.target.exists())

    def test_invalid_zip_and_duplicate_library_write_no_targets(self):
        """Ungültige Archive und mehrdeutige DLL-Einträge dürfen nicht installieren."""
        self.archive.write_bytes(b"not-a-zip")
        self.archive_hash = self.hash_file(self.archive)
        result = self.run_download()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.target.exists())
        self.write_archive()
        with zipfile.ZipFile(self.archive, "a") as archive:
            with self.assertWarns(UserWarning):
                archive.writestr("SaxonCCoreHE/bin/saxonc-core-he.dll", b"different-library")
        self.archive_hash = self.hash_file(self.archive)
        result = self.run_download()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("saxonc-core-he.dll", result.stderr)
        self.assertFalse(self.target.exists())

    def test_additional_argument_is_rejected_before_download(self):
        """Der öffentliche Aufruf erlaubt genau ein optionales Zielverzeichnis."""
        result = subprocess.run(
            [POWERSHELL, "-NoLogo", "-NoProfile", "-File", str(self.helper), "build", "extra"],
            cwd=self.root, capture_output=True, text=True, timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.target.exists())

    def test_linked_target_is_rejected(self):
        """Ein verknüpftes Ziel darf keine außerhalb liegenden Dateien erhalten."""
        outside = self.root / "outside target"
        outside.mkdir()
        try:
            self.target.symlink_to(outside, target_is_directory=True)
        except OSError as error:
            self.skipTest(f"Symbolische Verknüpfung nicht verfügbar: {error}")
        result = self.run_download()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(outside.iterdir()), [])

    def test_conflicting_file_is_preserved_before_any_copy(self):
        """Ein Hinweis-Konflikt verhindert auch das vorgezogene Schreiben der DLL."""
        conflict = self.target / "Notices/SaxonC/SDK/JLINE2.txt"
        conflict.parent.mkdir(parents=True)
        conflict.write_bytes(b"user-content")
        result = self.run_download()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(conflict.read_bytes(), b"user-content")
        self.assertFalse((self.target / "saxonc-core-he.dll").exists())

    def test_directory_and_parent_file_conflicts(self):
        """Dateitypkonflikte dürfen keine bestehenden Ziele verändern."""
        self.target.mkdir()
        conflict = self.target / "saxonc-core-he.dll"
        conflict.mkdir()
        result = self.run_download()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(conflict.is_dir())
        self.assertFalse((self.target / "Notices").exists())
        parent_file = self.repository / "parent-file"
        parent_file.write_bytes(b"keep")
        result = self.run_download(str(parent_file / "child"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(parent_file.read_bytes(), b"keep")


if __name__ == "__main__":
    unittest.main()
