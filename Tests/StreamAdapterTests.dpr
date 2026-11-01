program StreamAdapterTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.StrUtils,
  Winapi.Windows, Winapi.ActiveX, System.Win.ComObj, Winapi.MSXML,
  MGKositStreamAdapter in '..\Examples\MGKositStreamAdapter.pas',
  MGKosit;

type
  // Die Tests rufen den eigenständigen Stream-Adapter mit echten Streams und Regelpaketen auf.
  TIntegrationSuite = class
  private
    FLibraryFile, FValidationRoot, FValidFile, FInvalidFile, FEvidenceFile: string;
    FEvidence: TJSONObject;
    FCases: TJSONArray;
    FCaseEvidence: TJSONObject;
    FPassed, FFailed: Integer;
    procedure Require(const Condition: Boolean; const MessageText: string);
    procedure RunCase(const Name: string; const Action: TProc);
    function ReadStream(const Stream: TMemoryStream): string;
    function ParseXml(const Xml: string): IXMLDOMDocument3;
    function ArtifactFile(const Suffix: string): string;
    procedure CheckInvoice(const XmlFile: string; const ExpectedStatus: Char; const ArtifactSuffix: string; const CheckReference: Boolean);
    procedure CheckNilInput;
    procedure CheckUnknownXml;
    procedure AddScenarios(const Validator: TMGKositValidator);
  public
    constructor Create(const LibraryFile, ValidationRoot, ValidFile, InvalidFile, EvidenceFile: string);
    destructor Destroy; override;
    function Execute: Integer;
  end;

// Alle Eingabepfade bleiben explizit; die Tests erzeugen nur Evidenz neben dem angeforderten JSON.
constructor TIntegrationSuite.Create(const LibraryFile, ValidationRoot, ValidFile, InvalidFile, EvidenceFile: string);
begin
  inherited Create;
  FLibraryFile := ExpandFileName(LibraryFile);
  FValidationRoot := ExpandFileName(ValidationRoot);
  FValidFile := ExpandFileName(ValidFile);
  FInvalidFile := ExpandFileName(InvalidFile);
  FEvidenceFile := ExpandFileName(EvidenceFile);
  FEvidence := TJSONObject.Create;
  FCases := TJSONArray.Create;
  FEvidence.AddPair('tests', FCases);
  FEvidence.AddPair('source_unit', 'Examples/MGKositStreamAdapter.pas');
  FEvidence.AddPair('library_file', FLibraryFile);
  FEvidence.AddPair('validation_root', FValidationRoot);
  FEvidence.AddPair('valid_invoice', FValidFile);
  FEvidence.AddPair('invalid_invoice', FInvalidFile);
end;

// Das Ergebnisarray und die einzelnen Fälle gehören dem JSON-Wurzelobjekt.
destructor TIntegrationSuite.Destroy;
begin
  FreeAndNil(FEvidence);
  inherited Destroy;
end;

// Eine verletzte Erwartung erhält eine vom Produktionsfehler getrennte Testdiagnose.
procedure TIntegrationSuite.Require(const Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

// Unabhängige Grenzfälle laufen auch nach einer fehlgeschlagenen Rechnung weiter.
procedure TIntegrationSuite.RunCase(const Name: string; const Action: TProc);
var
  Passed: Boolean;
  Diagnostic: string;
begin
  Passed := False;
  Diagnostic := '';
  FCaseEvidence := TJSONObject.Create;
  FCases.AddElement(FCaseEvidence);
  FCaseEvidence.AddPair('name', Name);
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
  FCaseEvidence.AddPair('passed', TJSONBool.Create(Passed));
  FCaseEvidence.AddPair('diagnostic', Diagnostic);
  WriteLn(Name, ': ', BoolToStr(Passed, True), ' ', Diagnostic);
end;

// Das Auslesen der Evidenz darf die vom Stream-Adapter gesetzte Streamposition nicht verändern.
function TIntegrationSuite.ReadStream(const Stream: TMemoryStream): string;
var
  Buffer: TBytes;
begin
  SetLength(Buffer, Stream.Size);
  if Length(Buffer) > 0 then
    Move(Stream.Memory^, Buffer[0], Length(Buffer));
  Result := TEncoding.UTF8.GetString(Buffer);
end;

// Die vom Wrapper gelieferten XHTML-Berichte müssen auch mit gesperrten DTDs lesbar sein.
function TIntegrationSuite.ParseXml(const Xml: string): IXMLDOMDocument3;
begin
  Result := CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
  Result.async := False;
  Result.validateOnParse := False;
  Result.resolveExternals := False;
  Result.setProperty('ProhibitDTD', True);
  Result.setProperty('UseInlineSchema', False);
  Require(Boolean(Result.loadXML(Xml)), 'Der XML-/XHTML-Bericht ist nicht parsebar: ' + string(Result.parseError.reason));
end;

// Jeder Report ist eindeutig an den vom Aufrufer gewählten Evidenzdateinamen gebunden.
function TIntegrationSuite.ArtifactFile(const Suffix: string): string;
begin
  Result := ChangeFileExt(FEvidenceFile, '') + Suffix;
end;

// Ein Aufruf prüft Status, HTML und Streambesitz; die gültige Rechnung prüft zusätzlich XML-Escaping.
procedure TIntegrationSuite.CheckInvoice(const XmlFile: string; const ExpectedStatus: Char; const ArtifactSuffix: string; const CheckReference: Boolean);
const
  Reference = 'Integration & <Auftrag> / Prüfung.xml';
var
  XmlStream, HtmlStream: TMemoryStream;
  BeforePosition: Int64;
  Status: Char;
  ErrorOutput, Html, HtmlFile: string;
  Document: IXMLDOMDocument3;
begin
  XmlStream := TMemoryStream.Create;
  HtmlStream := TMemoryStream.Create;
  try
    XmlStream.LoadFromFile(XmlFile);
    Require(XmlStream.Size > 17, 'Die Rechnung ist für die Positionsgegenprobe zu kurz.');
    XmlStream.Position := 17;
    BeforePosition := XmlStream.Position;
    Status := ValidateWithKOSITNative(XmlStream, HtmlStream, ErrorOutput, FValidationRoot, FLibraryFile, Reference);
    FCaseEvidence.AddPair('status', string(Status));
    FCaseEvidence.AddPair('expected_status', string(ExpectedStatus));
    FCaseEvidence.AddPair('error_output', ErrorOutput);
    FCaseEvidence.AddPair('input_position_before', TJSONNumber.Create(BeforePosition));
    FCaseEvidence.AddPair('input_position_after', TJSONNumber.Create(XmlStream.Position));
    FCaseEvidence.AddPair('html_size', TJSONNumber.Create(HtmlStream.Size));
    FCaseEvidence.AddPair('html_position', TJSONNumber.Create(HtmlStream.Position));
    Require(Status = ExpectedStatus, 'Unerwarteter Validierungsstatus ' + string(Status) + ': ' + ErrorOutput);
    Require(XmlStream.Position = BeforePosition, 'Die Eingabestreamposition wurde verändert.');
    Require((HtmlStream.Size > 0) and (HtmlStream.Position = 0), 'HTML fehlt oder der Ausgabestream steht nicht am Anfang.');
    Html := ReadStream(HtmlStream);
    HtmlFile := ArtifactFile(ArtifactSuffix);
    TFile.WriteAllText(HtmlFile, Html, TEncoding.UTF8);
    FCaseEvidence.AddPair('html_file', HtmlFile);
    Document := ParseXml(Html);
    Require(SameText(string(Document.documentElement.baseName), 'html'), 'Der Bericht enthält kein HTML-Wurzelelement.');
    if CheckReference then
    begin
      Require(Pos(Reference, string(Document.documentElement.text)) > 0, 'Die XML-Referenz wurde im Bericht nicht verlustfrei übernommen.');
      Require((Pos('&amp;', Html) > 0) and (Pos('&lt;Auftrag', Html) > 0), 'Die Referenz wurde nicht als XML-Text maskiert.');
      Require(Document.selectSingleNode('//*[local-name()="Auftrag"]') = nil, 'Die Referenz wurde als XML-Markup interpretiert.');
      FCaseEvidence.AddPair('reference', Reference);
      FCaseEvidence.AddPair('reference_roundtrip', TJSONBool.Create(True));
    end;
  finally
    FreeAndNil(HtmlStream);
    FreeAndNil(XmlStream);
  end;
end;

// Nil-Eingabe muss F liefern und einen bereits befüllten Ergebnisstream leeren.
procedure TIntegrationSuite.CheckNilInput;
var
  HtmlStream: TMemoryStream;
  Marker: TBytes;
  Status: Char;
  ErrorOutput: string;
begin
  HtmlStream := TMemoryStream.Create;
  try
    Marker := TEncoding.UTF8.GetBytes('Vorheriger Bericht');
    HtmlStream.WriteBuffer(Marker[0], Length(Marker));
    Status := ValidateWithKOSITNative(nil, HtmlStream, ErrorOutput, FValidationRoot, FLibraryFile);
    FCaseEvidence.AddPair('status', string(Status));
    FCaseEvidence.AddPair('error_output', ErrorOutput);
    FCaseEvidence.AddPair('html_size', TJSONNumber.Create(HtmlStream.Size));
    Require(Status = 'F', 'Nil-Eingabe liefert nicht F.');
    Require(ErrorOutput <> '', 'Nil-Eingabe liefert keine Fehlerdiagnose.');
    Require(HtmlStream.Size = 0, 'Der vorhandene HTML-Bericht wurde bei Nil-Eingabe nicht geleert.');
  finally
    FreeAndNil(HtmlStream);
  end;
end;

// Die Kontrollvalidierung verwendet dieselben drei Original-Konfigurationen wie der Stream-Adapter.
procedure TIntegrationSuite.AddScenarios(const Validator: TMGKositValidator);
begin
  Validator.AddScenario(TPath.Combine(FValidationRoot, 'validator-configuration-zugferd\scenarios.xml'));
  Validator.AddScenario(TPath.Combine(FValidationRoot, 'validator-configuration-zugferd\scenarios_zugferd1.xml'));
  Validator.AddScenario(TPath.Combine(FValidationRoot, 'validator-configuration-xrechnung\3.0.2\scenarios.xml'));
end;

// Eine Szenario-Ablehnung benötigt keine rep:message und muss vom Wrapper trotzdem als E erscheinen.
procedure TIntegrationSuite.CheckUnknownXml;
const
  UnknownXml = '<unknown xmlns="urn:mggm:kosit:integration:unknown"/>';
var
  XmlStream, HtmlStream: TMemoryStream;
  Buffer: TBytes;
  BeforePosition: Int64;
  Status: Char;
  ErrorOutput, Html, ReportFile: string;
  Validator: TMGKositValidator;
  Validation: TMGKositValidationResult;
  Document: IXMLDOMDocument3;
  MessageCount: Integer;
begin
  XmlStream := TMemoryStream.Create;
  HtmlStream := TMemoryStream.Create;
  try
    Buffer := TEncoding.UTF8.GetBytes(UnknownXml);
    XmlStream.WriteBuffer(Buffer[0], Length(Buffer));
    XmlStream.Position := 5;
    BeforePosition := XmlStream.Position;
    Status := ValidateWithKOSITNative(XmlStream, HtmlStream, ErrorOutput, FValidationRoot, FLibraryFile, 'Unbekannt & <XML>');
    FCaseEvidence.AddPair('status', string(Status));
    FCaseEvidence.AddPair('error_output', ErrorOutput);
    FCaseEvidence.AddPair('input_position_before', TJSONNumber.Create(BeforePosition));
    FCaseEvidence.AddPair('input_position_after', TJSONNumber.Create(XmlStream.Position));
    FCaseEvidence.AddPair('html_size', TJSONNumber.Create(HtmlStream.Size));
    Require(Status = 'E', 'Unbekanntes XML muss E liefern, auch ohne rep:message: ' + string(Status) + ' ' + ErrorOutput);
    Require(XmlStream.Position = BeforePosition, 'Die Eingabestreamposition wurde beim unbekannten XML verändert.');
    Require((HtmlStream.Size > 0) and (HtmlStream.Position = 0), 'Der Ablehnungsbericht fehlt oder steht nicht am Anfang.');
    Html := ReadStream(HtmlStream);
    Document := ParseXml(Html);
    TFile.WriteAllText(ArtifactFile('-unknown.html'), Html, TEncoding.UTF8);
    Validator := TMGKositValidator.Create(FLibraryFile);
    try
      AddScenarios(Validator);
      XmlStream.Position := 0;
      Validation := Validator.ValidateStream(XmlStream, 'Unbekannt & <XML>');
      Require(not Validation.ProcessingError, 'Die Kontrollvalidierung hat einen technischen Fehler: ' + Validation.ErrorMessage);
      Require(Validation.Acceptance = kaReject, 'Die Kontrollvalidierung weist das unbekannte XML nicht fachlich zurück.');
      Document := ParseXml(Validation.ReportXml);
      Document.setProperty('SelectionNamespaces', 'xmlns:rep="http://www.xoev.de/de/validator/varl/1"');
      MessageCount := Document.selectNodes('//rep:message').length;
      FCaseEvidence.AddPair('rep_message_count', TJSONNumber.Create(MessageCount));
      Require(MessageCount = 0, 'Die Gegenprobe enthält rep:message und prüft den geforderten Grenzfall nicht.');
      Require(KositStatus(Validation) = 'E', 'Die Kontrollvalidierung stuft eine Ablehnung ohne rep:message nicht als E ein.');
      ReportFile := ArtifactFile('-unknown-report.xml');
      TFile.WriteAllText(ReportFile, Validation.ReportXml, TEncoding.UTF8);
      FCaseEvidence.AddPair('control_report', ReportFile);
    finally
      FreeAndNil(Validator);
    end;
  finally
    FreeAndNil(HtmlStream);
    FreeAndNil(XmlStream);
  end;
end;

// Der gültige Beleg dient als begrenzte Integrationsgegenprobe vor den Fehlerpfaden.
function TIntegrationSuite.Execute: Integer;
begin
  ForceDirectories(ExtractFileDir(FEvidenceFile));
  RunCase('stream-adapter-valid-v-html-position-reference',
    procedure
    begin
      CheckInvoice(FValidFile, 'V', '-valid.html', True);
    end);
  RunCase('stream-adapter-invalid-e-html-position',
    procedure
    begin
      CheckInvoice(FInvalidFile, 'E', '-invalid.html', False);
    end);
  RunCase('stream-adapter-nil-input-f-clears-html',
    procedure
    begin
      CheckNilInput;
    end);
  RunCase('stream-adapter-unknown-e-with-zero-report-messages',
    procedure
    begin
      CheckUnknownXml;
    end);
  FEvidence.AddPair('passed', TJSONNumber.Create(FPassed));
  FEvidence.AddPair('failed', TJSONNumber.Create(FFailed));
  FEvidence.AddPair('total', TJSONNumber.Create(FPassed + FFailed));
  TFile.WriteAllText(FEvidenceFile, FEvidence.ToJSON, TEncoding.UTF8);
  if FFailed = 0 then
    Result := 0
  else
    Result := 1;
end;

// Aufruf: StreamAdapterTests LibraryFile ValidationRoot ValidUbl InvalidUbl EvidenceJson.
procedure Run;
var
  Suite: TIntegrationSuite;
  InitializationResult: HRESULT;
  MustUninitialize: Boolean;
begin
  if ParamCount <> 5 then
    raise Exception.Create('Aufruf: StreamAdapterTests LibraryFile ValidationRoot ValidUbl InvalidUbl EvidenceJson');
  InitializationResult := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  MustUninitialize := Succeeded(InitializationResult);
  if not MustUninitialize and (InitializationResult <> RPC_E_CHANGED_MODE) then
    OleCheck(InitializationResult);
  try
    Suite := TIntegrationSuite.Create(ParamStr(1), ParamStr(2), ParamStr(3), ParamStr(4), ParamStr(5));
    try
      ExitCode := Suite.Execute;
    finally
      FreeAndNil(Suite);
    end;
  finally
    if MustUninitialize then
      CoUninitialize;
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
