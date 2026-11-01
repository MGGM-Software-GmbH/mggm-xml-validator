unit MGKositTypes;

interface

type
  TMGKositAcceptance = (kaUndefined, kaAccept, kaReject);

  TMGKositFinding = record
    Level, Code, Text, Location, ValidationStep: string;
  end;

  // Kumulative Erzeugungszähler machen die Wiederverwendung der Prüfobjekte messbar.
  TMGKositStatistics = record
    SchemaCompilationCount, StylesheetCompilationCount, XPathProcessorCount, SourceParseCount: Integer;
    SchemaCompilationMs, SchemaValidationMs, XPathMs, TransformationMs, DocumentParsingMs, SvrlProjectionMs: Double;
    DomMs, WorkingDirectoryMs, TemporaryCleanupMs: Double;
  end;

  TMGKositValidationResult = record
    Acceptance: TMGKositAcceptance;
    ProcessingError: Boolean;
    ErrorMessage, ScenarioName, DocumentReference, ReportXml, ReportHtml, ReportInputXml: string;
    Findings: TArray<TMGKositFinding>;
    SchemaValid: Boolean;
    Warnings, Errors: Integer;
  end;

function KositStatus(const Validation: TMGKositValidationResult): Char;

implementation

uses
  System.SysUtils;

const
  UnitName = 'MGKositTypes';

// Verarbeitungsfehler haben Vorrang vor der fachlichen Annahmeentscheidung.
function KositStatus(const Validation: TMGKositValidationResult): Char;
var
  Finding: TMGKositFinding;
  HasWarning, HasError: Boolean;
begin
  if Validation.ProcessingError or (Validation.Acceptance = kaUndefined) then
    Exit('F');
  HasWarning := Validation.Warnings > 0;
  HasError := Validation.Errors > 0;
  for Finding in Validation.Findings do
  begin
    HasWarning := HasWarning or SameText(Finding.Level, 'warning') or SameText(Finding.Level, 'warn');
    HasError := HasError or SameText(Finding.Level, 'error') or SameText(Finding.Level, 'fatal');
  end;
  if (Validation.Acceptance = kaReject) or HasError then
    Result := 'E'
  else if HasWarning then
    Result := 'W'
  else
    Result := 'V';
end;

end.
