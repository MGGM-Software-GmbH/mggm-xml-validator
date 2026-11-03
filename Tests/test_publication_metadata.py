"""Öffentliche Prüfnachweise enthalten Ergebnisse statt interner Artefaktpfade."""

import json
from pathlib import Path
import unittest


REPOSITORY_DIRECTORY = Path(__file__).parents[1]
METADATA_FILES = (
    "docs/prp/test-coverage/original-method-matrix.json",
    "Tests/publication-verification.json",
    "Tests/svrl-metadata-verification.json",
)
INTERNAL_PATH_FIELDS = frozenset({
    "artifact", "execution_artifact", "java_execution_artifact",
    "builds_artifact", "evidence_directory_name",
})


def verify_metadata(value, location=()):
    """Auch relative Laufpfade entfallen; öffentliche Quell- und Ergebnisdaten bleiben zulässig."""
    if isinstance(value, dict):
        for key, child in value.items():
            child_location = location + (key,)
            if key in INTERNAL_PATH_FIELDS or child_location == ("python_tests", "evidence"):
                raise ValueError("Interner Prüfdateiverweis: " + ".".join(child_location))
            verify_metadata(child, child_location)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            verify_metadata(child, location + (str(index),))


class PublicationMetadataVerifierTests(unittest.TestCase):
    """Synthetische Gegenproben unterscheiden öffentliche Daten von internen Laufpfadfeldern."""

    def test_public_sources_results_and_artifacts_dictionary_are_allowed(self):
        verify_metadata({
            "source": {"file": "src/test/java/example/ExampleTest.java", "sha256": "a" * 64},
            "methods": [{"evidence": [{"run_id": "synthetic-run", "exit_code": 0, "passed": True}]}],
            "python_tests": {"passed": 3, "total": 3},
            "artifacts": {"framework": [{"file": "Source/example.xsd", "sha256": "b" * 64}]},
        })

    def test_internal_path_fields_are_rejected_at_any_depth(self):
        for field in sorted(INTERNAL_PATH_FIELDS):
            for path in ("/synthetic-checks/execution.json", "synthetic-run/execution.json"):
                with self.subTest(field=field, path=path):
                    with self.assertRaisesRegex(ValueError, "Interner Prüfdateiverweis: nested.0." + field):
                        verify_metadata({"nested": [{field: path}]})

    def test_python_test_log_reference_is_rejected(self):
        for path in ("/synthetic-checks/tests.log", "synthetic-run/tests.log"):
            with self.subTest(path=path):
                with self.assertRaisesRegex(ValueError, "Interner Prüfdateiverweis: python_tests.evidence"):
                    verify_metadata({"python_tests": {"evidence": path, "passed": 3}})


class PublicationMetadataTests(unittest.TestCase):
    """Alle drei versionierten Nachweise erfüllen denselben Veröffentlichungsvertrag."""

    def test_versioned_metadata_contains_no_internal_file_references(self):
        for relative_file in METADATA_FILES:
            with self.subTest(file=relative_file):
                metadata = json.loads((REPOSITORY_DIRECTORY / relative_file).read_text(encoding="utf-8-sig"))
                verify_metadata(metadata)


if __name__ == "__main__":
    unittest.main()
