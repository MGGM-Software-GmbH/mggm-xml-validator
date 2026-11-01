"""Prüft die Sammlung geteilter Kindprozessmessungen mit isolierten Linux-Fixtures."""

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from collect_benchmark import collect, main


class BenchmarkCollectionTests(unittest.TestCase):
    """Zwei abgeschlossene Eingaben und ein ausgeschlossener Abbruch bilden die Gegenprobenbasis."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        cases = []
        for name in ("Erste.XML", "Zweite.xml"):
            data = ("<Invoice>" + name + "</Invoice>").encode()
            (self.inputs / name).write_bytes(data)
            cases.append({"name": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps({"cases": cases, "input_directory": str(self.inputs)}), encoding="utf-8")
        self.sources = [self.root / "initial", self.root / "range"]
        self.output = self.root / "collected"
        for index, source in enumerate(self.sources):
            source.mkdir()
            (source / "reports").mkdir()
            process_directory = source / "process-0001"
            process_directory.mkdir()
            process = {"executable": "D:\\java\\bin\\java.exe", "working_directory": "D:\\inputs",
                       "arguments": ["-Xmx1G", "-jar", "D:\\validator.jar", "-X", "-s", "D:\\scenarios.xml", "--html", "-o", str(source / "reports"), cases[index]["name"]],
                       "exit_code": index, "wall_ms": 100.25 + index, "cpu_user_ms": 30.5 + index, "cpu_kernel_ms": 4.25 + index}
            (process_directory / "process.json").write_text(json.dumps(process), encoding="utf-8-sig")
            for extension in ("xml", "html"):
                report = source / "reports" / (Path(cases[index]["name"]).stem + "-report." + extension)
                report.write_text("<report>" + cases[index]["name"] + "</report>", encoding="utf-8")
        self.unfinished = self.sources[0] / "process-0002"
        self.unfinished.mkdir()
        (self.unfinished / "stdout.txt").write_text("abgebrochen")
        # Teilbereichs-Summen sind keine Quelle für die Sammlung; maßgeblich sind ausschließlich process.json-Dateien.
        (self.sources[1] / "measurement.json").write_text(json.dumps({"process_wall_ms": 999999}))

    def mutate_process(self, source_index, field, value):
        """Genau ein Feld eines abgeschlossenen Kindprozesses ändern."""
        path = self.sources[source_index] / "process-0001" / "process.json"
        process = json.loads(path.read_text(encoding="utf-8-sig"))
        process[field] = value
        path.write_text(json.dumps(process), encoding="utf-8-sig")

    def assert_rejected(self):
        """Eine Vorbedingungsverletzung darf keinen neuen Ausgabeordner hinterlassen."""
        with self.assertRaises((ValueError, OSError)):
            collect(self.manifest, self.output, self.sources)
        self.assertFalse(self.output.exists())

    def test_two_inputs_sum_exact_processes(self):
        result = collect(self.manifest, self.output, self.sources)
        self.assertEqual(result["mode"], "java-per-file")
        self.assertEqual(result["process_count"], 2)
        self.assertEqual(result["process_wall_ms"], 201.5)
        self.assertEqual(result["cpu_user_ms"], 62.0)
        self.assertEqual(result["cpu_kernel_ms"], 9.5)
        self.assertNotIn("total_wall_ms", result)
        self.assertEqual([process["input"] for process in result["processes"]], ["Erste.XML", "Zweite.xml"])
        self.assertTrue(all(Path(process["source_process_json"]).is_file() for process in result["processes"]))
        self.assertEqual(len(result["excluded_processes"]), 1)
        self.assertEqual(result["excluded_processes"][0]["process_directory"], str(self.unfinished))
        self.assertEqual(len(list((self.output / "reports").iterdir())), 4)
        self.assertFalse((self.output / "stdout.txt").exists())
        self.assertEqual(json.loads((self.output / "measurement.json").read_text()), result)
        for source in self.sources:
            for report in (source / "reports").iterdir():
                self.assertEqual(report.read_bytes(), (self.output / "reports" / report.name).read_bytes())

    def test_duplicate_input(self):
        self.mutate_process(1, "arguments", ["-Xmx1G", "-jar", "D:\\validator.jar", "-X", "-s", "D:\\scenarios.xml", "--html", "-o", "D:/other", "Erste.XML"])
        self.assert_rejected()

    def test_missing_report_pair(self):
        (self.sources[1] / "reports" / "Zweite-report.html").unlink()
        self.assert_rejected()

    def test_empty_report(self):
        (self.sources[1] / "reports" / "Zweite-report.xml").write_bytes(b"")
        self.assert_rejected()

    def test_missing_original_input(self):
        (self.inputs / "Erste.XML").unlink()
        self.assert_rejected()

    def test_changed_original_input(self):
        (self.inputs / "Erste.XML").write_bytes(b"<Changed/>")
        self.assert_rejected()

    def test_invalid_times(self):
        for field in ("wall_ms", "cpu_user_ms", "cpu_kernel_ms"):
            for value in (-1, float("nan"), float("inf"), "100", True, None):
                with self.subTest(field=field, value=value):
                    self.mutate_process(1, field, value)
                    self.assert_rejected()
                    self.mutate_process(1, field, 0)

    def test_changed_options(self):
        path = self.sources[1] / "process-0001" / "process.json"
        process = json.loads(path.read_text(encoding="utf-8-sig"))
        process["arguments"][0] = "-Xmx2G"
        self.mutate_process(1, "arguments", process["arguments"])
        self.assert_rejected()

    def test_changed_program(self):
        self.mutate_process(1, "executable", "D:\\other-java.exe")
        self.assert_rejected()

    def test_changed_working_directory(self):
        self.mutate_process(1, "working_directory", "D:\\other-inputs")
        self.assert_rejected()

    def test_child_exit_two(self):
        self.mutate_process(1, "exit_code", 2)
        self.assert_rejected()

    def test_missing_completed_process(self):
        (self.sources[1] / "process-0001" / "process.json").unlink()
        self.assert_rejected()

    def test_foreign_reports_not_copied(self):
        (self.sources[0] / "reports" / "Abgebrochen-report.xml").write_text("<report/>")
        self.assert_rejected()

    def test_unfinished_process_artifacts_excluded(self):
        (self.unfinished / "unfinished-report.xml").write_text("<report/>")
        result = collect(self.manifest, self.output, self.sources)
        self.assertIn(str(self.unfinished / "unfinished-report.xml"), result["excluded_processes"][0]["artifacts"])
        self.assertFalse((self.output / "unfinished-report.xml").exists())

    def test_existing_output_preserved(self):
        self.output.mkdir()
        marker = self.output / "marker.txt"
        marker.write_text("bestehend")
        with self.assertRaises(ValueError):
            collect(self.manifest, self.output, self.sources)
        self.assertEqual(marker.read_text(), "bestehend")
        self.assertEqual(list(self.output.iterdir()), [marker])

    def test_cli_success(self):
        arguments = [str(self.manifest), str(self.output)] + [str(source) for source in self.sources]
        with redirect_stdout(io.StringIO()):
            self.assertEqual(main(arguments), 0)

    def test_cli_error_without_output(self):
        self.mutate_process(1, "exit_code", 2)
        arguments = [str(self.manifest), str(self.output)] + [str(source) for source in self.sources]
        with redirect_stderr(io.StringIO()):
            self.assertEqual(main(arguments), 1)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
