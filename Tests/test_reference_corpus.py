"""Prüft reproduzierbare Läufe sowie erkennbare Änderungen am Referenzbestand."""

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import reference_corpus as corpus


class ReferenceCorpusTests(unittest.TestCase):
    """Isoliert Regelpakete und JAR ohne reale Validatorprozesse."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixtures = self.root / "fixtures"
        self.fixtures.mkdir()
        self.rules = self.root / "rules"
        self.rules.mkdir()
        (self.rules / "scenarios.xml").write_text("<scenarios/>")
        self.jar = self.root / "validator.jar"
        self.jar.write_bytes(b"isoliertes JAR")
        (self.fixtures / "LICENSE").write_text("Testlizenz")
        (self.fixtures / "invoice.xml").write_bytes(b"<Invoice>original</Invoice>\r\n")
        self.manifest = {
            "rule_hashes": "rule-hashes.json",
            "java_validator": {"version": "1.6.3", "sha256": corpus.sha256(self.jar)},
            "cases": [{"name": "invoice", "file": "invoice.xml", "sha256": corpus.sha256(self.fixtures / "invoice.xml"),
                       "expected": {"status": "E", "accepted": False, "schema_valid": True,
                                    "processing_error": False, "report_valid": False, "required_findings": []},
                       "source": {"license": "test", "license_file": "LICENSE", "license_sha256": corpus.sha256(self.fixtures / "LICENSE")}}]
        }
        files = {"scenarios.xml": corpus.sha256(self.rules / "scenarios.xml")}
        self.lock = {"files": files, "sha256": hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
                     "scenarios": ["scenarios.xml"], "configuration_versions": ["test"]}
        self.save_source()
        self.run = self.root / "run"

    def save_source(self):
        """Schreibt nur die eigene isolierte Testkopie."""
        (self.fixtures / "fixture-manifest.json").write_text(json.dumps(self.manifest))
        (self.fixtures / "rule-hashes.json").write_text(json.dumps(self.lock))

    def prepare(self):
        return corpus.prepare(self.run, self.rules, self.jar, self.fixtures)

    def public_source(self):
        """Legt eine isolierte öffentliche LF-Quelle mit lokaler CRLF-Kopie fest."""
        source = self.manifest["cases"][0]["source"]
        source.update(repository="https://example.test/public", commit="a" * 40,
                      original_path="invoice.xml", derived=False,
                      original_sha256=hashlib.sha256(b"<Invoice>original</Invoice>\n").hexdigest(),
                      line_ending_normalization="lf-to-crlf")
        self.save_source()
        return source

    def test_public_source_line_endings_verified_without_network(self):
        """Die deklarierte Normalisierung erhält Geschäftsinhalt und lokale Laufbytes."""
        source = self.public_source()
        self.assertNotEqual(source["original_sha256"], self.manifest["cases"][0]["sha256"])
        manifest = self.prepare()
        self.assertEqual(Path(manifest["cases"][0]["file"]).read_bytes(), b"<Invoice>original</Invoice>\r\n")
        self.assertEqual(corpus.load_manifest(self.run), manifest)

    def test_claimed_line_endings_cannot_hide_content_change(self):
        """Ein nachgezogener lokaler Hash darf eine inhaltliche Änderung nicht legitimieren."""
        self.public_source()
        path = self.fixtures / "invoice.xml"
        path.write_bytes(b"<Invoice>changed</Invoice>\r\n")
        self.manifest["cases"][0]["sha256"] = corpus.sha256(path)
        self.save_source()
        with self.assertRaisesRegex(ValueError, "Original-SHA-256"):
            self.prepare()
        self.assertFalse(self.run.exists())

    def test_local_hash_cannot_masquerade_as_original_hash(self):
        source = self.public_source()
        source["original_sha256"] = self.manifest["cases"][0]["sha256"]
        self.save_source()
        with self.assertRaisesRegex(ValueError, "Original-SHA-256"):
            self.prepare()

    def test_incorrect_or_unknown_line_ending_normalization_rejected(self):
        source = self.public_source()
        original = b"<Invoice>original</Invoice>\r\n"
        for content in (original.replace(b"\r\n", b"\n"), original + b"\r", original + b"\n"):
            with self.subTest(content=content):
                path = self.fixtures / "invoice.xml"
                path.write_bytes(content)
                self.manifest["cases"][0]["sha256"] = corpus.sha256(path)
                self.save_source()
                with self.assertRaisesRegex(ValueError, "Zeilenendennormalisierung"):
                    self.prepare()
        (self.fixtures / "invoice.xml").write_bytes(original)
        self.manifest["cases"][0]["sha256"] = corpus.sha256(self.fixtures / "invoice.xml")
        source["line_ending_normalization"] = "xml-reserialization"
        self.save_source()
        with self.assertRaisesRegex(ValueError, "Unbekannte Zeilenendennormalisierung"):
            self.prepare()

    def test_derived_source_requires_matching_verified_original(self):
        """Eine Ableitung erbt die echte Git-Quellidentität, nicht den lokalen Basishash."""
        self.public_source()
        derived = deepcopy(self.manifest["cases"][0])
        derived.update(name="derived", file="derived.xml")
        (self.fixtures / "derived.xml").write_bytes(b"<Invoice>derived</Invoice>\r\n")
        derived["sha256"] = corpus.sha256(self.fixtures / "derived.xml")
        derived["source"]["derived"] = True
        self.manifest["cases"].append(derived)
        self.save_source()
        self.assertEqual(len(corpus.validate_fixtures(self.fixtures)["cases"]), 2)
        for field, value in (("original_sha256", self.manifest["cases"][0]["sha256"]),
                             ("original_path", "unverified.xml"), ("commit", "b" * 40)):
            with self.subTest(field=field):
                previous = derived["source"][field]
                derived["source"][field] = value
                self.save_source()
                with self.assertRaisesRegex(ValueError, "Ungeprüfte Originalquelle"):
                    self.prepare()
                derived["source"][field] = previous

    def test_invalid_public_source_identity_rejected(self):
        source = self.public_source()
        for field, value, message in (("commit", "main", "Quellidentität"),
                                      ("original_sha256", "invalid", "Quellidentität"),
                                      ("derived", "false", "boolesch")):
            with self.subTest(field=field):
                previous = source[field]
                source[field] = value
                self.save_source()
                with self.assertRaisesRegex(ValueError, message):
                    self.prepare()
                source[field] = previous

    def test_repository_fixtures_have_verified_source_and_local_hashes(self):
        """Der echte Bestand wird zusätzlich zu isolierten Gegenproben geprüft."""
        manifest = corpus.validate_fixtures(corpus.FIXTURES)
        self.assertEqual(sum(case["source"].get("derived") is False for case in manifest["cases"]), 2)

    def test_prepare_preserves_original_bytes_and_identity(self):
        manifest = self.prepare()
        self.assertEqual(Path(manifest["cases"][0]["file"]).read_bytes(), b"<Invoice>original</Invoice>\r\n")
        self.assertEqual(corpus.load_manifest(self.run), manifest)
        arguments = corpus.engine_arguments(manifest, self.run / "native", "/local/saxon.dll")
        self.assertEqual(arguments[:4], ["--json", "--html", "--serialize-report-input", "--saxon-library"])
        self.assertIn(str(self.rules / "scenarios.xml"), arguments)
        self.assertEqual(arguments[-1], str(self.run / "input" / "invoice.xml"))

    def test_empty_duplicate_traversal_and_hash_fail_before_run_creation(self):
        original = deepcopy(self.manifest)
        variants = []
        empty = deepcopy(original)
        empty["cases"] = []
        variants.append(empty)
        duplicate = deepcopy(original)
        duplicate["cases"].append(deepcopy(duplicate["cases"][0]))
        variants.append(duplicate)
        traversal = deepcopy(original)
        traversal["cases"][0]["file"] = "../invoice.xml"
        variants.append(traversal)
        bad_hash = deepcopy(original)
        bad_hash["cases"][0]["sha256"] = "0" * 64
        variants.append(bad_hash)
        for variant in variants:
            with self.subTest(variant=variant):
                self.manifest = variant
                self.save_source()
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse(self.run.exists())

    def test_duplicate_basename_rejected_even_with_distinct_case_names(self):
        duplicate = deepcopy(self.manifest["cases"][0])
        duplicate["name"] = "different"
        self.manifest["cases"].append(duplicate)
        self.save_source()
        with self.assertRaisesRegex(ValueError, "Doppelter"):
            self.prepare()

    def test_missing_license_rejected(self):
        self.manifest["cases"][0]["source"]["license_file"] = "missing"
        self.save_source()
        with self.assertRaisesRegex(ValueError, "Lizenz"):
            self.prepare()

    def test_changed_license_rejected(self):
        """Ein vorhandener, aber veränderter Lizenztext ist kein gültiger Herkunftsnachweis."""
        (self.fixtures / "LICENSE").write_text("veränderte Lizenz")
        with self.assertRaisesRegex(ValueError, "Lizenz-SHA"):
            self.prepare()
        self.assertFalse(self.run.exists())

    def test_unsafe_paths_rejected(self):
        for relative in ("/etc/passwd", "../escape", "C:/escape", "child\\escape", ""):
            with self.subTest(relative=relative), self.assertRaises(ValueError):
                corpus.safe_path(self.fixtures, relative)

    def test_changed_rule_rejected(self):
        (self.rules / "scenarios.xml").write_text("changed")
        with self.assertRaisesRegex(ValueError, "Regel-SHA"):
            self.prepare()

    def test_extra_rule_rejected(self):
        (self.rules / "extra.xml").write_text("extra")
        with self.assertRaisesRegex(ValueError, "Regeldateimenge"):
            self.prepare()

    def test_changed_jar_rejected(self):
        self.jar.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "JAR-SHA"):
            self.prepare()

    def test_existing_run_not_overwritten(self):
        self.prepare()
        with self.assertRaises(FileExistsError):
            self.prepare()

    def test_mutated_run_input_or_expectations_rejected(self):
        manifest = self.prepare()
        changed = deepcopy(manifest)
        changed["cases"][0]["expected"]["accepted"] = True
        (self.run / "manifest.json").write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, "Erwartung"):
            corpus.load_manifest(self.run)
        (self.run / "manifest.json").write_text(json.dumps(manifest))
        (self.run / "input" / "invoice.xml").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "Laufeingabe"):
            corpus.load_manifest(self.run)

    def test_mutated_prerequisites_rejected_before_process(self):
        self.prepare()
        (self.rules / "scenarios.xml").write_text("changed")
        with patch.object(subprocess, "run") as process:
            with self.assertRaisesRegex(ValueError, "Regel-SHA"):
                corpus.execute(self.run, "java", "java")
            process.assert_not_called()

    def test_explicit_transport_alias_preserves_input_and_expectation_checks(self):
        """Ein zweiter Betriebssystempfad ändert weder die Originalbytes noch den Prüfentscheid."""
        manifest = self.prepare()
        manifest['cases'][0]['input_aliases'] = [r'D:\Reference\invoice.xml']
        (self.run / 'manifest.json').write_text(json.dumps(manifest))
        self.assertEqual(corpus.load_manifest(self.run)['cases'][0]['expected']['status'], 'E')
        manifest['cases'][0]['input_aliases'] = [False]
        (self.run / 'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'Eingabepfadzuordnung'):
            corpus.load_manifest(self.run)

    def test_expected_rejection_exit_is_success_and_security_arguments_present(self):
        self.prepare()
        version = subprocess.CompletedProcess(["java", "-version"], 0, "", "Java test")
        validation = subprocess.CompletedProcess([], 1, "rejected", "diagnostic")
        with patch.object(subprocess, "run", side_effect=[version, validation]) as process:
            execution = corpus.execute(self.run, "java", "java")
        self.assertEqual(execution["returncode"], 1)
        self.assertFalse(execution["maven_used"])
        arguments = process.call_args.args[0]
        self.assertIn("-Djavax.xml.accessExternalDTD=", arguments)
        self.assertIn("-Djavax.xml.accessExternalSchema=file", arguments)
        self.assertIn("-Djavax.xml.accessExternalStylesheet=file", arguments)
        self.assertEqual(process.call_args.kwargs["cwd"], self.run / "java")
        self.assertEqual((self.run / "java" / "stdout.log").read_text(), "rejected")
        with self.assertRaises(FileExistsError):
            corpus.execute(self.run, "java", "java")

    def test_unexpected_exit_fails_with_recorded_diagnostics(self):
        self.prepare()
        with patch.object(subprocess, "run", side_effect=[subprocess.CompletedProcess([], 0, "", "test"),
                                                         subprocess.CompletedProcess([], 254, "", "crash")]):
            with self.assertRaisesRegex(RuntimeError, "Unerwarteter Exitcode"):
                corpus.execute(self.run, "java", "java")
        execution = corpus.read_json(self.run / "java" / "execution.json")
        self.assertEqual(execution["returncode"], 254)
        self.assertEqual((self.run / "java" / "stderr.log").read_text(), "crash")

    def test_timeout_fails_with_partial_output_preserved(self):
        self.prepare()
        with patch.object(subprocess, "run", side_effect=[subprocess.CompletedProcess([], 0, "", "test"),
                                                         subprocess.TimeoutExpired("java", 7, output=b"partial", stderr=b"hung")]):
            with self.assertRaisesRegex(RuntimeError, "Timeout"):
                corpus.execute(self.run, "java", "java", timeout=7)
        execution = corpus.read_json(self.run / "java" / "execution.json")
        self.assertTrue(execution["timed_out"])
        self.assertIsNone(execution["returncode"])
        self.assertEqual((self.run / "java" / "stdout.log").read_text(), "partial")

    def test_external_delphi_execution_preserves_json_array(self):
        output = self.root / "native"
        stdout = '[{"status":"W","acceptance":"ACCEPTABLE"}]'
        corpus.record_execution(output, ["validator", "--json"], stdout, "", 0, "start", {"engine": "delphi", "compiler_version": "11"})
        self.assertEqual(corpus.read_json(output / "results.json"), json.loads(stdout))
        self.assertEqual(corpus.read_json(output / "execution.json")["compiler_version"], "11")
        with self.assertRaises(FileExistsError):
            corpus.record_execution(output, [], "[]", "", 0, "start", {"engine": "delphi"})


if __name__ == "__main__":
    unittest.main()
