program PipelineTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.DateUtils, System.Hash, System.NetEncoding, System.Win.ComObj,
  Winapi.MSXML, MGKositTypes, MGKositValidator;

type
  // Read ist implementiert; jeder Seek würde die zugesicherte Stream-Eigenschaft verletzen.
  TReadOnlySequentialStream = class(TStream)
  private
    FContent: TBytes;
    FOffset, FReadCalls, FSeekCalls: Integer;
  public
    constructor Create(const Content: TBytes);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property ReadCalls: Integer read FReadCalls;
    property SeekCalls: Integer read FSeekCalls;
  end;

  TPipelineTestSuite = class
  private
    FLibraryFile, FUpstreamRoot, FEvidenceDirectory, FDefaultHash: string;
    FDefaultValidator, FErrorValidator: TMGKositValidator;
    FEvidence: TJSONObject;
    FCases: TJSONArray;
    FActual: TMGKositValidationResult;
    FPassed, FFailed: Integer;
    function UpstreamFile(const RelativeName: string): string;
    function InputFile(const Name: string): string;
    function CreateConfigured(const ScenarioName, RepositoryName: string): TMGKositValidator;
    function ParseXml(const Xml: string): IXMLDOMDocument3;
    function XmlText(const Xml, Expression: string): string;
    function XmlHas(const Xml, Expression: string): Boolean;
    procedure Require(const Condition: Boolean; const MessageText: string);
    procedure CheckResult(const ExpectedStatus: Char; const ExpectedAcceptance: TMGKositAcceptance;
      const ExpectedSchema, ExpectedProcessingError, RequireReport: Boolean);
    procedure RunCase(const Name, SourceExpectation: string; const Action: TProc);
    procedure CheckDocumentReplacement;
    procedure ExecuteCases;
  public
    constructor Create(const LibraryFile, UpstreamRoot, EvidenceDirectory: string);
    destructor Destroy; override;
    function Execute: Integer;
  end;

// Die Testdaten bleiben unverändert, der Stream besitzt nur seine eigene Bytekopie.
constructor TReadOnlySequentialStream.Create(const Content: TBytes);
begin
  inherited Create;
  FContent := Copy(Content);
end;

// Kurze Leseportionen prüfen zusätzlich, dass der Aufrufer bis EOF liest.
function TReadOnlySequentialStream.Read(var Buffer; Count: Longint): Longint;
begin
  Inc(FReadCalls);
  Result := Length(FContent) - FOffset;
  if Result > Count then
    Result := Count;
  if Result > 37 then
    Result := 37;
  if Result > 0 then
  begin
    Move(FContent[FOffset], Buffer, Result);
    Inc(FOffset, Result);
  end;
end;

// Die Testquelle ist ausschließlich lesbar.
function TReadOnlySequentialStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('Der Teststream ist schreibgeschützt');
end;

// Auch indirekte Size-/Position-Abfragen würden hier nachweisbar scheitern.
function TReadOnlySequentialStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Inc(FSeekCalls);
  raise EStreamError.Create('Der Teststream unterstützt kein Seek');
end;

// Evidence enthält ausschließlich Artefakte dieses Testprogramms.
constructor TPipelineTestSuite.Create(const LibraryFile, UpstreamRoot, EvidenceDirectory: string);
begin
  inherited Create;
  FLibraryFile := ExpandFileName(LibraryFile);
  FUpstreamRoot := ExpandFileName(UpstreamRoot);
  FEvidenceDirectory := ExpandFileName(EvidenceDirectory);
  FEvidence := TJSONObject.Create;
  FCases := TJSONArray.Create;
  FEvidence.AddPair('tests', FCases);
end;

// COM-Dokumente sind auf Methoden begrenzt und vor dem Validatorabbau freigegeben.
destructor TPipelineTestSuite.Destroy;
begin
  FreeAndNil(FErrorValidator);
  FreeAndNil(FDefaultValidator);
  FreeAndNil(FEvidence);
  inherited;
end;

// UpstreamRoot bezeichnet das unveränderte KoSIT-Git-Repository.
function TPipelineTestSuite.UpstreamFile(const RelativeName: string): string;
begin
  Result := TPath.Combine(FUpstreamRoot, StringReplace(RelativeName, '/', PathDelim, [rfReplaceAll]));
end;

// Die Standardfälle verwenden dieselben Dateien wie Helper.Simple im Original.
function TPipelineTestSuite.InputFile(const Name: string): string;
begin
  Result := UpstreamFile('src/test/resources/examples/simple/input/' + Name);
end;

// Konfigurationsfehler werden weitergereicht und können keinen erwarteten Validierungsstatus vortäuschen.
function TPipelineTestSuite.CreateConfigured(const ScenarioName, RepositoryName: string): TMGKositValidator;
begin
  Result := TMGKositValidator.Create(FLibraryFile);
  try
    Result.AddScenario(UpstreamFile(ScenarioName), UpstreamFile(RepositoryName));
  except
    FreeAndNil(Result);
    raise;
  end;
end;

// Die Assertion liest nur zurückgegebene lokale Berichtstrings, ohne externe Entitäten.
function TPipelineTestSuite.ParseXml(const Xml: string): IXMLDOMDocument3;
begin
  Result := CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
  Result.async := False;
  Result.validateOnParse := False;
  Result.resolveExternals := False;
  Result.setProperty('ProhibitDTD', True);
  Result.setProperty('SelectionLanguage', 'XPath');
  Result.setProperty('SelectionNamespaces', 'xmlns:in="http://www.xoev.de/de/validator/framework/1/createreportinput" ' +
    'xmlns:s="http://www.xoev.de/de/validator/framework/1/scenarios" xmlns:t="http://validator.kosit.de/test-sample" ' +
    'xmlns:r="http://validator.kosit.de/test-report" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:svrl="http://purl.oclc.org/dsdl/svrl"');
  Require(Boolean(Result.loadXML(Xml)), 'Bericht ist kein lesbares XML: ' + string(Result.parseError.reason));
end;

// Ein fehlender Knoten ist nur bei einer gezielten Nichtvorhandenheitsprüfung zulässig.
function TPipelineTestSuite.XmlText(const Xml, Expression: string): string;
var
  Document: IXMLDOMDocument3;
  Node: IXMLDOMNode;
begin
  Document := ParseXml(Xml);
  Node := Document.selectSingleNode(Expression);
  Require(Node <> nil, 'Erwarteter Berichtsknoten fehlt: ' + Expression);
  Result := Node.text;
end;

// XPath-Prüfungen unterscheiden echte Ergebnisse von bloßen Texttreffern.
function TPipelineTestSuite.XmlHas(const Xml, Expression: string): Boolean;
var
  Document: IXMLDOMDocument3;
begin
  Document := ParseXml(Xml);
  Result := Document.selectSingleNode(Expression) <> nil;
end;

// Fehlgeschlagene Anforderungen werden vom Fallrunner ausdrücklich als Fehler gezählt.
procedure TPipelineTestSuite.Require(const Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

// Status und Annahme werden getrennt geprüft, weil acceptMatch Schematronfehler überstimmen darf.
procedure TPipelineTestSuite.CheckResult(const ExpectedStatus: Char; const ExpectedAcceptance: TMGKositAcceptance;
  const ExpectedSchema, ExpectedProcessingError, RequireReport: Boolean);
begin
  Require(KositStatus(FActual) = ExpectedStatus, 'Status erwartet ' + ExpectedStatus + ', erhalten ' + KositStatus(FActual) + ': ' + FActual.ErrorMessage);
  Require(FActual.Acceptance = ExpectedAcceptance, 'Abweichende Annahmeentscheidung');
  Require(FActual.SchemaValid = ExpectedSchema, 'Abweichendes XSD-Ergebnis');
  Require(FActual.ProcessingError = ExpectedProcessingError, 'Abweichender Verarbeitungsstatus: ' + FActual.ErrorMessage);
  Require(FActual.ReportInputXml <> '', 'Berichtseingabe fehlt');
  Require(XmlText(FActual.ReportInputXml, '/in:createReportInput/in:engine/in:name').StartsWith('MGGM XML Validator für Delphi '),
    'Die Berichtseingabe muss die MGGM-Projektbezeichnung ausweisen');
  if RequireReport then
    Require(FActual.ReportXml <> '', 'Originalbericht fehlt: ' + FActual.ErrorMessage);
end;

// Jede Ausnahme ist ein fehlgeschlagener Test; die tatsächlichen Artefakte bleiben für die Diagnose erhalten.
procedure TPipelineTestSuite.RunCase(const Name, SourceExpectation: string; const Action: TProc);
var
  CaseEvidence: TJSONObject;
  Passed: Boolean;
  Diagnostic: string;
begin
  FActual := Default(TMGKositValidationResult);
  Passed := False;
  Diagnostic := '';
  try
    Action();
    Passed := True;
    Inc(FPassed);
  except
    on Error: Exception do
    begin
      Inc(FFailed);
      Diagnostic := Error.ClassName + ': ' + Error.Message;
    end;
  end;
  CaseEvidence := TJSONObject.Create;
  CaseEvidence.AddPair('name', Name);
  CaseEvidence.AddPair('source_expectation', SourceExpectation);
  CaseEvidence.AddPair('passed', TJSONBool.Create(Passed));
  CaseEvidence.AddPair('diagnostic', Diagnostic);
  CaseEvidence.AddPair('status', string(KositStatus(FActual)));
  CaseEvidence.AddPair('acceptance', TJSONNumber.Create(Ord(FActual.Acceptance)));
  CaseEvidence.AddPair('schema_valid', TJSONBool.Create(FActual.SchemaValid));
  CaseEvidence.AddPair('processing_error', TJSONBool.Create(FActual.ProcessingError));
  CaseEvidence.AddPair('error_message', FActual.ErrorMessage);
  CaseEvidence.AddPair('findings', TJSONNumber.Create(Length(FActual.Findings)));
  CaseEvidence.AddPair('warnings', TJSONNumber.Create(FActual.Warnings));
  CaseEvidence.AddPair('errors', TJSONNumber.Create(FActual.Errors));
  FCases.AddElement(CaseEvidence);
  if FActual.ReportInputXml <> '' then
    TFile.WriteAllText(TPath.Combine(FEvidenceDirectory, Name + '-reportInput.xml'), FActual.ReportInputXml, TEncoding.UTF8);
  if FActual.ReportXml <> '' then
    TFile.WriteAllText(TPath.Combine(FEvidenceDirectory, Name + '-report.xml'), FActual.ReportXml, TEncoding.UTF8);
  if FActual.ReportHtml <> '' then
    TFile.WriteAllText(TPath.Combine(FEvidenceDirectory, Name + '-report.html'), FActual.ReportHtml, TEncoding.UTF8);
  WriteLn(Name, ': ', BoolToStr(Passed, True), ' ', Diagnostic);
end;

// Dieselbe Validatorinstanz muss neue Originalbytes am selben Pfad auch nach einem Parserfehler lesen.
procedure TPipelineTestSuite.CheckDocumentReplacement;
var
  ReplacementFile: string;
  PreviousHash: string;
  StepEvidence: TJSONArray;

  // Der erwartete Hash stammt aus der unveränderten Fixture, nicht aus dem überschriebenen Prüfpfad.
  procedure ValidateReplacement(const FixtureName, StepName: string; const ExpectedStatus: Char; const ExpectedAcceptance: TMGKositAcceptance;
    const ExpectedSchema, ExpectedProcessingError: Boolean; const ExpectedRoot: string);
  var
    FixtureStream: TFileStream;
    ExpectedHash, ActualHash: string;
    Step: TJSONObject;
  begin
    TFile.WriteAllBytes(ReplacementFile, TFile.ReadAllBytes(InputFile(FixtureName)));
    FixtureStream := TFileStream.Create(InputFile(FixtureName), fmOpenRead or fmShareDenyWrite);
    try
      ExpectedHash := TNetEncoding.Base64.EncodeBytesToString(THashSHA2.GetHashBytes(FixtureStream));
    finally
      FreeAndNil(FixtureStream);
    end;
    FActual := FDefaultValidator.ValidateFile(ReplacementFile, FixtureName);
    Step := TJSONObject.Create;
    StepEvidence.AddElement(Step);
    Step.AddPair('name', StepName);
    Step.AddPair('fixture', FixtureName);
    Step.AddPair('status', string(KositStatus(FActual)));
    Step.AddPair('expected_hash', ExpectedHash);
    TFile.WriteAllText(TPath.Combine(FEvidenceDirectory, 'same-path-' + StepName + '-reportInput.xml'), FActual.ReportInputXml, TEncoding.UTF8);
    TFile.WriteAllText(TPath.Combine(FEvidenceDirectory, 'same-path-' + StepName + '-report.xml'), FActual.ReportXml, TEncoding.UTF8);
    CheckResult(ExpectedStatus, ExpectedAcceptance, ExpectedSchema, ExpectedProcessingError, True);
    ActualHash := XmlText(FActual.ReportInputXml, '/in:createReportInput/in:documentIdentification/in:documentHash/in:hashValue');
    Step.AddPair('actual_hash', ActualHash);
    Require(ActualHash = ExpectedHash, 'Der Bericht verwendet einen veralteten Dokumenthash für ' + FixtureName);
    Require(ActualHash <> PreviousHash, 'Zwei unterschiedliche Dokumentfassungen haben denselben Berichtshash.');
    PreviousHash := ActualHash;
    if ExpectedProcessingError then
    begin
      Require(XmlHas(FActual.ReportInputXml, '//in:processingError/in:error'), 'Der neue Parserfehler fehlt in der Berichtseingabe.');
      Require(FActual.ErrorMessage <> '', 'Der Parserfehler blieb unsichtbar.');
      Require(not XmlHas(FActual.ReportXml, '/r:report/r:input/t:simple | /r:report/r:input/t:foo'), 'Der Fehlerbericht enthält eine vorherige Eingabe.');
    end
    else
    begin
      Require(XmlHas(FActual.ReportXml, '/r:report/r:input/t:' + ExpectedRoot), 'Der Bericht enthält ein vorheriges Quelldokument.');
      Require(not XmlHas(FActual.ReportInputXml, '//in:processingError/in:error'), 'Ein vorheriger Verarbeitungsfehler blieb erhalten.');
    end;
  end;

begin
  ReplacementFile := TPath.Combine(FEvidenceDirectory, 'same-path-document.xml');
  PreviousHash := '';
  StepEvidence := TJSONArray.Create;
  FEvidence.AddPair('same_path_steps', StepEvidence);
  ValidateReplacement('simple.xml', 'valid', 'V', kaAccept, True, False, 'simple');
  Require(Length(FActual.Findings) = 0, 'Die gültige Ausgangsfassung enthält Befunde.');
  ValidateReplacement('foo-schematron-invalid.xml', 'invalid', 'E', kaReject, True, False, 'foo');
  Require((Length(FActual.Findings) = 1) and (FActual.Findings[0].Code = 'content-2'), 'Die neue Fassung enthält nicht den erwarteten Schematronfehler.');
  ValidateReplacement('simple-not-wellformed.xml', 'parse-error', 'F', kaReject, False, True, '');
  ValidateReplacement('simple.xml', 'valid-after-error', 'V', kaAccept, True, False, 'simple');
  Require(Length(FActual.Findings) = 0, 'Ein Befund aus einer vorherigen Fassung blieb erhalten.');
end;

// Erwartungen stammen aus den genannten Originaltests und der dokumentierten Original-Aktionsreihenfolge.
procedure TPipelineTestSuite.ExecuteCases;
begin
  RunCase('default-valid', 'DefaultCheckTest.testHappyCase/testExtractHtml; CreateReportAction input-document',
    procedure
    begin
      FActual := FDefaultValidator.ValidateFile(InputFile('simple.xml'), 'Originalreferenz.xml');
      CheckResult('V', kaAccept, True, False, True);
      Require(Length(FActual.Findings) = 0, 'Gültige Eingabe erzeugt Befunde');
      Require(XmlHas(FActual.ReportXml, '/r:report/r:input/t:simple'), 'Original-Dokumentparameter fehlt');
      Require(XmlText(FActual.ReportXml, '/r:report/r:text') = 'This content should be transferred to the result document', 'unparsed-text fehlt');
      Require(XmlHas(FActual.ReportHtml, '/h:html/h:body/h:div'), 'XHTML ohne data-report-type wurde nicht extrahiert');
      Require(FActual.DocumentReference = 'Originalreferenz.xml', 'Explizite Dokumentreferenz ging verloren');
      Require(XmlText(FActual.ReportInputXml, '/in:createReportInput/in:documentIdentification/in:documentReference') = FActual.DocumentReference,
        'Referenz im Bericht abweichend');
      FDefaultHash := XmlText(FActual.ReportInputXml, '/in:createReportInput/in:documentIdentification/in:documentHash/in:hashValue');
      Require(FDefaultHash <> '', 'Dokumenthash fehlt');
    end);
  RunCase('schema-invalid', 'ComputeAcceptanceActionTest.testValidAcceptMatchOnSchemaFailed; SchematronValidationAction.isSkipped',
    procedure
    begin
      FActual := FDefaultValidator.ValidateFile(InputFile('simple-schema-invalid.xml'));
      CheckResult('E', kaReject, False, False, True);
      Require(FActual.Errors > 0, 'XSD-Befund fehlt');
      Require(not XmlHas(FActual.ReportInputXml, '//in:validationResultsSchematron'), 'Schematron lief trotz ungültigem XSD');
    end);
  RunCase('without-acceptmatch-valid', 'DefaultCheckTest.testWithoutAcceptMatch',
    procedure
    begin
      FActual := FDefaultValidator.ValidateFile(InputFile('foo.xml'));
      CheckResult('V', kaAccept, True, False, True);
    end);
  RunCase('without-acceptmatch-invalid', 'DefaultCheckTest.testSchematronFailedWithoutAcceptMatch',
    procedure
    begin
      FActual := FDefaultValidator.ValidateFile(InputFile('foo-schematron-invalid.xml'));
      CheckResult('E', kaReject, True, False, True);
      Require((Length(FActual.Findings) = 1) and (FActual.Findings[0].Code = 'content-2'), 'Originalassertion content-2 fehlt');
    end);
  RunCase('acceptmatch-overrides-assertion', 'DefaultCheckTest.testSchematronFailed; MGKositTypes Statusvertrag bei error',
    procedure
    begin
      FActual := FDefaultValidator.ValidateFile(InputFile('simple-schematron-invalid.xml'));
      CheckResult('E', kaAccept, True, False, True);
      Require((Length(FActual.Findings) = 1) and (FActual.Findings[0].Code = 'content-1'), 'Originalassertion content-1 fehlt');
    end);
  RunCase('manual-reject-without-findings', 'DefaultCheckTest.testRejectAcceptMatch',
    procedure
    begin
      FActual := FDefaultValidator.ValidateFile(InputFile('withManualReject.xml'));
      CheckResult('E', kaReject, True, False, True);
      Require(Length(FActual.Findings) = 0, 'Manuelle Ablehnung erzeugt erfundene Befunde');
    end);
  RunCase('unknown-without-findings', 'DefaultCheckTest.testNoScenario',
    procedure
    begin
      FActual := FDefaultValidator.ValidateFile(InputFile('unknown.xml'));
      CheckResult('E', kaReject, False, False, True);
      Require((FActual.ScenarioName = '') and (Length(FActual.Findings) = 0), 'Unbekanntes Dokument erhielt Szenario oder Befunde');
    end);
  RunCase('malformed-with-report', 'DefaultCheckTest.testNotWellFormed',
    procedure
    begin
      FActual := FDefaultValidator.ValidateFile(InputFile('simple-not-wellformed.xml'));
      CheckResult('F', kaReject, False, True, True);
      Require(XmlHas(FActual.ReportInputXml, '//in:processingError/in:error'), 'Parserfehler fehlt in Berichtseingabe');
    end);
  RunCase('schematron-runtime-with-report', 'DefaultCheckTest.testSchematronExecutionError',
    procedure
    begin
      FActual := FErrorValidator.ValidateFile(InputFile('simple.xml'));
      CheckResult('F', kaUndefined, True, True, True);
      Require(XmlHas(FActual.ReportInputXml, '//in:processingError/in:error'), 'Schematron-Ausführungsfehler fehlt');
      Require(XmlHas(FActual.ReportInputXml, '//in:results/svrl:schematron-output'), 'Originaler Fehler-Ergebniscontainer fehlt');
    end);
  RunCase('custom-warning', 'DefaultCheckTest.testCustomFailedAssertsWarning',
    procedure
    begin
      FActual := FErrorValidator.ValidateFile(InputFile('foo-custom-level-error.xml'));
      CheckResult('W', kaAccept, True, False, True);
      Require((Length(FActual.Findings) = 1) and (FActual.Findings[0].Code = 'content-2'), 'CustomLevel betrifft falsche Assertion');
      Require((FActual.Findings[0].Level = 'warning') and (FActual.Warnings = 1) and (FActual.Errors = 0), 'CustomLevel warning wurde nicht übernommen');
    end);
  RunCase('relative-repository', 'CommandlineApplicationTest.testValidMinimalConfigurationWithoutRepositoryPath',
    procedure
    var
      Validator: TMGKositValidator;
    begin
      Validator := TMGKositValidator.Create(FLibraryFile);
      try
        Validator.AddScenario(UpstreamFile('src/test/resources/examples/simple/scenarios-with-relative-paths.xml'));
        FActual := Validator.ValidateFile(InputFile('simple.xml'));
        CheckResult('V', kaAccept, True, False, True);
      finally
        FreeAndNil(Validator);
      end;
    end);
  RunCase('ambiguous-matches', 'ScenarioRepository.selectScenario; ScenarioSelectionAction.determineScenario',
    procedure
    var
      Validator: TMGKositValidator;
    begin
      Validator := CreateConfigured('src/test/resources/examples/simple/scenarios.xml', 'src/test/resources/examples/simple/repository');
      try
        Validator.AddScenario(UpstreamFile('src/test/resources/examples/simple/scenarios.xml'), UpstreamFile('src/test/resources/examples/simple/repository'));
        FActual := Validator.ValidateFile(InputFile('simple.xml'));
        CheckResult('E', kaReject, False, False, True);
        Require((FActual.ScenarioName = '') and (Length(FActual.Findings) = 0), 'Mehrere Matches wurden willkürlich aufgelöst');
      finally
        FreeAndNil(Validator);
      end;
    end);
  RunCase('identity-without-create-report', 'ConfigurationLoader.initialize: createIdentityTransformation bei fehlendem createReport',
    procedure
    var
      Validator: TMGKositValidator;
      Document: IXMLDOMDocument3;
      Nodes: IXMLDOMNodeList;
      Node: IXMLDOMNode;
      Index: Integer;
      ConfigurationFile: string;
    begin
      Document := ParseXml(TFile.ReadAllText(UpstreamFile('src/test/resources/examples/simple/scenarios.xml'), TEncoding.UTF8));
      Nodes := Document.selectNodes('/s:scenarios/s:scenario/s:createReport');
      for Index := Nodes.length - 1 downto 0 do
      begin
        Node := Nodes.item[Index];
        Node.parentNode.removeChild(Node);
      end;
      ConfigurationFile := TPath.Combine(FEvidenceDirectory, 'identity-scenarios.xml');
      TFile.WriteAllText(ConfigurationFile, Document.xml, TEncoding.UTF8);
      Validator := TMGKositValidator.Create(FLibraryFile);
      try
        Validator.AddScenario(ConfigurationFile, UpstreamFile('src/test/resources/examples/simple/repository'));
        FActual := Validator.ValidateFile(InputFile('simple.xml'));
        CheckResult('V', kaAccept, True, False, True);
        Require(XmlHas(FActual.ReportXml, '/in:createReportInput/in:validationResultsSchematron'), 'Identitätsbericht wurde ersetzt');
        Require(FActual.ReportHtml = '', 'Identitätsbericht erzeugt erfundenes HTML');
      finally
        FreeAndNil(Validator);
      end;
    end);
  RunCase('nonseekable-stream', 'ValidateStream-Vertrag; DefaultCheckTest.testHappyCase; identische Originalbytes',
    procedure
    var
      Stream: TReadOnlySequentialStream;
    begin
      Stream := TReadOnlySequentialStream.Create(TFile.ReadAllBytes(InputFile('simple.xml')));
      try
        FActual := FDefaultValidator.ValidateStream(Stream, 'Nicht seekbarer Stream.xml');
        CheckResult('V', kaAccept, True, False, True);
        Require((Stream.ReadCalls > 2) and (Stream.SeekCalls = 0), 'Stream wurde nicht ausschließlich sequentiell gelesen');
        Require(FActual.DocumentReference = 'Nicht seekbarer Stream.xml', 'Streamreferenz ging verloren');
        Require(FDefaultHash <> '', 'Datei-Gegenprobe für den Hash fehlt');
        Require(XmlText(FActual.ReportInputXml, '/in:createReportInput/in:documentIdentification/in:documentHash/in:hashValue') = FDefaultHash, 'Streambytes wurden verändert');
      finally
        FreeAndNil(Stream);
      end;
    end);
  RunCase('same-path-document-replacement-after-parse-error', 'ValidateFile-Dokumentkontext; unveränderte HappyCase-, Schematron- und Parserfehler-Fixtures',
    procedure
    begin
      CheckDocumentReplacement;
    end);
  RunCase('upstream-xslt-runtime-fixture', 'CommandlineApplicationTest.testValidMinimalConfigurationXSLTRuntimeError; SchematronValidationAction',
    procedure
    var
      Validator: TMGKositValidator;
    begin
      Validator := TMGKositValidator.Create(FLibraryFile);
      try
        Validator.AddScenario(UpstreamFile('src/test/resources/examples/invalid/xslt-runtime-error/scenarios-with-xslt-runtime-error.xml'));
        FActual := Validator.ValidateFile(UpstreamFile('src/test/resources/examples/invalid/xslt-runtime-error/input/simple-xslt-runtime-error.xml'));
        CheckResult('F', kaUndefined, True, True, False);
        Require(XmlHas(FActual.ReportInputXml, '//in:processingError/in:error'), 'Originaler XSLT-Ausführungsfehler fehlt');
        Require(FActual.ErrorMessage <> '', 'Ausführungsfehler blieb unsichtbar');
      finally
        FreeAndNil(Validator);
      end;
    end);
end;

// Ein Setupfehler zählt gesondert; kein Fall kann dadurch als bestanden erscheinen.
function TPipelineTestSuite.Execute: Integer;
var
  SetupFailure: TJSONObject;
begin
  TDirectory.CreateDirectory(FEvidenceDirectory);
  FEvidence.AddPair('started_at', DateToISO8601(Now, False));
  FEvidence.AddPair('upstream_root', FUpstreamRoot);
  try
    FDefaultValidator := CreateConfigured('src/test/resources/examples/simple/scenarios.xml', 'src/test/resources/examples/simple/repository');
    FErrorValidator := CreateConfigured('src/test/resources/examples/simple/scenarios-with-errors.xml', 'src/test/resources/examples/simple/repository');
    ExecuteCases;
  except
    on Error: Exception do
    begin
      Inc(FFailed);
      SetupFailure := TJSONObject.Create;
      SetupFailure.AddPair('name', 'suite-infrastructure');
      SetupFailure.AddPair('passed', TJSONBool.Create(False));
      SetupFailure.AddPair('diagnostic', Error.ClassName + ': ' + Error.Message);
      FCases.AddElement(SetupFailure);
    end;
  end;
  FEvidence.AddPair('passed', TJSONNumber.Create(FPassed));
  FEvidence.AddPair('failed', TJSONNumber.Create(FFailed));
  FEvidence.AddPair('total', TJSONNumber.Create(FPassed + FFailed));
  TFile.WriteAllText(TPath.Combine(FEvidenceDirectory, 'pipeline-tests.json'), FEvidence.ToJSON, TEncoding.UTF8);
  Result := Ord(FFailed <> 0);
end;

// Aufruf: PipelineTests LibraryFile UpstreamRoot EvidenceDirectory.
procedure Run;
var
  Suite: TPipelineTestSuite;
begin
  if ParamCount <> 3 then
    raise Exception.Create('Aufruf: PipelineTests LibraryFile UpstreamRoot EvidenceDirectory');
  Suite := TPipelineTestSuite.Create(ParamStr(1), ParamStr(2), ParamStr(3));
  try
    ExitCode := Suite.Execute;
  finally
    FreeAndNil(Suite);
  end;
end;

begin
  SetTextCodePage(Output, 65001);
  SetTextCodePage(ErrOutput, 65001);
  try
    Run;
  except
    on Error: Exception do
    begin
      WriteLn(ErrOutput, Error.ClassName, ': ', Error.Message);
      ExitCode := 1;
    end;
  end;
end.
