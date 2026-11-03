"""Die im Repository enthaltenen Prüfregeln müssen ohne externe Regelquelle nutzbar sein."""

import json
from pathlib import Path
import unittest
from xml.etree import ElementTree

from Tests.reference_corpus import validate_rules


ROOT = Path(__file__).resolve().parents[1]
VALIDATION = ROOT / "build/Validation"
SCENARIO_NAMESPACE = {"scenario": "http://www.xoev.de/de/validator/framework/1/scenarios"}


class BundledValidationTests(unittest.TestCase):
    """Reale Regeldateien und ihre Ressourcen gehören zum überprüften Quellstand."""

    def test_bundled_rules_match_reference_lock(self):
        """Unbeabsichtigt fehlende oder veränderte Dateien werden vor Referenzläufen erkannt."""
        lock = json.loads((ROOT / "Tests/Fixtures/reference/rule-hashes.json").read_text(encoding="utf-8"))
        scenarios = validate_rules(VALIDATION, lock)
        self.assertEqual(len(scenarios), 3)

    def test_scenario_resources_are_available_locally(self):
        """Ein frischer Klon benötigt keine weiteren Downloads für referenzierte Prüfressourcen."""
        lock = json.loads((ROOT / "Tests/Fixtures/reference/rule-hashes.json").read_text(encoding="utf-8"))
        for relative in lock["scenarios"]:
            scenario = VALIDATION / relative
            document = ElementTree.parse(scenario)
            resources = document.findall(".//scenario:resource/scenario:location", SCENARIO_NAMESPACE)
            self.assertTrue(resources, relative)
            for resource in resources:
                with self.subTest(scenario=relative, resource=resource.text):
                    location = (scenario.parent / resource.text).resolve()
                    self.assertTrue(location.is_relative_to(VALIDATION.resolve()))
                    self.assertTrue(location.is_file())

    def test_rule_licenses_and_notices_are_present(self):
        """Das technische Regelpaket behält die mitgeführten Weitergabehinweise."""
        for relative in ("ThirdParty/Validation/XRechnung-LICENSE", "ThirdParty/Validation/XRechnung-NOTICE",
                         "ThirdParty/Validation/EN16931-EUPL.txt", "ThirdParty/Validation/SOURCES.md",
                         "build/Validation/validator-configuration-zugferd/LICENSE"):
            with self.subTest(file=relative):
                self.assertTrue((ROOT / relative).read_bytes())


if __name__ == "__main__":
    unittest.main()
