"""Prüft Laufzeitpakete mit isolierten Programm-, SDK- und Hinweisdateien."""

from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import package_runtime


class RuntimePackageTests(unittest.TestCase):
    """Programme, Regelpakete und Hinweise bilden ein überprüfbares Paket."""

    def setUp(self):
        """Lokale Fixtures ersetzen ausschließlich Dateien und den bekannten SDK-Hash."""
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repository"
        self.output = self.root / "build"
        self.executable = self.output / "MGGMXmlValidator.exe"
        self.batch_executable = self.executable.with_name("MGGMXmlValidatorBatch.exe")
        self.example_executable = self.executable.with_name("ValidateXmlExample.exe")
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"validator-fixture")
        self.batch_executable.write_bytes(b"batch-fixture")
        self.example_executable.write_bytes(b"example-fixture")
        command = self.root / "Examples/validate.cmd"
        command.parent.mkdir()
        command.write_bytes(b"@echo off\r\nValidateXmlExample.exe %*\r\n")
        self.sdk = self.root / "Vendor/SaxonC"
        self.library = self.sdk / "SaxonCCoreHE/bin/saxonc-core-he.dll"
        self.library.parent.mkdir(parents=True)
        self.library.write_bytes(b"sdk-fixture")
        notices = self.sdk / "notices"
        notices.mkdir()
        for name in ("LICENSE.txt", "JAMESCLARK.txt", "JLINE2.txt"):
            (notices / name).write_text("SDK-Hinweis", encoding="utf-8")
        upstream_notices = self.root / "ThirdParty/KoSIT"
        upstream_notices.mkdir(parents=True)
        (upstream_notices / "LICENSE").write_text("KoSIT-Lizenz", encoding="utf-8")
        (upstream_notices / "NOTICE").write_text("KoSIT-Hinweis", encoding="utf-8")
        saxon_notices = self.root / "ThirdParty/SaxonC"
        saxon_notices.mkdir()
        (saxon_notices / "LICENSE.txt").write_text("SaxonC-Lizenz", encoding="utf-8")
        for relative in package_runtime.LEGAL_FILES:
            notice = self.root / relative
            notice.parent.mkdir(parents=True, exist_ok=True)
            if not notice.exists():
                notice.write_text("Lizenz-Fixture", encoding="utf-8")
        self.validation_root = self.root / "Validation"
        for relative in package_runtime.SCENARIOS:
            scenario = self.validation_root / relative
            scenario.parent.mkdir(parents=True, exist_ok=True)
            scenario.write_text("<scenarios/>", encoding="utf-8")
        (self.validation_root / "validator-configuration-zugferd/LICENSE").write_text("Regellizenz", encoding="utf-8")
        (self.validation_root / "validator-configuration-xrechnung/3.0.2/README.md").write_text("Regelhinweise", encoding="utf-8")
        resources = self.validation_root / "validator-configuration-xrechnung/3.0.2/resources"
        resources.mkdir()
        (resources / "schema.xsd").write_bytes(b"<!-- Copyright-Fixture -->")
        self.addCleanup(patch.stopall)
        patch.object(package_runtime, "ROOT", self.root).start()
        patch.object(package_runtime, "DLL_SHA256", package_runtime.digest(self.library)).start()

    def run_package(self, *arguments):
        """Standardpfade und ausdrücklich übergebene Varianten gleichermaßen prüfen."""
        with redirect_stdout(io.StringIO()):
            package_runtime.package(["--sdk", str(self.sdk), "--validation-root", str(self.validation_root), *arguments])

    def snapshot(self):
        """Vorprüfungsfehler dürfen den bestehenden Buildinhalt nicht verändern."""
        return {path.relative_to(self.output).as_posix(): path.read_bytes()
                for path in self.output.rglob("*") if path.is_file()}

    def test_standalone_repository_defaults_without_arguments(self):
        """Der dokumentierte Aufbau benötigt keine benachbarten Entwicklungsprojekte."""
        shutil.copytree(self.validation_root, self.output / "Validation")
        self.validation_root.rename(self.root / "external-rules-unavailable")
        with redirect_stdout(io.StringIO()):
            package_runtime.package([])
        self.assertEqual((self.output / "saxonc-core-he.dll").read_bytes(), self.library.read_bytes())
        self.assertTrue((self.output / "Validation" / package_runtime.SCENARIOS[2]).is_file())

    def test_bundled_rule_changes_are_preserved_and_manifested_in_place(self):
        """Szenarioanpassungen im versionierten Buildpfad bleiben auch bei erneuter Paketierung erhalten."""
        bundled = self.output / "Validation"
        shutil.copytree(self.validation_root, bundled)
        self.run_package("--validation-root", str(bundled))
        scenario = bundled / package_runtime.SCENARIOS[2]
        scenario.write_bytes(b"<scenarios><name>custom-profile</name></scenarios>")
        expected = {path.relative_to(bundled): path.read_bytes() for path in bundled.rglob("*") if path.is_file()}
        self.run_package("--validation-root", str(bundled))
        self.assertEqual(expected, {path.relative_to(bundled): path.read_bytes() for path in bundled.rglob("*") if path.is_file()})
        manifest = json.loads((self.output / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["files"]["Validation/" + package_runtime.SCENARIOS[2]], package_runtime.digest(scenario))

    def test_all_programs_rules_and_hashes_are_packaged(self):
        """Alle Programme, Regeldateien und Lizenztexte gehören zum Manifest."""
        self.run_package()
        manifest = json.loads((self.output / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["sdk"], "SaxonC-HE 12.10.1 Windows x86_64")
        for source in (self.executable, self.batch_executable, self.example_executable, self.library):
            copied = self.output / source.name
            self.assertEqual(copied.read_bytes(), source.read_bytes())
            self.assertEqual(manifest["files"][source.name], package_runtime.digest(source))
        self.assertEqual((self.output / "Notices/SaxonC/SDK/LICENSE.txt").read_text(encoding="utf-8"), "SDK-Hinweis")
        self.assertEqual((self.output / "Notices/SaxonC/LICENSE.txt").read_text(encoding="utf-8"), "SaxonC-Lizenz")
        self.assertEqual((self.output / "Notices/KoSIT/NOTICE").read_text(encoding="utf-8"), "KoSIT-Hinweis")
        self.assertEqual(manifest["scenarios"], list(package_runtime.SCENARIOS))
        for relative in package_runtime.SCENARIOS:
            self.assertEqual((self.output / "Validation" / relative).read_bytes(), (self.validation_root / relative).read_bytes())
        self.assertEqual((self.output / "validate.cmd").read_bytes(), (self.root / "Examples/validate.cmd").read_bytes())
        self.assertFalse(any(path.startswith("/") or "repository" in path for path in manifest["files"]))

    def test_new_target_and_explicit_validation_root(self):
        """Ein eigener Zielordner und externe Regelquellen bleiben unterstützt."""
        target = self.root.parent / "distribution"
        self.run_package("--target", str(target), "--validation-root", str(self.validation_root))
        self.assertEqual((target / "MGGMXmlValidator.exe").read_bytes(), self.executable.read_bytes())
        self.assertTrue((target / "Validation" / package_runtime.SCENARIOS[2]).is_file())

    def test_identical_second_run_preserves_unrelated_files(self):
        """Idempotente Aufrufe erfassen keine fremden Builds oder Daten im Manifest."""
        extra = self.output / "unrelated.txt"
        extra.write_bytes(b"keep")
        self.run_package()
        first = self.snapshot()
        self.run_package()
        self.assertEqual(first, self.snapshot())
        self.assertNotIn("unrelated.txt", json.loads((self.output / "manifest.json").read_text())["files"])

    def test_managed_file_can_be_updated(self):
        """Unveränderte verwaltete Dateien dürfen neuen Quellinhalt erhalten."""
        self.run_package()
        notice = self.root / "ThirdParty/KoSIT/NOTICE"
        notice.write_bytes(b"updated-notice")
        self.run_package()
        self.assertEqual((self.output / "Notices/KoSIT/NOTICE").read_bytes(), notice.read_bytes())

    def test_only_selected_sdk_and_rule_directories_are_packaged(self):
        """SDK-Werkzeuge und benachbarte Rechnungsdaten gehören nicht zur Laufzeit."""
        (self.sdk / "invoice.xml").write_bytes(b"private")
        (self.sdk / "validator.jar").write_bytes(b"java")
        (self.validation_root / "invoice.xml").write_bytes(b"private")
        excluded_version = self.validation_root / "validator-configuration-xrechnung/9.9.9"
        excluded_version.mkdir()
        (excluded_version / "private.xml").write_bytes(b"private")
        (self.validation_root / "validator-configuration-zugferd/specification.xlsx").write_bytes(b"reference")
        self.run_package()
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertFalse(any("invoice" in relative or "private" in relative or relative.endswith(".jar")
                             for relative in manifest["files"]))
        self.assertFalse(any(relative.endswith(".xlsx") for relative in manifest["files"]))
        for name in ("LICENSE", "NOTICE", "THIRD_PARTY.md"):
            self.assertEqual((self.output / "Notices" / name).read_bytes(), (self.root / name).read_bytes())
        self.assertTrue((self.output / "Notices/Validation/EN16931-EUPL.txt").is_file())

    def test_unexpected_notice_file_types_are_rejected_before_writing(self):
        """Hinweisordner dürfen keine Programme, Rechnungs-XML oder Archive ins Paket einschleusen."""
        for directory in (self.root / "ThirdParty", self.sdk / "notices"):
            for name in ("unexpected.exe", "invoice.xml", "archive.zip", "unknown"):
                with self.subTest(directory=directory, name=name):
                    source = directory / name
                    source.write_bytes(b"unexpected-fixture")
                    before = self.snapshot()
                    try:
                        with self.assertRaisesRegex(SystemExit, "Hinweisdatei"):
                            self.run_package()
                        self.assertEqual(before, self.snapshot())
                    finally:
                        source.unlink()

    def test_binary_content_in_notice_text_file_is_rejected(self):
        """Eine Textendung macht binäre Nutzdaten nicht zu einem Lizenzhinweis."""
        for source in (self.root / "ThirdParty/extra.txt", self.sdk / "notices/extra.md", self.root / "LICENSE"):
            for payload, diagnostic in ((b"\xff-binary-fixture", "kein UTF-8-Text"), (b"MZ\x00-binary-fixture", "binäre Steuerzeichen")):
                with self.subTest(source=source, diagnostic=diagnostic):
                    previous = source.read_bytes() if source.exists() else None
                    source.write_bytes(payload)
                    before = self.snapshot()
                    try:
                        with self.assertRaisesRegex(SystemExit, diagnostic):
                            self.run_package()
                        self.assertEqual(before, self.snapshot())
                    finally:
                        if previous is None:
                            source.unlink()
                        else:
                            source.write_bytes(previous)

    def test_additional_license_texts_are_preserved(self):
        """Textliche Zusatzhinweise bleiben bytegleich erhalten, einschließlich endungsloser Lizenzen."""
        additions = {
            self.root / "ThirdParty/Additional/LICENSE": "Notices/Additional/LICENSE",
            self.root / "ThirdParty/Additional/NOTICE.txt": "Notices/Additional/NOTICE.txt",
            self.root / "ThirdParty/Additional/README.md": "Notices/Additional/README.md",
            self.sdk / "notices/COPYING": "Notices/SaxonC/SDK/COPYING",
        }
        for source in additions:
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes("Zusätzlicher Hinweis\r\n".encode("utf-8"))
        (self.sdk / "notices/COPYING").write_bytes("Zusätzlicher Hinweis\r\n".encode("utf-8-sig"))
        self.run_package()
        for source, relative in additions.items():
            self.assertEqual((self.output / relative).read_bytes(), source.read_bytes())

    def test_rebuilt_program_in_default_target_is_accepted(self):
        """Ein frischer Build im Ziel gilt selbst als vorgegebene Programmquelle."""
        self.run_package()
        self.executable.write_bytes(b"rebuilt-validator")
        self.run_package()
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["files"]["MGGMXmlValidator.exe"], package_runtime.digest(self.executable))

    def test_unmanaged_collision_is_rejected_before_copying(self):
        """Fremde Zieldateien dürfen bei der Erstpaketierung nicht überschrieben werden."""
        (self.output / "validate.cmd").write_bytes(b"user-command")
        before = self.snapshot()
        with self.assertRaisesRegex(SystemExit, "nicht überschrieben"):
            self.run_package()
        self.assertEqual(before, self.snapshot())

    def test_modified_managed_file_is_preserved(self):
        """Nachträglich bearbeitete Paketdateien bleiben vor Aktualisierungen geschützt."""
        self.run_package()
        (self.output / "Notices/KoSIT/NOTICE").write_bytes(b"user-notice")
        (self.root / "ThirdParty/KoSIT/NOTICE").write_bytes(b"new-source")
        before = self.snapshot()
        with self.assertRaisesRegex(SystemExit, "nicht überschrieben"):
            self.run_package()
        self.assertEqual(before, self.snapshot())

    def test_missing_batch_is_rejected_before_target_creation(self):
        """Ein fehlender Batchbuild darf kein unvollständiges Laufzeitpaket anlegen."""
        self.batch_executable.rename(self.batch_executable.with_suffix(".fixture"))
        before = self.snapshot()
        with self.assertRaisesRegex(SystemExit, "Batchprogramm fehlt"):
            self.run_package()
        self.assertEqual(before, self.snapshot())

    def test_changed_sdk_is_rejected_before_target_creation(self):
        """Eine vom gepinnten Hash abweichende SDK-Datei muss sichtbar scheitern."""
        self.library.write_bytes(b"modified-sdk-fixture")
        before = self.snapshot()
        with self.assertRaisesRegex(SystemExit, "entspricht nicht dem geprüften SDK"):
            self.run_package()
        self.assertEqual(before, self.snapshot())

    def test_missing_prerequisites_leave_build_unchanged(self):
        """Jede fachlich erforderliche Quelle wird vor dem ersten Zielschreibzugriff geprüft."""
        paths = [self.example_executable, self.root / "Examples/validate.cmd",
                 self.sdk / "notices/JLINE2.txt", self.validation_root / package_runtime.SCENARIOS[0],
                 self.validation_root / "validator-configuration-zugferd/LICENSE",
                 self.validation_root / "validator-configuration-xrechnung/3.0.2/README.md"]
        paths.extend(self.root / relative for relative in package_runtime.LEGAL_FILES)
        for source in paths:
            with self.subTest(source=source):
                moved = source.with_suffix(source.suffix + ".fixture")
                source.rename(moved)
                before = self.snapshot()
                try:
                    with self.assertRaises(SystemExit):
                        self.run_package()
                    self.assertEqual(before, self.snapshot())
                finally:
                    moved.rename(source)

    def test_missing_source_does_not_create_new_target(self):
        """Eine fehlende Quelle darf auch an einem neuen Ort kein Teilpaket hinterlassen."""
        target = self.root.parent / "new-package"
        self.example_executable.rename(self.example_executable.with_suffix(".fixture"))
        with self.assertRaisesRegex(SystemExit, "Beispielprogramm fehlt"):
            self.run_package("--target", str(target))
        self.assertFalse(target.exists())

    def test_invalid_manifest_paths_are_rejected(self):
        """Manipulierte Manifeste dürfen keine Dateien außerhalb des Pakets adressieren."""
        for relative in ("../outside", "/absolute", "C:/absolute", "a\\b", "a//b", "a/./b", "a/.. /b", "a/b.", "manifest.json"):
            with self.subTest(relative=relative):
                (self.output / "manifest.json").write_text(json.dumps({"sdk": package_runtime.SDK_NAME, "files": {relative: "0" * 64}}))
                before = self.snapshot()
                with self.assertRaises(SystemExit):
                    self.run_package()
                self.assertEqual(before, self.snapshot())

    def test_symlink_in_source_is_rejected(self):
        """Regelpakete dürfen über Verweise keine zusätzlichen Daten einschleusen."""
        (self.validation_root / "validator-configuration-zugferd/linked.xml").symlink_to(self.executable)
        before = self.snapshot()
        with self.assertRaisesRegex(SystemExit, "Symbolischer Verweis"):
            self.run_package()
        self.assertEqual(before, self.snapshot())

    def test_customer_xml_inside_rule_directory_is_rejected(self):
        """Auch versehentlich in Regelverzeichnissen abgelegte Rechnungen bleiben ausgeschlossen."""
        invoice = self.validation_root / "validator-configuration-zugferd/invoice.xml"
        invoice.write_bytes(b"<CrossIndustryInvoice/>")
        before = self.snapshot()
        with self.assertRaisesRegex(SystemExit, "Szenarien oder Codelisten"):
            self.run_package()
        self.assertEqual(before, self.snapshot())

    def test_archives_inside_rule_directory_are_rejected(self):
        """Archive und sonstige Fremddateien werden vor der Paketierung sichtbar gemeldet."""
        archive = self.validation_root / "validator-configuration-zugferd/history.zip"
        archive.write_bytes(b"archive")
        before = self.snapshot()
        with self.assertRaisesRegex(SystemExit, "Unerwartete Datei"):
            self.run_package()
        self.assertEqual(before, self.snapshot())

    def test_malformed_rule_xml_is_rejected(self):
        """Defekte XML-Dateien werden nicht als geprüfte Regelquelle ausgegeben."""
        scenario = self.validation_root / package_runtime.SCENARIOS[0]
        scenario.write_bytes(b"<scenarios>")
        before = self.snapshot()
        with self.assertRaisesRegex(SystemExit, "Ungültige XML-Regeldatei"):
            self.run_package()
        self.assertEqual(before, self.snapshot())

    def test_invalid_manifests_leave_target_unchanged(self):
        """Unlesbare oder strukturell falsche Manifeste erteilen keine Schreibfreigabe."""
        for content in ("{", "[]", '{"files": {}}',
                        json.dumps({"sdk": package_runtime.SDK_NAME, "files": []}),
                        json.dumps({"sdk": package_runtime.SDK_NAME, "files": {"validate.cmd": "wrong"}})):
            with self.subTest(content=content):
                (self.output / "manifest.json").write_text(content)
                before = self.snapshot()
                with self.assertRaisesRegex(SystemExit, "Ungültiges Paketmanifest"):
                    self.run_package()
                self.assertEqual(before, self.snapshot())

    def test_obsolete_owned_file_requires_explicit_cleanup(self):
        """Der Paketierer löscht keine aus dem aktuellen Vertrag entfernten Dateien."""
        self.run_package()
        manifest_path = self.output / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["files"]["obsolete.txt"] = "0" * 64
        manifest_path.write_text(json.dumps(manifest))
        before = self.snapshot()
        with self.assertRaisesRegex(SystemExit, "nicht mehr vorgesehene"):
            self.run_package()
        self.assertEqual(before, self.snapshot())

    def test_changed_copy_is_detected_before_commit(self):
        """Die Gegenprobe erkennt eine beim Kopieren beschädigte Datei vor der Zieländerung."""
        original_copy = package_runtime.shutil.copy2

        def corrupt_copy(source, destination):
            """Ein isolierter Kopierfehler muss die Byteprüfung auslösen."""
            result = original_copy(source, destination)
            Path(destination).write_bytes(b"corrupted-copy")
            return result

        before = self.snapshot()
        with patch.object(package_runtime.shutil, "copy2", side_effect=corrupt_copy):
            with self.assertRaisesRegex(SystemExit, "stimmt nicht mit ihrer Quelle"):
                self.run_package()
        self.assertEqual(before, self.snapshot())

    def test_symlink_in_target_is_rejected(self):
        """Zielverweise dürfen auch vorhandene externe Dateien nicht überschreiben."""
        external = self.root.parent / "external"
        external.mkdir()
        (self.output / "Notices").symlink_to(external, target_is_directory=True)
        with self.assertRaisesRegex(SystemExit, "Symbolischer Verweis"):
            self.run_package()
        self.assertEqual(list(external.iterdir()), [])

    def test_target_directory_blocked_by_file_is_rejected(self):
        """Dateien an Verzeichnispfaden müssen bereits in der Vorprüfung auffallen."""
        (self.output / "Validation").write_bytes(b"user-file")
        before = self.snapshot()
        with self.assertRaisesRegex(SystemExit, "blockiert"):
            self.run_package()
        self.assertEqual(before, self.snapshot())

    def test_overlapping_rule_source_and_target_is_rejected(self):
        """Eine Regelquelle darf kein Laufzeitziel und kein übergeordnetes Ziel sein."""
        source = self.validation_root / "validator-configuration-zugferd"
        with self.assertRaisesRegex(SystemExit, "überlappen"):
            self.run_package("--target", str(source / "output"))
        self.assertFalse((source / "output").exists())


if __name__ == "__main__":
    unittest.main()
