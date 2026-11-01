"""Gegenproben für Vollzähligkeit, Quellidentität und Zuordnungen der Methodenmatrix."""

import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("original_inventory", Path(__file__).parents[1] / "verify_original_test_inventory.py")
INVENTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INVENTORY)


class OriginalTestInventoryTests(unittest.TestCase):
    """Eine kleine Java-Fixture isoliert die jeweiligen Erkennungsfehler."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "src/test/java/example"
        self.directory.mkdir(parents=True)
        self.source = self.directory / "SampleTest.java"
        self.source.write_text('''package example;
public class SampleTest {
    // @Test public void fake() {}
    @Test(expected = IllegalArgumentException.class)
    public void realTest() { String braces = "} { @Test"; if (true) { check(); } }
}
''')
        self.actual = INVENTORY.inventory(self.root)
        self.matrix = {
            "source_commit": INVENTORY.SOURCE_COMMIT,
            "helpers": self.actual["helpers"],
            "classes": self.actual["classes"],
            "files": self.actual["files"],
            "methods": [{
                "source": self.actual["methods"][0], "classification": "covered",
                "contract": "Ungültige Eingabe wird abgelehnt.", "variants": ["Fehleingabe"],
                "reason": "Gleichwertige Assertion vorhanden.", "target": {"case": "real-case"},
                "evidence": [{"run_id": "isolierte-testfixture", "passed": True}],
            }],
        }

    def check(self, matrix=None):
        return INVENTORY.verify(self.root, self.matrix if matrix is None else matrix, check_commit=False)

    def test_valid_source_ignores_comments_and_string_braces(self):
        self.assertEqual(self.check()["methods"], 1)
        self.assertEqual(self.actual["methods"][0]["method"], "realTest")
        self.assertEqual(self.actual["methods"][0]["line"], 5)

    def test_missing_method_is_rejected(self):
        self.matrix["methods"].clear()
        with self.assertRaisesRegex(ValueError, "Abweichende Methoden"):
            self.check()

    def test_duplicate_method_is_rejected(self):
        self.matrix["methods"].append(copy.deepcopy(self.matrix["methods"][0]))
        with self.assertRaisesRegex(ValueError, "Doppelte Methoden"):
            self.check()

    def test_changed_method_body_is_rejected(self):
        self.source.write_text(self.source.read_text().replace("check();", "other();"))
        with self.assertRaisesRegex(ValueError, "Geänderte Originalmethode"):
            self.check()

    def test_changed_data_source_is_rejected(self):
        data = self.root / "src/test/resources/variants.csv"
        data.parent.mkdir(parents=True)
        data.write_text("zusätzliche Variante")
        with self.assertRaisesRegex(ValueError, "Testdatenquellen"):
            self.check()

    def test_unsupported_parameter_provider_is_rejected(self):
        self.source.write_text(self.source.read_text().replace("public class", "@RunWith(Parameterized.class)\npublic class"))
        with self.assertRaisesRegex(ValueError, "Testdatenquelle"):
            INVENTORY.inventory(self.root)

    def test_inherited_tests_require_explicit_mapping(self):
        base = self.directory / "BaseTest.java"
        base.write_text("package example; public class BaseTest { @Test public void inherited() {} }")
        self.source.write_text(self.source.read_text().replace("class SampleTest", "class SampleTest extends BaseTest"))
        with self.assertRaisesRegex(ValueError, "Geerbte Testmethoden"):
            INVENTORY.inventory(self.root)

    def test_lifecycle_base_without_tests_is_allowed(self):
        base = self.directory / "BaseTest.java"
        base.write_text("package example; public class BaseTest { @Before public void setup() {} }")
        self.source.write_text(self.source.read_text().replace("class SampleTest", "class SampleTest extends BaseTest"))
        actual = INVENTORY.inventory(self.root)
        self.assertEqual(len(actual["methods"]), 1)
        self.assertIn("src/test/java/example/BaseTest.java", actual["helpers"])

    def test_covered_without_evidence_is_rejected(self):
        self.matrix["methods"][0]["evidence"] = []
        with self.assertRaisesRegex(ValueError, "ohne Nachweis"):
            self.check()

    def test_unknown_classification_is_rejected(self):
        self.matrix["methods"][0]["classification"] = "maybe"
        with self.assertRaisesRegex(ValueError, "Klassifikation"):
            self.check()

    def test_missing_variants_are_rejected(self):
        self.matrix["methods"][0]["variants"] = []
        with self.assertRaisesRegex(ValueError, "Unbegründete Zuordnung"):
            self.check()

    def test_missing_source_directory_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Originalverzeichnis"):
            INVENTORY.inventory(self.root / "missing")


if __name__ == "__main__":
    unittest.main()
