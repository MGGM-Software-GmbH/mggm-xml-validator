"""Vergleicht eingebettete Frameworkressourcen unverändert mit ihren Originalbytes."""

import base64
import binascii
from pathlib import Path
import re
import tempfile
import unittest


SOURCE_DIRECTORY = Path(__file__).resolve().parents[1] / "Source"
FRAMEWORK_RESOURCES = {
    "FrameworkScenariosSchemaBase64": "scenarios.xsd",
    "FrameworkReportInputSchemaBase64": "createReportInput.xsd",
    "FrameworkSvrlSchemaBase64": "svrl-kosit.xsd",
    "FrameworkXmlNamespaceSchemaBase64": "xml.xsd",
    "FrameworkIdentityStylesheetBase64": "identity.xsl",
}
PASCAL_STRING = r"'(?:[^']|'')*'"


def verify_resource(source, constant_name, original_path):
    """Nur verkettete Pascal-Stringliterale zulassen und strikt bytegleich prüfen."""
    # Kommentare dürfen weder eine fehlende Deklaration ersetzen noch Nutzdaten ändern.
    uncommented = re.sub(
        PASCAL_STRING + r"|//[^\r\n]*|\{[^}]*\}|\(\*.*?\*\)",
        lambda match: match.group() if match.group().startswith("'") else " ",
        source,
        flags=re.DOTALL,
    )
    declarations = re.findall(
        rf"^\s*{re.escape(constant_name)}\s*=\s*(.*?);",
        uncommented,
        flags=re.MULTILINE | re.DOTALL | re.IGNORECASE,
    )
    if not declarations:
        raise AssertionError(f"Konstante fehlt: {constant_name}")
    if len(declarations) != 1:
        raise AssertionError(f"Konstante mehrfach deklariert: {constant_name}")
    expression = declarations[0]
    if re.fullmatch(rf"{PASCAL_STRING}(?:\s*\+\s*{PASCAL_STRING})*\s*", expression) is None:
        raise AssertionError(f"Ungültiger Pascal-Stringausdruck: {constant_name}")
    encoded = "".join(literal[1:-1].replace("''", "'") for literal in re.findall(PASCAL_STRING, expression))
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise AssertionError(f"Ungültiges Base64: {constant_name}: {error}") from error
    if base64.b64encode(decoded).decode("ascii") != encoded:
        raise AssertionError(f"Nicht kanonisches Base64: {constant_name}")
    if not original_path.is_file():
        raise AssertionError(f"Originaldatei fehlt: {original_path}")
    original = original_path.read_bytes()
    if decoded != original:
        raise AssertionError(
            f"Byteabweichung: {constant_name} / {original_path.name} "
            f"(eingebettet {len(decoded)} Bytes, Original {len(original)} Bytes)"
        )


class FrameworkResourceTests(unittest.TestCase):
    """Alle fünf tatsächlichen Delphi-Konstanten müssen ihre Originaldateien abbilden."""

    def test_embedded_resources_match_original_files(self):
        """XML-Inhalte und Zeilenenden werden ausschließlich als Bytes verglichen."""
        source = (SOURCE_DIRECTORY / "MGKositValidator.pas").read_text(encoding="utf-8-sig")
        for constant_name, filename in FRAMEWORK_RESOURCES.items():
            with self.subTest(constant=constant_name, file=filename):
                verify_resource(source, constant_name, SOURCE_DIRECTORY / filename)


class FrameworkResourceVerifierTests(unittest.TestCase):
    """Isolierte Gegenproben belegen die Fehlererkennung ohne Produktdateiänderungen."""

    def setUp(self):
        """Binäre Fixture mit BOM, Umlaut und CRLF vermeidet XML-Normalisierung."""
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.original_path = Path(temporary.name) / "fixture.xsd"
        self.original_bytes = b"\xef\xbb\xbf<schema>\xc3\xa4</schema>\r\n"
        self.original_path.write_bytes(self.original_bytes)
        encoded = base64.b64encode(self.original_bytes).decode("ascii")
        self.source = f"const\n  FixtureBase64 =\n    '{encoded[:9]}' +\n    '{encoded[9:]}';\n"

    def test_valid_multiline_concatenation(self):
        """Der gültige Fall muss einschließlich unveränderter Binärbytes bestehen."""
        verify_resource(self.source, "FixtureBase64", self.original_path)

    def test_missing_constant(self):
        """Andere und auskommentierte Deklarationen dürfen fehlende Namen nicht ersetzen."""
        for comment in ("// FixtureBase64 = 'YQ==';\n", "{FixtureBase64 = 'YQ==';}\n", "(*FixtureBase64 = 'YQ==';*)\n"):
            with self.subTest(comment=comment), self.assertRaisesRegex(AssertionError, "Konstante fehlt: FixtureBase64"):
                verify_resource(comment + "OtherBase64 = 'YQ==';", "FixtureBase64", self.original_path)

    def test_invalid_base64(self):
        """Ungültige Zeichen, Leerraum, Padding und Nicht-ASCII dürfen nicht durchgehen."""
        for encoded in ("!A==", "Y Q==", "YQ=", "YQ==!", "äA=="):
            with self.subTest(encoded=encoded), self.assertRaisesRegex(AssertionError, "Ungültiges Base64: FixtureBase64"):
                verify_resource(f"FixtureBase64 = '{encoded}';", "FixtureBase64", self.original_path)

    def test_noncanonical_base64(self):
        """Zusätzliches Padding und ungenutzte gesetzte Paddingbits werden erkannt."""
        for encoded in ("YWJj====", "YR=="):
            with self.subTest(encoded=encoded), self.assertRaisesRegex(AssertionError, "Nicht kanonisches Base64"):
                verify_resource(f"FixtureBase64 = '{encoded}';", "FixtureBase64", self.original_path)

    def test_missing_original_file(self):
        """Eine gültige Einbettung benötigt trotzdem die zugehörige Originaldatei."""
        with self.assertRaisesRegex(AssertionError, "Originaldatei fehlt"):
            verify_resource(self.source, "FixtureBase64", self.original_path.with_name("missing.xsd"))

    def test_changed_original_bytes(self):
        """Inhaltsänderungen und allein abweichende Zeilenenden müssen scheitern."""
        for changed in (self.original_bytes.replace(b"schema", b"Schema"), self.original_bytes.replace(b"\r\n", b"\n")):
            with self.subTest(changed=changed), self.assertRaisesRegex(AssertionError, "Byteabweichung"):
                self.original_path.write_bytes(changed)
                verify_resource(self.source, "FixtureBase64", self.original_path)

    def test_malformed_pascal_expression(self):
        """Nichtliteral-Ausdrücke dürfen nicht nur anhand enthaltener Literale bestehen."""
        with self.assertRaisesRegex(AssertionError, "Ungültiger Pascal-Stringausdruck"):
            verify_resource("FixtureBase64 = 'YQ==' + OtherConstant;", "FixtureBase64", self.original_path)

    def test_duplicate_constant(self):
        """Doppelte Deklarationen dürfen keine beliebige Auswahl des Inhalts erlauben."""
        with self.assertRaisesRegex(AssertionError, "Konstante mehrfach deklariert"):
            verify_resource(self.source + self.source, "FixtureBase64", self.original_path)


if __name__ == "__main__":
    unittest.main()
