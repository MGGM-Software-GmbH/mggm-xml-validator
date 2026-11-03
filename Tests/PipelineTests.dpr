program PipelineTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.DateUtils, System.Hash, System.NetEncoding, System.RegularExpressions, System.Win.ComObj,
  Winapi.MSXML, MGKositTypes, MGKositValidator, MGKositEngine;

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
    FValidationRoot, FPublicValidFile, FBusinessInvalidFile: string;
    FDefaultValidator, FErrorValidator: TMGKositValidator;
    FEvidence: TJSONObject;
    FCases: TJSONArray;
    FActual: TMGKositValidationResult;
    FPassed, FFailed: Integer;
    function UpstreamFile(const RelativeName: string): string;
    function InputFile(const Name: string): string;
    function CreateConfigured(const ScenarioName, RepositoryName: string): TMGKositValidator;
    function CreateContractValidator(const Name, AcceptExpression, Assertions: string): TMGKositValidator;
    function ParseXml(const Xml: string): IXMLDOMDocument3;
    function XmlText(const Xml, Expression: string): string;
    function XmlHas(const Xml, Expression: string): Boolean;
    function WithoutTimestamp(const Xml: string): string;
    procedure Require(const Condition: Boolean; const MessageText: string);
    procedure CheckResult(const ExpectedStatus: Char; const ExpectedAcceptance: TMGKositAcceptance;
      const ExpectedSchema, ExpectedProcessingError, RequireReport: Boolean);
    procedure RunCase(const Name, SourceExpectation: string; const Action: TProc);
    procedure CheckDocumentReplacement;
    procedure CheckConfigurationContracts;
    procedure CheckVersionContracts;
    procedure CheckReportInputSchemas;
    procedure CheckInputContracts;
    procedure CheckFirstFallback;
    procedure CheckSchemaOnly;
    procedure CheckReportRuntime;
    procedure CheckSvrlProjection(const Variant: Integer);
    procedure CheckUpdatedXRechnung(const InvalidBusinessRules: Boolean);
    procedure ExecuteCases;
  public
    constructor Create(const LibraryFile, UpstreamRoot, EvidenceDirectory: string;
      const ValidationRoot, PublicValidFile, BusinessInvalidFile: string);
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
constructor TPipelineTestSuite.Create(const LibraryFile, UpstreamRoot, EvidenceDirectory: string;
  const ValidationRoot, PublicValidFile, BusinessInvalidFile: string);
begin
  inherited Create;
  FLibraryFile := ExpandFileName(LibraryFile);
  FUpstreamRoot := ExpandFileName(UpstreamRoot);
  FEvidenceDirectory := ExpandFileName(EvidenceDirectory);
  FValidationRoot := ValidationRoot;
  FPublicValidFile := PublicValidFile;
  FBusinessInvalidFile := BusinessInvalidFile;
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

// Eigene, kleine XML-Fixtures isolieren Annahme und Befundmultimenge von Rechnungsregeln.
function TPipelineTestSuite.CreateContractValidator(const Name, AcceptExpression, Assertions: string): TMGKositValidator;
var
  DirectoryName, Configuration, AcceptElement: string;
begin
  DirectoryName := TPath.Combine(FEvidenceDirectory, Name);
  TDirectory.CreateDirectory(DirectoryName);
  TFile.WriteAllText(TPath.Combine(DirectoryName, 'input.xml'), '<contract>valid</contract>', TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(DirectoryName, 'schema.xsd'),
    '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:element name="contract" type="xs:string"/></xs:schema>', TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(DirectoryName, 'rules.xsl'),
    '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:svrl="http://purl.oclc.org/dsdl/svrl" version="2.0">' +
    '<xsl:template match="/"><svrl:schematron-output>' + Assertions + '</svrl:schematron-output></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(DirectoryName, 'identity.xsl'),
    '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="2.0">' +
    '<xsl:template match="/"><xsl:copy-of select="."/></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
  AcceptElement := '';
  if AcceptExpression <> '' then
    AcceptElement := '<acceptMatch>' + AcceptExpression + '</acceptMatch>';
  Configuration := '<scenarios xmlns="http://www.xoev.de/de/validator/framework/1/scenarios" frameworkVersion="1.1.2">' +
    '<name>Contract tests</name><date>2026-11-01</date><description><p>Generierte Vertragsfixtures</p></description>' +
    '<scenario><name>Contract</name><match>/contract</match><validateWithXmlSchema><resource><name>Schema</name>' +
    '<location>schema.xsd</location></resource></validateWithXmlSchema><validateWithSchematron><resource><name>Contract rules</name>' +
    '<location>rules.xsl</location></resource></validateWithSchematron>' + AcceptElement + '</scenario>' +
    '<noScenarioReport><resource><name>Identity</name><location>identity.xsl</location></resource></noScenarioReport></scenarios>';
  TFile.WriteAllText(TPath.Combine(DirectoryName, 'scenarios.xml'), Configuration, TEncoding.UTF8);
  Result := TMGKositValidator.Create(FLibraryFile);
  try
    Result.AddScenario(TPath.Combine(DirectoryName, 'scenarios.xml'), DirectoryName);
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

// Nur das ausgewiesene volatile Frameworkfeld darf Datei-/Stream-Gleichheit nicht beeinflussen.
function TPipelineTestSuite.WithoutTimestamp(const Xml: string): string;
var
  Document: IXMLDOMDocument3;
  Nodes: IXMLDOMNodeList;
  Node: IXMLDOMNode;
  Index: Integer;
begin
  Document := ParseXml(Xml);
  Nodes := Document.selectNodes('//in:timestamp');
  for Index := Nodes.length - 1 downto 0 do
  begin
    Node := Nodes.item[Index];
    Node.parentNode.removeChild(Node);
  end;
  Result := Document.xml;
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

// Jeder unzulässige Konfigurationszustand muss vor Registrierung scheitern und eine anschließende gültige Registrierung erlauben.
procedure TPipelineTestSuite.CheckConfigurationContracts;
const
  ScenarioNamespace = 'http://www.xoev.de/de/validator/framework/1/scenarios';
var
  Validator: TMGKositValidator;
  DirectoryName, ConfigurationFile, OriginalConfiguration, Diagnostic, ExpectedToken, RemovePath: string;
  Document: IXMLDOMDocument3;
  Node: IXMLDOMNode;
  VariantIndex: Integer;
  Rejected: Boolean;
begin
  Validator := CreateContractValidator('configuration-contracts', 'true()', '');
  FreeAndNil(Validator);
  DirectoryName := TPath.Combine(FEvidenceDirectory, 'configuration-contracts');
  ConfigurationFile := TPath.Combine(DirectoryName, 'scenarios.xml');
  OriginalConfiguration := TFile.ReadAllText(ConfigurationFile, TEncoding.UTF8);
  for VariantIndex := 0 to 10 do
  begin
    Document := ParseXml(OriginalConfiguration);
    RemovePath := '';
    case VariantIndex of
      0: begin RemovePath := '/s:scenarios/s:noScenarioReport'; ExpectedToken := 'noScenarioReport'; end;
      1: begin RemovePath := '//s:validateWithXmlSchema'; ExpectedToken := 'validateWithXmlSchema'; end;
      2: begin RemovePath := '//s:match'; ExpectedToken := 'match'; end;
      3: begin Document.selectSingleNode('//s:match').text := '/////'; ExpectedToken := 'match'; end;
      4: begin Document.selectSingleNode('//s:acceptMatch').text := '/////'; ExpectedToken := 'acceptMatch'; end;
      5: begin RemovePath := '//s:validateWithSchematron/s:resource'; ExpectedToken := 'validateWithSchematron'; end;
      6: begin
        Node := Document.createNode(NODE_ELEMENT, 'createReport', ScenarioNamespace);
        Document.selectSingleNode('//s:scenario').insertBefore(Node, Document.selectSingleNode('//s:acceptMatch'));
        ExpectedToken := 'createReport';
      end;
      7: begin Document.selectSingleNode('//s:validateWithSchematron/s:resource/s:location').text := 'absent-schematron.xsl'; ExpectedToken := 'absent-schematron.xsl'; end;
      8: begin
        Node := ParseXml('<createReport xmlns="' + ScenarioNamespace + '"><resource><name>Missing report</name>' +
          '<location>absent-report.xsl</location></resource></createReport>').documentElement;
        Document.selectSingleNode('//s:scenario').insertBefore(Document.importNode(Node, True), Document.selectSingleNode('//s:acceptMatch'));
        ExpectedToken := 'absent-report.xsl';
      end;
      9: begin Document.selectSingleNode('//s:validateWithXmlSchema/s:resource/s:location').text := 'absent-schema.xsd'; ExpectedToken := 'absent-schema.xsd'; end;
      10: begin RemovePath := '//s:validateWithXmlSchema/s:resource'; ExpectedToken := 'validateWithXmlSchema'; end;
    end;
    if RemovePath <> '' then
    begin
      Node := Document.selectSingleNode(RemovePath);
      Require(Node <> nil, 'Konfigurationsgegenprobe besitzt keinen Zielknoten');
      Node.parentNode.removeChild(Node);
    end;
    TFile.WriteAllText(ConfigurationFile, Document.xml, TEncoding.UTF8);
    TFile.WriteAllText(TPath.Combine(DirectoryName, 'rejected-' + IntToStr(VariantIndex) + '.xml'), Document.xml, TEncoding.UTF8);
    Validator := TMGKositValidator.Create(FLibraryFile);
    try
      Rejected := False;
      Diagnostic := '';
      try
        Validator.AddScenario(ConfigurationFile, DirectoryName);
      except
        on Error: Exception do
        begin
          Rejected := True;
          Diagnostic := Error.Message;
        end;
      end;
      Require(Rejected, 'Konfigurationsvariante ' + IntToStr(VariantIndex) + ' wurde nicht abgelehnt');
      Require(Pos(LowerCase(ExpectedToken), LowerCase(Diagnostic)) > 0, 'Konfigurationsvariante ' + IntToStr(VariantIndex) + ' ohne passende Diagnose: ' + Diagnostic);
      Require(Validator.ScenarioCount = 0, 'Defekte Konfiguration wurde teilweise registriert');
      FEvidence.AddPair('configuration_contract_' + IntToStr(VariantIndex), Diagnostic);
      TFile.WriteAllText(ConfigurationFile, OriginalConfiguration, TEncoding.UTF8);
      Validator.AddScenario(ConfigurationFile, DirectoryName);
      Require(Validator.ScenarioCount = 1, 'Gültige Registrierung nach Konfigurationsfehler fehlt');
      FActual := Validator.ValidateFile(TPath.Combine(DirectoryName, 'input.xml'));
      CheckResult('V', kaAccept, True, False, True);
    finally
      FreeAndNil(Validator);
    end;
  end;
end;

// Versionsfixtures bleiben unverändert; neutrale lokale Dateien erfüllen nur die zusätzlichen Ressourcenprüfungen der Delphi-API.
procedure TPipelineTestSuite.CheckVersionContracts;
const
  VersionNames: array[0..3] of string = ('base', 'increment', 'newfeature', 'newversion');
var
  Validator: TMGKositValidator;
  DirectoryName, ResourcePath, Diagnostic: string;
  Document: IXMLDOMDocument3;
  Resources: IXMLDOMNodeList;
  VersionIndex, ResourceIndex: Integer;
  Rejected: Boolean;
begin
  DirectoryName := TPath.Combine(FEvidenceDirectory, 'version-resources');
  TDirectory.CreateDirectory(DirectoryName);
  Document := ParseXml(TFile.ReadAllText(UpstreamFile('src/test/resources/examples/versioning/scenarios-base.xml'), TEncoding.UTF8));
  Resources := Document.selectNodes('//*[local-name()="location"]');
  for ResourceIndex := 0 to Resources.length - 1 do
  begin
    ResourcePath := TPath.Combine(DirectoryName, StringReplace(Resources.item[ResourceIndex].text, '/', PathDelim, [rfReplaceAll]));
    TDirectory.CreateDirectory(ExtractFileDir(ResourcePath));
    TFile.WriteAllText(ResourcePath, '<unused/>', TEncoding.UTF8);
  end;
  for VersionIndex := Low(VersionNames) to High(VersionNames) do
  begin
    Validator := TMGKositValidator.Create(FLibraryFile);
    try
      Rejected := False;
      Diagnostic := '';
      try
        Validator.AddScenario(UpstreamFile('src/test/resources/examples/versioning/scenarios-' + VersionNames[VersionIndex] + '.xml'), DirectoryName);
      except
        on Error: Exception do
        begin
          Rejected := True;
          Diagnostic := Error.Message;
        end;
      end;
      Require(Rejected = (VersionIndex >= 2), 'Unerwartetes Ergebnis der unveränderten Versionsfixture ' + VersionNames[VersionIndex] + ': ' + Diagnostic);
      if Rejected then
      begin
        Require((Pos('Konfiguration', Diagnostic) > 0) and (Validator.ScenarioCount = 0), 'Versionsfehler ohne Diagnose oder mit teilweiser Registrierung');
        FEvidence.AddPair('version_failure_' + VersionNames[VersionIndex], Diagnostic);
      end
      else
        Require(Validator.ScenarioCount > 0, 'Kompatible Originalfixture hat kein Szenario registriert');
    finally
      FreeAndNil(Validator);
    end;
  end;
end;

// Ein unabhängiger Engineaufruf prüft die tatsächlichen Berichtseingaben gegen das lokale Original-XSD samt Imports.
procedure TPipelineTestSuite.CheckReportInputSchemas;
const
  Inputs: array[0..2] of string = ('simple.xml', 'simple-schema-invalid.xml', 'simple-not-wellformed.xml');
var
  Engine: TMGKositEngine;
  Index: Integer;
  SchemaDirectory, Diagnostic: string;
  InvalidReport: IXMLDOMDocument3;
  RequiredNode: IXMLDOMNode;
begin
  SchemaDirectory := UpstreamFile('src/main/model/xsd');
  Engine := TMGKositEngine.Create(FLibraryFile);
  try
    Engine.ConfigureResourceRoots([SchemaDirectory]);
    for Index := Low(Inputs) to High(Inputs) do
    begin
      FActual := FDefaultValidator.ValidateFile(InputFile(Inputs[Index]));
      Require(FActual.ReportInputXml <> '', 'Berichtseingabe für XSD-Prüfung fehlt');
      Require(Engine.ValidateDocumentSchemas(ParseXml(FActual.ReportInputXml), [TPath.Combine(SchemaDirectory, 'createReportInput.xsd')], Diagnostic),
        'Berichtseingabe ' + Inputs[Index] + ' verletzt das Originalschema: ' + Diagnostic);
    end;
    InvalidReport := ParseXml(FActual.ReportInputXml);
    RequiredNode := InvalidReport.selectSingleNode('/in:createReportInput/in:documentIdentification');
    RequiredNode.parentNode.removeChild(RequiredNode);
    Require(not Engine.ValidateDocumentSchemas(InvalidReport, [TPath.Combine(SchemaDirectory, 'createReportInput.xsd')], Diagnostic),
      'Die XSD-Gegenprobe akzeptierte eine Berichtseingabe ohne Dokumentidentifikation');
    Require(Diagnostic <> '', 'Die XSD-Gegenprobe blieb ohne Fehlerdiagnose');
  finally
    FreeAndNil(Engine);
  end;
end;

// Die Delphi-Validierungs-API liefert technische Fehler im Ergebnis; Java-Factory-Ausnahmen sind kein zusätzlicher API-Vertrag.
procedure TPipelineTestSuite.CheckInputContracts;
begin
  FActual := FDefaultValidator.ValidateStream(nil, 'nil-stream.xml');
  Require((KositStatus(FActual) = 'F') and (FActual.Acceptance = kaUndefined) and FActual.ProcessingError, 'Fehlender Stream wurde als Dokument angenommen');
  Require(Pos('XML-Stream fehlt', FActual.ErrorMessage) > 0, 'Diagnose des fehlenden Streams fehlt');
  Require((FActual.ReportXml = '') and (FActual.ReportHtml = '') and (Length(FActual.Findings) = 0), 'Fehlender Stream besitzt erfundene Dokumentergebnisse');
  FActual := FDefaultValidator.ValidateFile(InputFile('simple.xml'));
  CheckResult('V', kaAccept, True, False, True);
  FActual := FDefaultValidator.ValidateFile(TPath.Combine(FEvidenceDirectory, 'absent-input.xml'));
  Require((KositStatus(FActual) = 'F') and (FActual.Acceptance = kaUndefined) and FActual.ProcessingError, 'Fehlende Datei wurde als Dokument angenommen');
  Require(Pos('absent-input.xml', FActual.ErrorMessage) > 0, 'Fehlende Datei wurde ohne Pfad diagnostiziert');
  Require((FActual.ReportXml = '') and (FActual.ReportHtml = '') and (Length(FActual.Findings) = 0), 'Fehlende Datei besitzt alte Dokumentergebnisse');
  FActual := FDefaultValidator.ValidateFile(InputFile('simple.xml'));
  CheckResult('V', kaAccept, True, False, True);
end;

// Zwei unterscheidbare Fallbackberichte machen die Reihenfolge der geladenen Konfigurationen öffentlich beobachtbar.
procedure TPipelineTestSuite.CheckFirstFallback;
var
  First, Second: TMGKositValidator;
  FirstDirectory, SecondDirectory: string;
begin
  First := CreateContractValidator('fallback-first', 'true()', '');
  Second := CreateContractValidator('fallback-second', 'true()', '');
  try
    FirstDirectory := TPath.Combine(FEvidenceDirectory, 'fallback-first');
    SecondDirectory := TPath.Combine(FEvidenceDirectory, 'fallback-second');
    TFile.WriteAllText(TPath.Combine(FirstDirectory, 'identity.xsl'),
      '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="2.0"><xsl:template match="/"><first-fallback/></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
    TFile.WriteAllText(TPath.Combine(SecondDirectory, 'identity.xsl'),
      '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="2.0"><xsl:template match="/"><second-fallback/></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
    First.AddScenario(TPath.Combine(SecondDirectory, 'scenarios.xml'), SecondDirectory);
    FActual := First.ValidateFile(InputFile('unknown.xml'));
    CheckResult('E', kaReject, False, False, True);
    Require(XmlHas(FActual.ReportXml, '/first-fallback') and not XmlHas(FActual.ReportXml, '/second-fallback'), 'Fallback stammt nicht aus der ersten Konfiguration');
    Require(not XmlHas(FActual.ReportInputXml, '//s:scenario | //in:validationResultsXmlSchema | //in:validationResultsSchematron'), 'Fallback führte eine Fachprüfung aus');
  finally
    FreeAndNil(Second);
    FreeAndNil(First);
  end;
end;

// Schematron ist optional; ohne diese Phase entscheidet das tatsächlich ausgeführte Schema über die Annahme.
procedure TPipelineTestSuite.CheckSchemaOnly;
var
  Validator: TMGKositValidator;
  Document: IXMLDOMDocument3;
  Node: IXMLDOMNode;
  DirectoryName, ConfigurationFile: string;
begin
  Validator := CreateContractValidator('schema-only', '', '');
  FreeAndNil(Validator);
  DirectoryName := TPath.Combine(FEvidenceDirectory, 'schema-only');
  ConfigurationFile := TPath.Combine(DirectoryName, 'scenarios.xml');
  Document := ParseXml(TFile.ReadAllText(ConfigurationFile, TEncoding.UTF8));
  Node := Document.selectSingleNode('//s:validateWithSchematron');
  Node.parentNode.removeChild(Node);
  TFile.WriteAllText(ConfigurationFile, Document.xml, TEncoding.UTF8);
  Validator := TMGKositValidator.Create(FLibraryFile);
  try
    Validator.AddScenario(ConfigurationFile, DirectoryName);
    FActual := Validator.ValidateFile(TPath.Combine(DirectoryName, 'input.xml'));
    CheckResult('V', kaAccept, True, False, True);
    Require(XmlHas(FActual.ReportInputXml, '//in:validationResultsXmlSchema') and not XmlHas(FActual.ReportInputXml, '//in:validationResultsSchematron'),
      'Optionale Schematronphase wurde erfunden oder Pflichtschema übersprungen');
    Require(Length(FActual.Findings) = 0, 'Schema-only-Eingabe erzeugte Befunde');
  finally
    FreeAndNil(Validator);
  end;
end;

// Das Reportstylesheet löst nur für die gezielte Eingabe einen realen Fehler aus und bleibt für den Folgeaufruf verwendbar.
procedure TPipelineTestSuite.CheckReportRuntime;
var
  Validator: TMGKositValidator;
  DirectoryName, ConfigurationFile, Configuration: string;
begin
  Validator := CreateContractValidator('report-runtime', 'true()', '');
  FreeAndNil(Validator);
  DirectoryName := TPath.Combine(FEvidenceDirectory, 'report-runtime');
  ConfigurationFile := TPath.Combine(DirectoryName, 'scenarios.xml');
  Configuration := TFile.ReadAllText(ConfigurationFile, TEncoding.UTF8);
  Configuration := StringReplace(Configuration, '<acceptMatch>',
    '<createReport><resource><name>Runtime report</name><location>report.xsl</location></resource></createReport><acceptMatch>', []);
  TFile.WriteAllText(ConfigurationFile, Configuration, TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(DirectoryName, 'report.xsl'),
    '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="2.0"><xsl:param name="input-document"/>' +
    '<xsl:template match="/"><xsl:if test="$input-document/contract = ''trigger-report-error''">' +
    '<xsl:message terminate="yes">REPORT-RUNTIME-FAILURE</xsl:message></xsl:if><report-success/></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
  Validator := TMGKositValidator.Create(FLibraryFile);
  try
    Validator.AddScenario(ConfigurationFile, DirectoryName);
    FActual := Validator.ValidateFile(TPath.Combine(DirectoryName, 'input.xml'));
    CheckResult('V', kaAccept, True, False, True);
    TFile.WriteAllText(TPath.Combine(DirectoryName, 'input.xml'), '<contract>trigger-report-error</contract>', TEncoding.UTF8);
    FActual := Validator.ValidateFile(TPath.Combine(DirectoryName, 'input.xml'));
    CheckResult('F', kaUndefined, True, True, False);
    Require(FActual.ErrorMessage <> '', 'Berichtsfehler blieb ohne Diagnose');
    Require((FActual.ReportXml = '') and (FActual.ReportHtml = ''), 'Nach Berichtsfehler wurde ein alter Erfolgsbericht zurückgegeben');
    FEvidence.AddPair('report_runtime_diagnostic', FActual.ErrorMessage);
    TFile.WriteAllText(TPath.Combine(DirectoryName, 'input.xml'), '<contract>recovered</contract>', TEncoding.UTF8);
    FActual := Validator.ValidateFile(TPath.Combine(DirectoryName, 'input.xml'));
    CheckResult('V', kaAccept, True, False, True);
    Require(XmlHas(FActual.ReportXml, '/report-success'), 'Bericht nach Laufzeitfehler fehlt');
  finally
    FreeAndNil(Validator);
  end;
end;

// Nur die Berichtskopie darf auf das Frameworkmodell begrenzt werden; die Saxon-Ausgabe bleibt die Befundquelle.
procedure TPipelineTestSuite.CheckSvrlProjection(const Variant: Integer);
var
  Validator: TMGKositValidator;
  Engine: TMGKositEngine;
  Stream: TReadOnlySequentialStream;
  DirectoryName, Assertions, ConfigurationFile, Configuration, RawXml, Rules: string;
  InputBytes, RawBytes: TBytes;
  RawDocument: IXMLDOMDocument3;
begin
  DirectoryName := TPath.Combine(FEvidenceDirectory, 'svrl-projection-' + IntToStr(Variant));
  case Variant of
    0: Assertions := '<svrl:active-pattern id="before"/><svrl:metadata><svrl:failed-assert id="HIDDEN" test="false()" location="/contract" role="error">' +
      '<svrl:text>Kein direkter Befund</svrl:text></svrl:failed-assert></svrl:metadata><svrl:fired-rule context="contract"/>' +
      '<svrl:failed-assert id="CUSTOM" test="false()" location="/contract" flag="fatal" role="error"><svrl:text>Umgestufter Befund</svrl:text></svrl:failed-assert>';
    1: Assertions := '<svrl:extension><svrl:failed-assert id="WRAPPED" test="false()" location="/contract" role="error">' +
      '<svrl:text>Verschachtelter Befund</svrl:text></svrl:failed-assert></svrl:extension><svrl:active-pattern id="retained"/>';
    2: Assertions := '<svrl:diagnostic-reference diagnostic="WRONG-PARENT"><svrl:text>Falscher Elternknoten</svrl:text></svrl:diagnostic-reference>' +
      '<svrl:failed-assert id="DIRECT" test="false()" location="/contract" role="warning"><svrl:active-pattern id="wrong-child"/>' +
      '<svrl:text>Direkter Befund</svrl:text></svrl:failed-assert>';
    3: Assertions := '<svrl:failed-assert id="RICH" test="false()" location="/contract" role="warning">' +
      '<svrl:diagnostic-reference diagnostic="D1"><svrl:text>Diagnose</svrl:text></svrl:diagnostic-reference>' +
      '<svrl:property-reference property="P1"><svrl:text>Eigenschaft</svrl:text></svrl:property-reference>' +
      '<svrl:text xml:lang="de" xml:space="preserve" xmlns:ext="urn:projection-test" icon="behalten">Anfang ' +
      '<svrl:span class="notice">Mitte</svrl:span> danach <ext:payload ext:attribute="ä" xmlns:binding="urn:retained-binding" qname="binding:Value">' +
      '<svrl:active-pattern id="opaque"/><svrl:metadata>Fremdinhalt</svrl:metadata></ext:payload> danach ' +
      '<local-payload marker="lokal">Lokaler Inhalt</local-payload> Ende</svrl:text></svrl:failed-assert>';
    4: Assertions := '';
  else
    raise Exception.Create('Unbekannte SVRL-Testvariante');
  end;
  Validator := CreateContractValidator('svrl-projection-' + IntToStr(Variant), 'true()', Assertions);
  FreeAndNil(Validator);
  if Variant = 0 then
  begin
    ConfigurationFile := TPath.Combine(DirectoryName, 'scenarios.xml');
    Configuration := TFile.ReadAllText(ConfigurationFile, TEncoding.UTF8);
    Configuration := StringReplace(Configuration, '<acceptMatch>', '<createReport>' +
      '<resource><name>Identity</name><location>identity.xsl</location></resource><customLevel level="warning">CUSTOM</customLevel></createReport><acceptMatch>', []);
    TFile.WriteAllText(ConfigurationFile, Configuration, TEncoding.UTF8);
  end;
  if Variant = 4 then
  begin
    Rules := TFile.ReadAllText(TPath.Combine(DirectoryName, 'rules.xsl'), TEncoding.UTF8);
    Rules := StringReplace(Rules, 'svrl:schematron-output', 'svrl:metadata', [rfReplaceAll]);
    TFile.WriteAllText(TPath.Combine(DirectoryName, 'rules.xsl'), Rules, TEncoding.UTF8);
  end;
  InputBytes := TFile.ReadAllBytes(TPath.Combine(DirectoryName, 'input.xml'));
  Engine := TMGKositEngine.Create(FLibraryFile);
  try
    Engine.ConfigureResourceRoots([DirectoryName]);
    RawBytes := Engine.TransformBytes(InputBytes, TPath.Combine(DirectoryName, 'input.xml'), TPath.Combine(DirectoryName, 'rules.xsl'));
    RawDocument := Engine.LoadDocumentBytes(RawBytes);
    RawXml := RawDocument.xml;
    TFile.WriteAllBytes(TPath.Combine(DirectoryName, 'raw-saxon.xml'), RawBytes);
    Validator := TMGKositValidator.Create(FLibraryFile);
    try
      Validator.AddScenario(TPath.Combine(DirectoryName, 'scenarios.xml'), DirectoryName);
      Stream := TReadOnlySequentialStream.Create(InputBytes);
      try
        FActual := Validator.ValidateStream(Stream, 'svrl-projection.xml');
        Require((Stream.SeekCalls = 0) and (Stream.ReadCalls > 1), 'Die SVRL-Prüfung verletzte den nur lesbaren Eingabevertrag');
      finally
        FreeAndNil(Stream);
      end;
    finally
      FreeAndNil(Validator);
    end;
    if Variant = 4 then
    begin
      CheckResult('F', kaUndefined, True, True, False);
      Require(Pos('svrl:schematron-output', FActual.ErrorMessage) > 0, 'Falsches SVRL-Wurzelelement blieb ohne Diagnose');
      Exit;
    end;
    if Variant = 1 then
      CheckResult('V', kaAccept, True, False, True)
    else
      CheckResult('W', kaAccept, True, False, True);
    case Variant of
      0: begin
        Require(XmlHas(RawXml, '/svrl:schematron-output/svrl:metadata/svrl:failed-assert[@id="HIDDEN"]'), 'Saxon-Original enthält keine Metadaten');
        Require(not XmlHas(FActual.ReportInputXml, '//svrl:metadata'), 'Metadaten gelangten in die Berichtskopie');
        Require(XmlHas(FActual.ReportInputXml, '//svrl:active-pattern[@id="before"]/following-sibling::svrl:fired-rule[@context="contract"]'),
          'Bekannte Geschwister vor oder nach den Metadaten gingen verloren');
        Require((Length(FActual.Findings) = 1) and (FActual.Findings[0].Code = 'CUSTOM') and (FActual.Findings[0].Level = 'warning'),
          'Metadaten oder customLevel veränderten direkte Befunde');
        Require(XmlHas(FActual.ReportInputXml, '//svrl:failed-assert[@id="CUSTOM" and @flag="fatal" and @role="error"]'),
          'Die Berichtskopie verlor den ursprünglichen Schweregrad');
      end;
      1: begin
        Require(XmlHas(RawXml, '/svrl:schematron-output/svrl:extension/svrl:failed-assert'), 'Originaler unbekannter Wrapper fehlt');
        Require((Length(FActual.Findings) = 0) and not XmlHas(FActual.ReportInputXml, '//svrl:failed-assert | //svrl:extension'),
          'Unbekannter Wrapper wurde ausgepackt oder als direkter Befund gezählt');
        Require(XmlHas(FActual.ReportInputXml, '//svrl:active-pattern[@id="retained"]'), 'Bekannter Geschwisterknoten ging verloren');
      end;
      2: begin
        Require(not XmlHas(FActual.ReportInputXml, '//svrl:schematron-output/svrl:diagnostic-reference | //svrl:failed-assert/svrl:active-pattern'),
          'Global bekannte SVRL-Elemente blieben unter einem unzulässigen Elternknoten erhalten');
        Require((Length(FActual.Findings) = 1) and (FActual.Findings[0].Code = 'DIRECT'), 'Direkter Befund ging bei Elternprüfung verloren');
      end;
      3: begin
        Require(XmlText(FActual.ReportInputXml, '//svrl:failed-assert[@id="RICH"]/svrl:text') = 'Anfang Mitte danach Fremdinhalt danach Lokaler Inhalt Ende',
          'Rich-Text-Inhalt oder Textreihenfolge ging verloren');
        Require(XmlHas(FActual.ReportInputXml, '//svrl:text[@xml:lang="de" and @xml:space="preserve" and @icon="behalten"]' +
          '/*[local-name()="payload" and namespace-uri()="urn:projection-test" and @qname="binding:Value" and @*[local-name()="attribute"]="ä"]' +
          '[namespace::binding="urn:retained-binding"]/svrl:active-pattern[@id="opaque"]'), 'Wildcard-Attribute, Namensräume oder opaker SVRL-Inhalt gingen verloren');
        Require(XmlHas(FActual.ReportInputXml, '//svrl:text/*[local-name()="local-payload" and namespace-uri()="" and @marker="lokal" and text()="Lokaler Inhalt"]'),
          'Der lokale Wildcard-Unterbaum verlor Inhalt oder Attribute');
        Require(XmlHas(FActual.ReportInputXml, '//svrl:property-reference[@property="P1"]/svrl:text') and
          XmlHas(FActual.ReportInputXml, '//svrl:diagnostic-reference[@diagnostic="D1"]/svrl:text') and
          XmlHas(FActual.ReportInputXml, '//svrl:text/*[local-name()="payload"]/svrl:metadata'), 'Rich-Text-Referenzen oder Wildcard-Unterbaum gingen verloren');
        Require((Length(FActual.Findings) = 1) and (FActual.Findings[0].Code = 'RICH'), 'Opaker Wildcard-Inhalt wurde als Befund gezählt');
      end;
    end;
  finally
    RawDocument := nil;
    FreeAndNil(Engine);
  end;
end;

// Externe Regeln und beide fachlichen Eingaben werden ausdrücklich angegeben; gebündelte Ressourcen bleiben unverändert.
procedure TPipelineTestSuite.CheckUpdatedXRechnung(const InvalidBusinessRules: Boolean);
var
  Validator: TMGKositValidator;
  RepositoryDirectory: string;
  Finding: TMGKositFinding;
  ExpectedFinding, InformationFinding, WarningFinding: Boolean;
begin
  RepositoryDirectory := TPath.Combine(FValidationRoot, 'validator-configuration-xrechnung/3.0.2');
  Validator := TMGKositValidator.Create(FLibraryFile);
  try
    Validator.AddScenario(TPath.Combine(RepositoryDirectory, 'scenarios.xml'), RepositoryDirectory);
    if InvalidBusinessRules then
      FActual := Validator.ValidateFile(FBusinessInvalidFile)
    else
      FActual := Validator.ValidateFile(FPublicValidFile);
    ExpectedFinding := False;
    InformationFinding := False;
    WarningFinding := False;
    for Finding in FActual.Findings do
    begin
      InformationFinding := InformationFinding or ((Finding.Code = 'BR-DE-TMP-32') and (Finding.Level = 'information'));
      WarningFinding := WarningFinding or ((Finding.Code = 'BR-DE-17') and (Finding.Level = 'warning'));
      if InvalidBusinessRules then
        ExpectedFinding := ExpectedFinding or ((Finding.Code = 'BR-CL-01') and (Finding.Level = 'error'))
      else
        ExpectedFinding := ExpectedFinding or ((Finding.Code = 'BR-DE-TMP-32') and (Finding.Level = 'information'));
    end;
    Require(ExpectedFinding, 'Erwarteter fachlicher XRechnung-Befund fehlt');
    if InvalidBusinessRules then
    begin
      CheckResult('E', kaReject, True, False, True);
      Require(InformationFinding and WarningFinding and (Length(FActual.Findings) = 3) and (FActual.Errors = 1) and (FActual.Warnings = 1),
        'Die Befundmultimenge des abgelehnten Belegs unterscheidet sich von der aktuellen Java-Referenz');
    end
    else
    begin
      CheckResult('V', kaAccept, True, False, True);
      Require((Length(FActual.Findings) = 1) and (FActual.Errors = 0) and (FActual.Warnings = 0),
        'Die Befundmultimenge des akzeptierten Belegs unterscheidet sich von der aktuellen Java-Referenz');
    end;
    Require(XmlHas(FActual.ReportInputXml, '//svrl:schematron-output/svrl:failed-assert[@id="BR-DE-TMP-32" and @flag="information"]'),
      'Der ursprüngliche Informationsschweregrad ging in der Berichtskopie verloren');
    Require(not XmlHas(FActual.ReportInputXml, '//svrl:schematron-output/svrl:metadata'), 'Aktuelle Schematronmetadaten verletzen die Berichtskopie');
  finally
    FreeAndNil(Validator);
  end;
end;

// Erwartungen stammen aus den genannten Originaltests und der dokumentierten Original-Aktionsreihenfolge.
procedure TPipelineTestSuite.ExecuteCases;
begin
  RunCase('svrl-metadata-copy-and-custom-level', 'Aktuelle Schematronmetadaten; direkte Befunde und ursprüngliche Schweregrade bleiben erhalten',
    procedure begin CheckSvrlProjection(0); end);
  RunCase('svrl-unknown-wrapper-no-hoisting', 'Unbekannte SVRL-Unterbäume werden als Einheit verworfen und erzeugen keine direkten Befunde',
    procedure begin CheckSvrlProjection(1); end);
  RunCase('svrl-known-element-wrong-parent', 'Das tatsächliche SVRL-Inhaltsmodell bestimmt erlaubte Eltern-Kind-Beziehungen',
    procedure begin CheckSvrlProjection(2); end);
  RunCase('svrl-rich-text-wildcard-preservation', 'Rich-Text-Wildcards bewahren Attribute, Namensräume, Textreihenfolge und opaken SVRL-Inhalt',
    procedure begin CheckSvrlProjection(3); end);
  RunCase('svrl-wrong-root-processing-failure', 'Ein falsches SVRL-Wurzelelement bleibt ein technischer Fehler',
    procedure begin CheckSvrlProjection(4); end);
  if FValidationRoot <> '' then
  begin
    RunCase('updated-xrechnung-public-valid', 'Externe XRechnung 3.0.2 akzeptiert öffentliche UBL-Fixture mit BR-DE-TMP-32',
      procedure begin CheckUpdatedXRechnung(False); end);
    RunCase('updated-xrechnung-business-invalid', 'Externe XRechnung 3.0.2 lehnt BR-CL-01 fachlich ab',
      procedure begin CheckUpdatedXRechnung(True); end);
  end;
  RunCase('report-framework-version', 'CreateReportAction; createReportInput.xsd version 1.0.2 und Originalbericht',
    procedure
    begin
      FActual := FDefaultValidator.ValidateFile(InputFile('simple.xml'));
      CheckResult('V', kaAccept, True, False, True);
      Require(XmlText(FActual.ReportInputXml, '/in:createReportInput/@frameworkVersion') = '1.0.2', 'Berichtseingabe verwendet nicht Frameworkversion 1.0.2');
    end);
  RunCase('configuration-contracts', 'ConfigurationBuilderTest/ScenarioBuilderTest/SchemaBuilderTest/ContentRepositoryTest; Pflichtfelder, Ressourcen und XPathsyntax',
    procedure
    begin
      CheckConfigurationContracts;
    end);
  RunCase('framework-version-contracts', 'VersioningTest.testBase/testFrameworkIncrement/testNewFeature/testNewVersion; unveränderte Originalfixtures',
    procedure
    begin
      CheckVersionContracts;
    end);
  RunCase('invalid-input-contracts', 'InputFactoryTest.testNullStream/testUnexistingInput; öffentliche Delphi-Fehlerergebnisse und Wiederverwendung',
    procedure
    begin
      CheckInputContracts;
    end);
  RunCase('report-input-schema-validation', 'SchemaValidatorActionTest.testSchemaReferences; drei tatsächliche Berichtseingaben gegen das lokale Originalschema',
    procedure
    begin
      CheckReportInputSchemas;
    end);
  RunCase('first-configuration-fallback', 'ScenarioRepositoryTest.testFallbackOnMultipleConfigurations; sichtbarer Bericht der zuerst geladenen Konfiguration',
    procedure
    begin
      CheckFirstFallback;
    end);
  RunCase('schema-only-acceptance', 'ComputeAcceptanceActionTest.testNoSchematronCheck; Pflichtschema ausgeführt, optionale Schematronphase fehlt',
    procedure
    begin
      CheckSchemaOnly;
    end);
  RunCase('report-runtime-error', 'CreateReportActionTest.testExecutionException; realer Reportfehler mit Wiederverwendung',
    procedure
    begin
      CheckReportRuntime;
    end);
  RunCase('garbage-with-report', 'DefaultCheckTest.testGarbage; Nicht-XML-Bytes werden mit Bericht und Parserdiagnose abgelehnt',
    procedure
    var
      Stream: TBytesStream;
    begin
      Stream := TBytesStream.Create(TBytes.Create($00, $FF, $01, $42, $00, $FE));
      try
        FActual := FDefaultValidator.ValidateStream(Stream, 'garbage.bin');
        CheckResult('F', kaReject, False, True, True);
        Require(FActual.ErrorMessage <> '', 'Parserdiagnose für Nicht-XML-Bytes fehlt');
        Require(XmlHas(FActual.ReportInputXml, '//in:validationResultsWellformedness/in:xmlSyntaxError'), 'Nicht-XML-Bytes besitzen keine Wohlgeformtheitsdiagnose');
        Require(not XmlHas(FActual.ReportInputXml, '//s:scenario | //in:validationResultsXmlSchema | //in:validationResultsSchematron'), 'Nicht-XML-Eingabe hat Folgeprüfungen ausgeführt');
      finally
        FreeAndNil(Stream);
      end;
    end);
  RunCase('acceptmatch-false-with-schematron-error', 'ComputeAcceptanceActionTest.testAcceptMatchNotSatisfied; getrennte Annahme-, Status- und Schemaentscheidungen',
    procedure
    var
      Validator: TMGKositValidator;
    begin
      Validator := CreateContractValidator('accept-false', 'false()',
        '<svrl:failed-assert id="REJECT-1" test="false()" location="/contract" role="error"><svrl:text>Abgelehnte Regel</svrl:text></svrl:failed-assert>');
      try
        FActual := Validator.ValidateFile(TPath.Combine(FEvidenceDirectory, 'accept-false/input.xml'));
        CheckResult('E', kaReject, True, False, True);
        Require((Length(FActual.Findings) = 1) and (FActual.Findings[0].Code = 'REJECT-1') and (FActual.Errors = 1), 'Schematronfehler ging bei acceptMatch=false verloren');
      finally
        FreeAndNil(Validator);
      end;
    end);
  RunCase('acceptmatch-false-cannot-accept-invalid-schema', 'ComputeAcceptanceActionTest.testSchemaFailed/testValidAcceptMatchOnSchemaFailed; acceptMatch=false und ungültiges Schema',
    procedure
    var
      Validator: TMGKositValidator;
    begin
      Validator := CreateContractValidator('accept-false-schema', 'false()', '');
      try
        TFile.WriteAllText(TPath.Combine(FEvidenceDirectory, 'accept-false-schema/input.xml'), '<contract><unexpected/></contract>', TEncoding.UTF8);
        FActual := Validator.ValidateFile(TPath.Combine(FEvidenceDirectory, 'accept-false-schema/input.xml'));
        CheckResult('E', kaReject, False, False, True);
        Require((Length(FActual.Findings) = 1) and (FActual.Findings[0].Code = 'XML-SCHEMA'), 'Schemafehler ging bei acceptMatch=false verloren');
        Require(not XmlHas(FActual.ReportInputXml, '//in:validationResultsSchematron'), 'Schematron lief nach fehlgeschlagener Schemaprüfung');
      finally
        FreeAndNil(Validator);
      end;
    end);
  RunCase('finding-multiset-severity-location-and-identical-duplicates', 'SchematronValidationActionTest/CreateReportActionTest; vollständige Befundmultimenge und getrennte Schweregrade',
    procedure
    var
      Validator: TMGKositValidator;
      Index: Integer;
      Findings: IXMLDOMNodeList;
    begin
      Validator := CreateContractValidator('finding-multiset', 'true()',
        '<svrl:failed-assert id="SAME" test="false()" location="/contract/item[1]" role="error"><svrl:text>Identischer Befund ä</svrl:text></svrl:failed-assert>' +
        '<svrl:failed-assert id="SAME" test="false()" location="/contract/item[1]" role="error"><svrl:text>Identischer Befund ä</svrl:text></svrl:failed-assert>' +
        '<svrl:failed-assert id="SAME" test="false()" location="/contract/item[2]" role="error"><svrl:text>Andere Location</svrl:text></svrl:failed-assert>' +
        '<svrl:failed-assert id="WARN" test="false()" location="/contract" role="warning"><svrl:text>Warnung</svrl:text></svrl:failed-assert>' +
        '<svrl:successful-report id="INFO" test="true()" location="/contract" role="information"><svrl:text>Information</svrl:text></svrl:successful-report>');
      try
        FActual := Validator.ValidateFile(TPath.Combine(FEvidenceDirectory, 'finding-multiset/input.xml'));
        CheckResult('E', kaAccept, True, False, True);
        Require((Length(FActual.Findings) = 5) and (FActual.Errors = 3) and (FActual.Warnings = 1), 'Befundanzahl oder Schweregradzähler verändert');
        for Index := 0 to 4 do
          Require(FActual.Findings[Index].ValidationStep = 'Contract rules', 'Prüfphase eines Befunds ging verloren');
        for Index := 0 to 1 do
          Require((FActual.Findings[Index].Code = 'SAME') and (FActual.Findings[Index].Level = 'error') and
            (FActual.Findings[Index].Location = '/contract/item[1]') and (FActual.Findings[Index].Text = 'Identischer Befund ä'),
            'Identische doppelte Befunde wurden verändert oder zusammengefasst');
        Require((FActual.Findings[2].Code = 'SAME') and (FActual.Findings[2].Location = '/contract/item[2]') and
          (FActual.Findings[2].Level = 'error') and (FActual.Findings[2].Text = 'Andere Location'), 'Gleicher Code an anderer Location ging verloren');
        Require((FActual.Findings[3].Code = 'WARN') and (FActual.Findings[3].Level = 'warning') and
          (FActual.Findings[3].Location = '/contract') and (FActual.Findings[3].Text = 'Warnung'), 'Warnung wurde verändert');
        Require((FActual.Findings[4].Code = 'INFO') and (FActual.Findings[4].Level = 'information') and
          (FActual.Findings[4].Location = '/contract') and (FActual.Findings[4].Text = 'Information'), 'Information wurde verändert');
        Findings := ParseXml(FActual.ReportInputXml).selectNodes('//svrl:failed-assert | //svrl:successful-report');
        Require(Findings.length = 5, 'Berichtseingabe hat eine andere Befundmultimenge');
        Require(ParseXml(FActual.ReportXml).selectNodes('//svrl:failed-assert[@id="SAME" and @location="/contract/item[1]" and @role="error"]' +
          '/svrl:text[text()="Identischer Befund ä"]').length = 2, 'Der erzeugte Bericht hat identische Dubletten oder deren Felder verändert');
        Require(XmlHas(FActual.ReportXml, '//svrl:failed-assert[@id="WARN" and @location="/contract" and @role="warning"]/svrl:text[text()="Warnung"]'),
          'Der erzeugte Bericht hat Warnungsfelder verändert');
        Require(XmlHas(FActual.ReportXml, '//svrl:successful-report[@id="INFO" and @location="/contract" and @role="information"]/svrl:text[text()="Information"]'),
          'Der erzeugte Bericht hat Informationsfelder verändert');
      finally
        FreeAndNil(Validator);
      end;
    end);
  RunCase('configuration-errors-preserve-active-scenarios-and-recover', 'ConfigurationLoaderTest/ScenarioRepositoryTest; fehlende und ungültige Konfigurationen werden nicht als Ablehnung versteckt',
    procedure
    var
      Validator: TMGKositValidator;
      FileName, ExpectedToken, Diagnostic: string;
      Index: Integer;
      Rejected: Boolean;
    begin
      Validator := CreateContractValidator('configuration-recovery', 'true()', '');
      try
        for Index := 0 to 4 do
        begin
          FileName := TPath.Combine(FEvidenceDirectory, 'configuration-recovery/rejected-' + IntToStr(Index) + '.xml');
          ExpectedToken := 'rejected-' + IntToStr(Index) + '.xml';
          case Index of
            1: begin TFile.WriteAllText(FileName, '<scenarios>', TEncoding.UTF8); ExpectedToken := 'XML'; end;
            2: begin TFile.WriteAllText(FileName, '<scenarios/>', TEncoding.UTF8); ExpectedToken := 'Konfiguration'; end;
            3: begin
              TFile.WriteAllText(FileName, StringReplace(TFile.ReadAllText(TPath.Combine(FEvidenceDirectory, 'configuration-recovery/scenarios.xml')),
                'schema.xsd', 'absent-resource.xsd', []), TEncoding.UTF8);
              ExpectedToken := 'absent-resource.xsd';
            end;
            4: begin
              TFile.WriteAllText(FileName, '<scenarios xmlns="http://www.xoev.de/de/validator/framework/1/scenarios" frameworkVersion="1.1.2"/>', TEncoding.UTF8);
              ExpectedToken := 'Ungültige KoSIT-Konfiguration';
            end;
          end;
          Diagnostic := '';
          Rejected := False;
          try
            Validator.AddScenario(FileName, TPath.Combine(FEvidenceDirectory, 'configuration-recovery'));
          except
            on Error: Exception do
            begin
              Rejected := True;
              Diagnostic := Error.Message;
            end;
          end;
          Require(Rejected and (Diagnostic <> ''), 'Defekte Konfiguration erzeugte keinen Fehler');
          Require(Pos(LowerCase(ExpectedToken), LowerCase(Diagnostic)) > 0, 'Falsche Konfigurationsdiagnose: ' + Diagnostic);
          FEvidence.AddPair('configuration_failure_' + IntToStr(Index), Diagnostic);
          Require(Validator.ScenarioCount = 1, 'Fehlgeschlagene Konfiguration hat aktive Szenarien verändert');
          FActual := Validator.ValidateFile(TPath.Combine(FEvidenceDirectory, 'configuration-recovery/input.xml'));
          CheckResult('V', kaAccept, True, False, True);
        end;
      finally
        FreeAndNil(Validator);
      end;
    end);
  RunCase('missing-schema-import-is-processing-failure-and-recovers', 'SchemaValidatorActionTest; fehlender Import ist technischer Fehler, danach gültige Prüfung mit derselben Instanz',
    procedure
    var
      Validator: TMGKositValidator;
      SchemaFile, SchemaText: string;
    begin
      Validator := CreateContractValidator('schema-import-recovery', 'true()', '');
      try
        SchemaFile := TPath.Combine(FEvidenceDirectory, 'schema-import-recovery/schema.xsd');
        SchemaText := TFile.ReadAllText(SchemaFile, TEncoding.UTF8);
        TFile.WriteAllText(SchemaFile, StringReplace(SchemaText, '<xs:element', '<xs:include schemaLocation="absent-import.xsd"/><xs:element', []), TEncoding.UTF8);
        FActual := Validator.ValidateFile(TPath.Combine(FEvidenceDirectory, 'schema-import-recovery/input.xml'));
        CheckResult('F', kaUndefined, False, True, False);
        Require((Pos('absent-import.xsd', FActual.ErrorMessage) > 0) and (Pos('fehlt', FActual.ErrorMessage) > 0), 'Importdiagnose fehlt: ' + FActual.ErrorMessage);
        Require(Length(FActual.Findings) = 0, 'Fehlender Import wurde als fachlicher Schemafehler ausgegeben');
        Require(XmlHas(FActual.ReportInputXml, '//in:processingError/in:error'), 'Importfehler fehlt in der Berichtseingabe');
        Require(not XmlHas(FActual.ReportInputXml, '//in:validationResultsSchematron'), 'Schematron lief nach defektem Schema');
        FEvidence.AddPair('missing_schema_import_diagnostic', FActual.ErrorMessage);
        TFile.WriteAllText(TPath.Combine(FEvidenceDirectory, 'missing-schema-import-failure-reportInput.xml'), FActual.ReportInputXml, TEncoding.UTF8);
        TFile.WriteAllText(SchemaFile, SchemaText, TEncoding.UTF8);
        FActual := Validator.ValidateFile(TPath.Combine(FEvidenceDirectory, 'schema-import-recovery/input.xml'));
        CheckResult('V', kaAccept, True, False, True);
        Require(Length(FActual.Findings) = 0, 'Ein Importfehler blieb nach der Reparatur erhalten');
      finally
        FreeAndNil(Validator);
      end;
    end);
  RunCase('stylesheet-compile-failure-with-report-and-recovery', 'SchematronValidationActionTest; Stylesheetfehler bleibt Verarbeitungsfehler und vergiftet keinen Kompilierungscache',
    procedure
    var
      Validator: TMGKositValidator;
      StylesheetFile, StylesheetText: string;
    begin
      Validator := CreateContractValidator('stylesheet-recovery', 'true()', '');
      try
        StylesheetFile := TPath.Combine(FEvidenceDirectory, 'stylesheet-recovery/rules.xsl');
        StylesheetText := TFile.ReadAllText(StylesheetFile, TEncoding.UTF8);
        TFile.WriteAllText(StylesheetFile, StringReplace(StylesheetText, '<svrl:schematron-output>', '<xsl:invalid/><svrl:schematron-output>', []), TEncoding.UTF8);
        FActual := Validator.ValidateFile(TPath.Combine(FEvidenceDirectory, 'stylesheet-recovery/input.xml'));
        CheckResult('F', kaUndefined, True, True, True);
        Require((Pos('Schematron-Prüfung', FActual.ErrorMessage) > 0) and (Pos('Contract rules', FActual.ErrorMessage) > 0), 'Stylesheetdiagnose ohne Prüfphase');
        Require(XmlHas(FActual.ReportInputXml, '//in:processingError/in:error') and XmlHas(FActual.ReportXml, '//in:processingError/in:error'),
          'Stylesheetfehler ging beim Erzeugen des Berichts verloren');
        Require(Length(FActual.Findings) = 0, 'Stylesheetfehler wurde als fachlicher Befund ausgegeben');
        FEvidence.AddPair('stylesheet_compile_diagnostic', FActual.ErrorMessage);
        TFile.WriteAllText(TPath.Combine(FEvidenceDirectory, 'stylesheet-compile-failure-reportInput.xml'), FActual.ReportInputXml, TEncoding.UTF8);
        TFile.WriteAllText(StylesheetFile, StylesheetText, TEncoding.UTF8);
        FActual := Validator.ValidateFile(TPath.Combine(FEvidenceDirectory, 'stylesheet-recovery/input.xml'));
        CheckResult('V', kaAccept, True, False, True);
      finally
        FreeAndNil(Validator);
      end;
    end);
  RunCase('default-valid', 'DefaultCheckTest.testHappyCase/testExtractHtml; CreateReportAction input-document',
    procedure
    begin
      FActual := FDefaultValidator.ValidateFile(InputFile('simple.xml'), 'Originalreferenz.xml');
      CheckResult('V', kaAccept, True, False, True);
      Require(Length(FActual.Findings) = 0, 'Gültige Eingabe erzeugt Befunde');
      Require(ParseXml(FActual.ReportInputXml).selectNodes('/in:createReportInput/in:validationResultsSchematron').length = 1,
        'Gültige Eingabe besitzt nicht genau ein Schematronergebnis');
      Require(XmlHas(FActual.ReportInputXml, '//svrl:schematron-output/svrl:active-pattern') and
        XmlHas(FActual.ReportInputXml, '//svrl:schematron-output/svrl:fired-rule'), 'Gültige Eingabe verliert aktive Schematronregeln');
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
      Require((Length(FActual.Findings) = 1) and (FActual.Findings[0].Code = 'XML-SCHEMA') and
        (FActual.Findings[0].Level = 'error') and (FActual.Findings[0].ValidationStep = 'schema'), 'XSD-Diagnose besitzt falschen Code, Schweregrad oder Prüfphase');
      Require(TRegEx.IsMatch(FActual.Findings[0].Text, 'Zeile: [1-9][0-9]*; Position: [1-9][0-9]*'),
        'XSD-Diagnose besitzt keine positive Zeile und Spalte: ' + FActual.Findings[0].Text);
      Require(XmlText(FActual.ReportInputXml, '//in:validationResultsXmlSchema/in:xmlSyntaxError/in:severityCode') = 'SEVERITY_ERROR', 'Schemaschweregrad im Bericht fehlt');
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
      Require(XmlHas(FActual.ReportXml, '/r:report/r:input/*[local-name()="existiertNicht" and namespace-uri()="http://validator.kosit.de/unbekannt"]' +
        '/*[local-name()="inner" and text()="asldkfj"]') and XmlHas(FActual.ReportXml, '/r:report/r:result/in:createReportInput'),
        'Fallbackbericht besitzt nicht die Originaleingabe und Berichtseingabestruktur');
      Require(not XmlHas(FActual.ReportInputXml, '//in:validationResultsXmlSchema | //in:validationResultsSchematron'),
        'Eine Prüfung lief ohne ausgewähltes Szenario');
    end);
  RunCase('malformed-with-report', 'DefaultCheckTest.testNotWellFormed',
    procedure
    begin
      FActual := FDefaultValidator.ValidateFile(InputFile('simple-not-wellformed.xml'));
      CheckResult('F', kaReject, False, True, True);
      Require(XmlHas(FActual.ReportInputXml, '//in:processingError/in:error'), 'Parserfehler fehlt in Berichtseingabe');
      Require(not XmlHas(FActual.ReportInputXml, '//s:scenario | //in:validationResultsXmlSchema | //in:validationResultsSchematron'),
        'Nach einem Parserfehler wurden Szenario oder nachgelagerte Prüfungen erzeugt');
      Require(XmlHas(FActual.ReportInputXml, '//in:validationResultsWellformedness/in:xmlSyntaxError'), 'Wohlgeformtheitsdiagnose fehlt');
    end);
  RunCase('schematron-runtime-with-report', 'DefaultCheckTest.testSchematronExecutionError',
    procedure
    begin
      FActual := FErrorValidator.ValidateFile(InputFile('simple.xml'));
      CheckResult('F', kaUndefined, True, True, True);
      Require(XmlHas(FActual.ReportInputXml, '//in:processingError/in:error'), 'Schematron-Ausführungsfehler fehlt');
      Require(ParseXml(FActual.ReportInputXml).selectNodes('/in:createReportInput/in:processingError/in:error').length = 1,
        'Schematron-Ausführungsfehler besitzt nicht genau eine Fehlerdiagnose');
      Require(Length(FActual.Findings) = 0, 'Schematron-Ausführungsfehler wurde als fachlicher Befund ausgegeben');
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
        Require(XmlHas(FActual.ReportXml, '/r:report/r:input/t:simple'), 'Mehrdeutige Auswahl verlor die Originaleingabe im Fallbackbericht');
        Require(not XmlHas(FActual.ReportInputXml, '//s:scenario | //in:validationResultsXmlSchema | //in:validationResultsSchematron'),
          'Mehrdeutige Auswahl hat eine Prüfung ausgeführt');
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
  RunCase('file-stream-report-and-original-byte-hash-parity', 'InputFactoryTest/CreateReportActionTest; gleiche Eingabebytes erhalten Berichtsinhalte und eigenen SHA-256',
    procedure
    var
      FileResult: TMGKositValidationResult;
      Stream: TBytesStream;
      ExpectedHash: string;
    begin
      FileResult := FDefaultValidator.ValidateFile(InputFile('simple.xml'), 'Parität ä & <input>.xml');
      Stream := TBytesStream.Create(TFile.ReadAllBytes(InputFile('simple.xml')));
      try
        ExpectedHash := TNetEncoding.Base64.EncodeBytesToString(THashSHA2.GetHashBytes(Stream));
        Stream.Position := 0;
        FActual := FDefaultValidator.ValidateStream(Stream, 'Parität ä & <input>.xml');
        CheckResult('V', kaAccept, True, False, True);
        Require((FileResult.Acceptance = FActual.Acceptance) and (FileResult.SchemaValid = FActual.SchemaValid) and
          (FileResult.ProcessingError = FActual.ProcessingError) and (KositStatus(FileResult) = KositStatus(FActual)), 'Datei-/Streamentscheidungen unterscheiden sich');
        Require(WithoutTimestamp(FileResult.ReportInputXml) = WithoutTimestamp(FActual.ReportInputXml), 'Datei-/Stream-Berichtseingaben unterscheiden sich');
        Require(WithoutTimestamp(FileResult.ReportXml) = WithoutTimestamp(FActual.ReportXml), 'Datei-/Stream-Berichte unterscheiden sich');
        Require(FileResult.ReportHtml = FActual.ReportHtml, 'Datei-/Stream-HTML-Inhalte unterscheiden sich');
        Require(XmlText(FActual.ReportInputXml, '//in:documentHash/in:hashValue') = ExpectedHash, 'Streamhash stimmt nicht mit den Originalbytes überein');
        Require(XmlText(FileResult.ReportInputXml, '//in:documentHash/in:hashValue') = ExpectedHash, 'Dateihash stimmt nicht mit den Originalbytes überein');
        Require(Stream.Position = Stream.Size, 'Stream wurde für Berichtsgleichheit nicht bis EOF gelesen');
      finally
        FreeAndNil(Stream);
      end;
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

// Externe XRechnung-Prüfungen benötigen alle drei zusätzlichen Pfade gemeinsam.
procedure Run;
var
  Suite: TPipelineTestSuite;
begin
  if (ParamCount <> 3) and (ParamCount <> 6) then
    raise Exception.Create('Aufruf: PipelineTests LibraryFile UpstreamRoot EvidenceDirectory [ValidationRoot PublicValidFile BusinessInvalidFile]');
  Suite := TPipelineTestSuite.Create(ParamStr(1), ParamStr(2), ParamStr(3), ParamStr(4), ParamStr(5), ParamStr(6));
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
