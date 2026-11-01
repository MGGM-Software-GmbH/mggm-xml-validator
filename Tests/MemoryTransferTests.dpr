program MemoryTransferTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.DateUtils, System.Hash, System.NetEncoding,
  System.Win.ComObj, Winapi.Windows, Winapi.ActiveX, Winapi.MSXML, MGKosit;

type
  // Win32 liefert FILE_NOTIFY_INFORMATION als Header mit anschließendem UTF-16-Dateinamen.
  PDirectoryChange = ^TDirectoryChange;
  TDirectoryChange = record
    NextEntryOffset, Action, FileNameLength: Cardinal;
    FileName: array[0..0] of WideChar;
  end;

  // Die Quelle bildet eine Pipe ab und protokolliert auch indirekte Position-/Size-Zugriffe.
  TSequentialInput = class(TStream)
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

  TMemoryTransferSuite = class
  private
    FLibraryFile, FValidationRoot, FValidFile, FInvalidFile, FEvidenceFile, FBlockerFile: string;
    FOriginalTemp, FOriginalTmp, FVerifiedTempPath, FOriginalDirectory, FWatchedDirectory: string;
    FValidID, FInvalidID, FNonAsciiText: string;
    FValidBytes, FInvalidBytes, FMalformedBytes, FUtf8BomBytes, FUtf16Bytes, FLatin1Bytes: TBytes;
    FValidator: TMGKositValidator;
    FEvidence, FCase: TJSONObject;
    FCases: TJSONArray;
    FPassed, FFailed: Integer;
    FTempBlocked: Boolean;
    FDirectoryHandle, FDirectoryEvent: THandle;
    FDirectoryOverlap: TOverlapped;
    FDirectoryBuffer: array[0..65535] of Byte;
    procedure StartDirectoryWatch;
    procedure CheckDirectoryWatch;
    procedure StopDirectoryWatch;
    procedure Require(const Condition: Boolean; const MessageText: string);
    procedure RunCase(const Name: string; const Action: TProc);
    procedure PrepareFixtures;
    procedure CheckBlockedTemp;
    procedure CreateValidator;
    procedure AddScenarios;
    function ParseXml(const Xml: string): IXMLDOMDocument3;
    procedure CheckValidation(const Actual: TMGKositValidationResult; const ExpectedStatus: Char; const Input: TBytes; const Reference: string;
      const CheckEncodingText: Boolean = False);
    procedure ValidateBytes(const Input: TBytes; const ExpectedStatus: Char; const Reference: string; const CheckEncodingText: Boolean = False);
    procedure CheckCurrentPosition;
    procedure CheckSequentialInput;
    procedure ExecuteCases;
  public
    constructor Create(const LibraryFile, ValidationRoot, ValidFile, InvalidFile, EvidenceFile: string);
    destructor Destroy; override;
    function Execute: Integer;
  end;

const
  BlockerMarker = 'MemoryTransferTests: reguläre Datei sperrt TEMP-Unterverzeichnisse.';

// Eine eigene Bytekopie erhält die Originalfixtures über alle Testaufrufe unverändert.
constructor TSequentialInput.Create(const Content: TBytes);
begin
  inherited Create;
  FContent := Copy(Content);
end;

// Kurze Leseportionen verlangen vom Validator, ohne Size-Abfrage bis EOF zu lesen.
function TSequentialInput.Read(var Buffer; Count: Longint): Longint;
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

// Ein Validierungsaufruf darf den Eingabestream nicht beschreiben.
function TSequentialInput.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('Die sequentielle Testquelle ist schreibgeschützt.');
end;

// Jeder Seek ist ein Vertragsverstoß, auch eine reine Position-Abfrage.
function TSequentialInput.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Inc(FSeekCalls);
  raise EStreamError.Create('Die sequentielle Testquelle unterstützt kein Seek.');
end;

// Nur explizite Eingaben und das vom Aufrufer angeforderte Evidenzziel werden verwendet.
constructor TMemoryTransferSuite.Create(const LibraryFile, ValidationRoot, ValidFile, InvalidFile, EvidenceFile: string);
begin
  inherited Create;
  FLibraryFile := ExpandFileName(LibraryFile);
  FValidationRoot := ExpandFileName(ValidationRoot);
  FValidFile := ExpandFileName(ValidFile);
  FInvalidFile := ExpandFileName(InvalidFile);
  FEvidenceFile := ExpandFileName(EvidenceFile);
  FBlockerFile := ChangeFileExt(FEvidenceFile, '') + '-temp-blocker';
  FWatchedDirectory := ChangeFileExt(FEvidenceFile, '') + '-working-directory';
  FDirectoryHandle := INVALID_HANDLE_VALUE;
  FEvidence := TJSONObject.Create;
  FCases := TJSONArray.Create;
  FEvidence.AddPair('tests', FCases);
end;

// Der Validator wird noch unter der gesperrten TEMP-Vorgabe freigegeben.
destructor TMemoryTransferSuite.Destroy;
begin
  FreeAndNil(FValidator);
  StopDirectoryWatch;
  FreeAndNil(FEvidence);
  inherited;
end;

// Fehlerhafte Erwartungen zählen als Testfehler und bleiben im JSON diagnostizierbar.
procedure TMemoryTransferSuite.Require(const Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

// Einzelne Fälle werden unabhängig protokolliert, damit ein früher Fehler spätere Nachweise nicht verdeckt.
procedure TMemoryTransferSuite.RunCase(const Name: string; const Action: TProc);
var
  Passed: Boolean;
  Diagnostic: string;
begin
  Passed := False;
  Diagnostic := '';
  FCase := TJSONObject.Create;
  FCases.AddElement(FCase);
  FCase.AddPair('name', Name);
  FCase.AddPair('verified_temp_path', FVerifiedTempPath);
  try
    Action();
    if FDirectoryEvent <> 0 then
      CheckDirectoryWatch;
    Passed := True;
    Inc(FPassed);
  except
    on Error: Exception do
    begin
      Diagnostic := Error.ClassName + ': ' + Error.Message;
      Inc(FFailed);
    end;
  end;
  FCase.AddPair('passed', TJSONBool.Create(Passed));
  FCase.AddPair('diagnostic', Diagnostic);
  WriteLn(Name, ': ', BoolToStr(Passed, True), ' ', Diagnostic);
end;

// Encodingvarianten erhalten die vorhandenen Rechnungsdaten; numerische Zeichenreferenzen erhalten Zeichen außerhalb Latin-1.
procedure TMemoryTransferSuite.PrepareFixtures;
var
  SourceText, BodyText, Latin1Text: string;
  DeclarationEnd, NodeIndex, CharacterIndex, CodePoint: Integer;
  Latin1: TEncoding;
  Document: IXMLDOMDocument3;
  Nodes: IXMLDOMNodeList;
begin
  FValidBytes := TFile.ReadAllBytes(FValidFile);
  FInvalidBytes := TFile.ReadAllBytes(FInvalidFile);
  Require(Length(FValidBytes) > 20, 'Die gültige Fixture ist leer oder zu kurz.');
  Require(Length(FInvalidBytes) > 20, 'Die fachlich ungültige Fixture ist leer oder zu kurz.');
  SourceText := TEncoding.UTF8.GetString(FValidBytes);
  if (Length(SourceText) > 0) and (SourceText[1] = #$FEFF) then
    Delete(SourceText, 1, 1);
  Require(Pos('<?xml', SourceText) = 1, 'Die Eingabefixture benötigt eine UTF-8-XML-Deklaration.');
  DeclarationEnd := Pos('?>', SourceText);
  Require(DeclarationEnd > 0, 'Die XML-Deklaration der Fixture fehlt.');
  Document := ParseXml(SourceText);
  FValidID := string(Document.selectSingleNode('/*/*[local-name()="ID"]').text);
  Nodes := Document.selectNodes('//*[not(*) and text()]');
  for NodeIndex := 0 to Nodes.length - 1 do
    for CharacterIndex := 1 to Length(string(Nodes.item[NodeIndex].text)) do
      if Ord(string(Nodes.item[NodeIndex].text)[CharacterIndex]) > 127 then
      begin
        FNonAsciiText := string(Nodes.item[NodeIndex].text);
        Break;
      end;
  Require(FNonAsciiText <> '', 'Die vorhandene gültige UBL-Fixture enthält keinen nicht-ASCII-Text für die Encodinggegenprobe.');
  Document := ParseXml(TEncoding.UTF8.GetString(FInvalidBytes));
  FInvalidID := string(Document.selectSingleNode('/*/*[local-name()="ID"]').text);
  BodyText := Copy(SourceText, DeclarationEnd + 2, MaxInt);
  FMalformedBytes := Copy(FValidBytes, 0, Length(FValidBytes) div 2);
  FUtf8BomBytes := TEncoding.UTF8.GetPreamble + TEncoding.UTF8.GetBytes('<?xml version="1.0" encoding="UTF-8"?>' + BodyText);
  FUtf16Bytes := TEncoding.Unicode.GetPreamble + TEncoding.Unicode.GetBytes('<?xml version="1.0" encoding="UTF-16"?>' + BodyText);
  Latin1 := TEncoding.GetEncoding(28591);
  try
    SourceText := '<?xml version="1.0" encoding="ISO-8859-1"?>' + BodyText;
    Latin1Text := '';
    CharacterIndex := 1;
    while CharacterIndex <= Length(SourceText) do
    begin
      CodePoint := Ord(SourceText[CharacterIndex]);
      if (CodePoint >= $D800) and (CodePoint <= $DBFF) and (CharacterIndex < Length(SourceText)) then
      begin
        Inc(CharacterIndex);
        CodePoint := $10000 + (CodePoint - $D800) * $400 + Ord(SourceText[CharacterIndex]) - $DC00;
      end;
      if CodePoint > 255 then
        Latin1Text := Latin1Text + '&#' + IntToStr(CodePoint) + ';'
      else
        Latin1Text := Latin1Text + Char(CodePoint);
      Inc(CharacterIndex);
    end;
    FLatin1Bytes := Latin1.GetBytes(Latin1Text);
    Require(Latin1.GetString(FLatin1Bytes) = Latin1Text, 'Die Latin-1-Bytes sind nicht verlustfrei.');
  finally
    FreeAndNil(Latin1);
  end;
  Require(not TFile.Exists(FEvidenceFile), 'Das Evidenzziel muss für einen frischen Lauf neu sein: ' + FEvidenceFile);
  Require(not TFile.Exists(FBlockerFile) and not TDirectory.Exists(FBlockerFile), 'Die TEMP-Sperrdatei existiert bereits: ' + FBlockerFile);
  TDirectory.CreateDirectory(ExtractFileDir(FEvidenceFile));
  TFile.WriteAllText(FBlockerFile, BlockerMarker, TEncoding.UTF8);
  Require(not TDirectory.Exists(FWatchedDirectory), 'Das überwachte Arbeitsverzeichnis muss neu sein: ' + FWatchedDirectory);
  TDirectory.CreateDirectory(FWatchedDirectory);
end;

// Ein leeres RTL-TEMP darf keine internen Austauschdateien im aktuellen Verzeichnis verbergen.
procedure TMemoryTransferSuite.StartDirectoryWatch;
var
  BytesReturned: Cardinal;
begin
  FDirectoryHandle := CreateFile(PChar(FWatchedDirectory), FILE_LIST_DIRECTORY, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OVERLAPPED, 0);
  Require(FDirectoryHandle <> INVALID_HANDLE_VALUE, 'Das isolierte Arbeitsverzeichnis konnte nicht überwacht werden.');
  FDirectoryEvent := CreateEvent(nil, True, False, nil);
  Require(FDirectoryEvent <> 0, 'Das Ereignis der Verzeichnisüberwachung fehlt.');
  ZeroMemory(@FDirectoryOverlap, SizeOf(FDirectoryOverlap));
  FDirectoryOverlap.hEvent := FDirectoryEvent;
  Require(ReadDirectoryChangesW(FDirectoryHandle, @FDirectoryBuffer[0], SizeOf(FDirectoryBuffer), True,
    FILE_NOTIFY_CHANGE_FILE_NAME or FILE_NOTIFY_CHANGE_DIR_NAME or FILE_NOTIFY_CHANGE_SIZE or FILE_NOTIFY_CHANGE_LAST_WRITE,
    @BytesReturned, @FDirectoryOverlap, nil), 'Die Verzeichnisüberwachung konnte nicht gestartet werden.');
end;

// Die Überwachung erfasst auch Dateien, die innerhalb eines einzigen Validierungsaufrufs wieder gelöscht werden.
procedure TMemoryTransferSuite.CheckDirectoryWatch;
var
  BytesReturned: Cardinal;
  Change: PDirectoryChange;
  RelativeName: string;
  WaitResult: Cardinal;
begin
  WaitResult := WaitForSingleObject(FDirectoryEvent, 25);
  Require(WaitResult <> WAIT_FAILED, 'Die Verzeichnisüberwachung ist fehlgeschlagen.');
  if WaitResult = WAIT_OBJECT_0 then
  begin
    Require(GetOverlappedResult(FDirectoryHandle, FDirectoryOverlap, BytesReturned, False), 'Das Verzeichnisereignis konnte nicht gelesen werden.');
    Require(BytesReturned > 0, 'Der Überwachungspuffer ist übergelaufen und kann Dateifreiheit nicht belegen.');
    Change := PDirectoryChange(@FDirectoryBuffer[0]);
    SetString(RelativeName, PWideChar(@Change.FileName[0]), Change.FileNameLength div SizeOf(WideChar));
    FCase.AddPair('unexpected_filesystem_change', RelativeName);
    raise Exception.Create('Interne Datei-/Verzeichnisänderung im isolierten Arbeitsverzeichnis: ' + RelativeName);
  end;
end;

// Offene Benachrichtigungen werden beendet, bevor ihre Ereignis- und Pufferobjekte freigegeben werden.
procedure TMemoryTransferSuite.StopDirectoryWatch;
begin
  if FDirectoryHandle <> INVALID_HANDLE_VALUE then
  begin
    CancelIo(FDirectoryHandle);
    CloseHandle(FDirectoryHandle);
    FDirectoryHandle := INVALID_HANDLE_VALUE;
  end;
  if FDirectoryEvent <> 0 then
  begin
    CloseHandle(FDirectoryEvent);
    FDirectoryEvent := 0;
  end;
end;

// Der tatsächlich verwendete TEMP-Pfad muss unter einer regulären Datei liegen und einen Schreibversuch zurückweisen.
procedure TMemoryTransferSuite.CheckBlockedTemp;
var
  ProbeHandle: THandle;
  ProbeError: Cardinal;
  ProbeFile: string;
begin
  FVerifiedTempPath := TPath.GetTempPath;
  FEvidence.AddPair('verified_temp_path', FVerifiedTempPath);
  Require((FVerifiedTempPath = '') or SameFileName(ExcludeTrailingPathDelimiter(FVerifiedTempPath), FBlockerFile),
    'TPath.GetTempPath verwendet einen anderen beschreibbaren TEMP-Pfad.');
  Require(TFile.Exists(FBlockerFile) and not TDirectory.Exists(FBlockerFile), 'TEMP ist keine vorhandene reguläre Datei.');
  ProbeFile := TPath.Combine(FBlockerFile, 'write-probe.tmp');
  ProbeHandle := CreateFile(PChar(ProbeFile), GENERIC_WRITE, 0, nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
  ProbeError := GetLastError;
  if ProbeHandle <> INVALID_HANDLE_VALUE then
    CloseHandle(ProbeHandle);
  FCase.AddPair('write_probe_win32_error', TJSONNumber.Create(ProbeError));
  Require(ProbeHandle = INVALID_HANDLE_VALUE, 'Die TEMP-Gegenprobe konnte unerwartet eine Datei anlegen.');
  FCase.AddPair('temp_child_write_denied', TJSONBool.Create(True));
  FCase.AddPair('working_directory_watched', FWatchedDirectory);
  FTempBlocked := True;
end;

// Auch die eingebetteten Frameworkressourcen müssen ohne beschreibbares TEMP initialisiert werden.
procedure TMemoryTransferSuite.CreateValidator;
begin
  FValidator := TMGKositValidator.Create(FLibraryFile);
  Require(FValidator <> nil, 'Der öffentliche Validator wurde nicht erzeugt.');
end;

// Die Szenarien entsprechen den drei Original-Konfigurationen des MGGM-Streamadapters.
procedure TMemoryTransferSuite.AddScenarios;
begin
  Require(FValidator <> nil, 'Der Validator fehlt nach fehlgeschlagener Initialisierung.');
  FValidator.AddScenario(TPath.Combine(FValidationRoot, 'validator-configuration-zugferd\scenarios.xml'));
  FValidator.AddScenario(TPath.Combine(FValidationRoot, 'validator-configuration-zugferd\scenarios_zugferd1.xml'));
  FValidator.AddScenario(TPath.Combine(FValidationRoot, 'validator-configuration-xrechnung\3.0.2\scenarios.xml'));
  FCase.AddPair('scenario_count', TJSONNumber.Create(FValidator.ScenarioCount));
  Require(FValidator.ScenarioCount > 0, 'Die Regelpakete enthalten keine geladenen Szenarien.');
end;

// XML-Assertions lesen ausschließlich die vom öffentlichen Ergebnis gelieferten Strings.
function TMemoryTransferSuite.ParseXml(const Xml: string): IXMLDOMDocument3;
begin
  Result := CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
  Result.async := False;
  Result.validateOnParse := False;
  Result.resolveExternals := False;
  Result.setProperty('ProhibitDTD', True);
  Require(Boolean(Result.loadXML(Xml)), 'Der Bericht ist nicht parsebar: ' + string(Result.parseError.reason));
end;

// Hash und Rechnungsmetadaten aus dem Original-Stylesheet verhindern, dass ein alter Bericht als neuer Erfolg durchgeht.
procedure TMemoryTransferSuite.CheckValidation(const Actual: TMGKositValidationResult; const ExpectedStatus: Char; const Input: TBytes;
  const Reference: string; const CheckEncodingText: Boolean);
var
  ReportInput, Report, Html: IXMLDOMDocument3;
  HashNode, ReferenceNode, InvoiceIDNode: IXMLDOMNode;
  ActualHash, ExpectedHash, ExpectedInvoiceID: string;
  HashStream: TBytesStream;
begin
  FCase.AddPair('status', string(KositStatus(Actual)));
  FCase.AddPair('expected_status', string(ExpectedStatus));
  FCase.AddPair('processing_error', TJSONBool.Create(Actual.ProcessingError));
  FCase.AddPair('error_message', Actual.ErrorMessage);
  FCase.AddPair('report_input_size', TJSONNumber.Create(Length(Actual.ReportInputXml)));
  FCase.AddPair('report_size', TJSONNumber.Create(Length(Actual.ReportXml)));
  FCase.AddPair('html_size', TJSONNumber.Create(Length(Actual.ReportHtml)));
  FCase.AddPair('report_input_xml', Actual.ReportInputXml);
  FCase.AddPair('report_xml', Actual.ReportXml);
  FCase.AddPair('report_html', Actual.ReportHtml);
  Require(KositStatus(Actual) = ExpectedStatus, 'Status erwartet ' + ExpectedStatus + ', erhalten ' + KositStatus(Actual) + ': ' + Actual.ErrorMessage);
  Require(Actual.DocumentReference = Reference, 'Die öffentliche Dokumentreferenz wurde verändert.');
  ReportInput := ParseXml(Actual.ReportInputXml);
  Report := ParseXml(Actual.ReportXml);
  Html := ParseXml(Actual.ReportHtml);
  Require(SameText(string(Html.documentElement.baseName), 'html'), 'Der HTML-Bericht besitzt kein HTML-Wurzelelement.');
  HashNode := ReportInput.selectSingleNode('//*[local-name()="documentHash"]/*[local-name()="hashValue"]');
  ReferenceNode := ReportInput.selectSingleNode('//*[local-name()="documentIdentification"]/*[local-name()="documentReference"]');
  Require(HashNode <> nil, 'Der Bericht enthält keinen Dokumenthash.');
  Require(ReferenceNode <> nil, 'Der Bericht enthält keine Dokumentreferenz.');
  ActualHash := string(HashNode.text);
  HashStream := TBytesStream.Create(Input);
  try
    ExpectedHash := TNetEncoding.Base64.EncodeBytesToString(THashSHA2.GetHashBytes(HashStream));
  finally
    FreeAndNil(HashStream);
  end;
  FCase.AddPair('input_sha256_base64', ExpectedHash);
  FCase.AddPair('reported_sha256_base64', ActualHash);
  Require(ActualHash = ExpectedHash, 'Der Berichtshash entspricht nicht den tatsächlich übergebenen Bytes.');
  Require(string(ReferenceNode.text) = Reference, 'Die Referenz in der Berichtseingabe ist nicht verlustfrei.');
  if ExpectedStatus = 'F' then
  begin
    Require(Actual.ProcessingError and (Actual.ErrorMessage <> ''), 'Der Parserfehler fehlt im öffentlichen Ergebnis.');
    Require(ReportInput.selectSingleNode('//*[local-name()="processingError"]/*[local-name()="error"]') <> nil, 'Der Parserfehler fehlt in der Berichtseingabe.');
    Require(Report.selectSingleNode('//*[local-name()="documentData"]/*[local-name()="id"]') = nil, 'Der Parserfehlerbericht enthält eine vorherige Rechnung.');
  end
  else
  begin
    Require(not Actual.ProcessingError, 'Ein vorheriger Parserfehler blieb erhalten.');
    Require(ReportInput.selectSingleNode('//*[local-name()="processingError"]') = nil, 'Ein alter Parserfehler blieb in der Berichtseingabe.');
    InvoiceIDNode := Report.selectSingleNode('//*[local-name()="documentData"]/*[local-name()="id"]');
    Require(InvoiceIDNode <> nil, 'Die aus input-document gelesene UBL-Rechnungsnummer fehlt im Bericht.');
    ExpectedInvoiceID := FValidID;
    if ExpectedStatus = 'E' then
      ExpectedInvoiceID := FInvalidID;
    Require(string(InvoiceIDNode.text) = ExpectedInvoiceID, 'Der Bericht enthält eine abweichende Rechnungsnummer aus input-document.');
    if ExpectedStatus = 'V' then
      Require((Actual.Acceptance = kaAccept) and Actual.SchemaValid and (Actual.Errors = 0), 'Die gültige Rechnung enthält einen Ablehnungs- oder Fehlerzustand.')
    else
      Require((Actual.Acceptance = kaReject) or (Actual.Errors > 0), 'Die fachliche Ablehnung ist im Ergebnis nicht erkennbar.');
  end;
  if CheckEncodingText then
    Require(Pos(FNonAsciiText, string(Html.documentElement.text)) > 0, 'Der vorhandene nicht-ASCII-Rechnungstext ging beim Encoding-/HTML-Transfer verloren.');
end;

// Alle Eingaben werden ausschließlich aus den vor der TEMP-Sperre vorbereiteten Bytes gelesen.
procedure TMemoryTransferSuite.ValidateBytes(const Input: TBytes; const ExpectedStatus: Char; const Reference: string; const CheckEncodingText: Boolean);
var
  InputStream: TBytesStream;
  Actual: TMGKositValidationResult;
begin
  Require(FValidator <> nil, 'Der Validator fehlt nach fehlgeschlagener Initialisierung.');
  InputStream := TBytesStream.Create(Input);
  try
    Actual := FValidator.ValidateStream(InputStream, Reference);
    CheckValidation(Actual, ExpectedStatus, Input, Reference, CheckEncodingText);
    Require(InputStream.Position = InputStream.Size, 'Die Eingabe wurde nicht bis EOF gelesen.');
  finally
    FreeAndNil(InputStream);
  end;
end;

// Ein ungültiger Präfix darf nicht in die ab aktueller Position gelesene Rechnung gelangen.
procedure TMemoryTransferSuite.CheckCurrentPosition;
const
  Prefix = 'Kein XML: nur vor der aktuellen Streamposition';
var
  InputStream: TMemoryStream;
  PrefixBytes: TBytes;
  Actual: TMGKositValidationResult;
begin
  Require(FValidator <> nil, 'Der Validator fehlt nach fehlgeschlagener Initialisierung.');
  PrefixBytes := TEncoding.UTF8.GetBytes(Prefix);
  InputStream := TMemoryStream.Create;
  try
    InputStream.WriteBuffer(PrefixBytes[0], Length(PrefixBytes));
    InputStream.WriteBuffer(FValidBytes[0], Length(FValidBytes));
    InputStream.Position := Length(PrefixBytes);
    FCase.AddPair('input_position_before', TJSONNumber.Create(InputStream.Position));
    Actual := FValidator.ValidateStream(InputStream, 'Position & <Prüfung>.xml');
    CheckValidation(Actual, 'V', FValidBytes, 'Position & <Prüfung>.xml');
    FCase.AddPair('input_position_after', TJSONNumber.Create(InputStream.Position));
    Require(InputStream.Position = InputStream.Size, 'Der Stream wurde ab aktueller Position nicht bis EOF gelesen.');
  finally
    FreeAndNil(InputStream);
  end;
end;

// Ohne Seek und Size muss derselbe öffentliche Streamvertrag gelten.
procedure TMemoryTransferSuite.CheckSequentialInput;
var
  InputStream: TSequentialInput;
  Actual: TMGKositValidationResult;
begin
  Require(FValidator <> nil, 'Der Validator fehlt nach fehlgeschlagener Initialisierung.');
  InputStream := TSequentialInput.Create(FValidBytes);
  try
    Actual := FValidator.ValidateStream(InputStream, 'Pipe-Prüfung.xml');
    FCase.AddPair('read_calls', TJSONNumber.Create(InputStream.ReadCalls));
    FCase.AddPair('seek_calls', TJSONNumber.Create(InputStream.SeekCalls));
    CheckValidation(Actual, 'V', FValidBytes, 'Pipe-Prüfung.xml');
    Require(InputStream.SeekCalls = 0, 'Der Validator hat bei der sequentiellen Quelle Seek aufgerufen.');
    Require(InputStream.ReadCalls > 2, 'Die Quelle wurde nicht in mehreren Portionen bis EOF gelesen.');
  finally
    FreeAndNil(InputStream);
  end;
end;

// Die V/E/F/V-Folge in derselben Instanz deckt veraltete Quell-, Fehler- und Berichtszustände auf.
procedure TMemoryTransferSuite.ExecuteCases;
begin
  RunCase('temp-is-blocked', CheckBlockedTemp);
  Require(FTempBlocked, 'Ohne nachgewiesene TEMP-Sperre darf der Validator nicht gestartet werden.');
  RunCase('create-without-temp', CreateValidator);
  Require(WaitForSingleObject(FDirectoryEvent, 0) = WAIT_TIMEOUT, 'Der Konstruktor hat interne Dateien oder Verzeichnisse angelegt.');
  RunCase('add-scenarios-without-temp', AddScenarios);
  RunCase('sequence-valid', procedure begin ValidateBytes(FValidBytes, 'V', 'Gültig & <Prüfung>.xml'); end);
  RunCase('sequence-business-invalid', procedure begin ValidateBytes(FInvalidBytes, 'E', 'Fachfehler.xml'); end);
  RunCase('sequence-parse-error', procedure begin ValidateBytes(FMalformedBytes, 'F', 'Parserfehler.xml'); end);
  RunCase('sequence-valid-after-error', procedure begin ValidateBytes(FValidBytes, 'V', 'Erneut gültig.xml'); end);
  RunCase('current-stream-position', CheckCurrentPosition);
  RunCase('nonseekable-stream', CheckSequentialInput);
  RunCase('utf8-bom-nonascii', procedure begin ValidateBytes(FUtf8BomBytes, 'V', 'UTF-8 Prüfung.xml', True); end);
  RunCase('utf16-nonascii', procedure begin ValidateBytes(FUtf16Bytes, 'V', 'UTF-16 Prüfung.xml', True); end);
  RunCase('latin1-nonascii', procedure begin ValidateBytes(FLatin1Bytes, 'V', 'Latin-1 Prüfung.xml', True); end);
  RunCase('temp-blocker-unchanged',
    procedure
    begin
      Require(TFile.ReadAllText(FBlockerFile, TEncoding.UTF8) = BlockerMarker, 'Die TEMP-Sperrdatei wurde verändert.');
      Require(not TDirectory.Exists(FBlockerFile), 'Die TEMP-Sperrdatei wurde durch ein Verzeichnis ersetzt.');
    end);
end;

// TEMP/TMP gelten nur im isolierten Testprozess; Evidenz wird erst nach ihrer Wiederherstellung geschrieben.
function TMemoryTransferSuite.Execute: Integer;
var
  InfrastructureFailure: string;
begin
  FEvidence.AddPair('started_at', DateToISO8601(Now, False));
  FEvidence.AddPair('process_id', TJSONNumber.Create(GetCurrentProcessId));
  FEvidence.AddPair('library_file', FLibraryFile);
  FEvidence.AddPair('validation_root', FValidationRoot);
  FEvidence.AddPair('valid_invoice', FValidFile);
  FEvidence.AddPair('invalid_invoice', FInvalidFile);
  FEvidence.AddPair('temp_blocker_file', FBlockerFile);
  FEvidence.AddPair('watched_working_directory', FWatchedDirectory);
  FOriginalDirectory := GetCurrentDir;
  FOriginalTemp := GetEnvironmentVariable('TEMP');
  FOriginalTmp := GetEnvironmentVariable('TMP');
  try
    PrepareFixtures;
    Require(SetCurrentDir(FWatchedDirectory), 'Das isolierte Arbeitsverzeichnis konnte nicht gesetzt werden.');
    StartDirectoryWatch;
    Require(SetEnvironmentVariable('TEMP', PChar(FBlockerFile)), 'TEMP konnte nicht gesetzt werden.');
    try
      Require(SetEnvironmentVariable('TMP', PChar(FBlockerFile)), 'TMP konnte nicht gesetzt werden.');
      ExecuteCases;
    finally
      try
        FreeAndNil(FValidator);
      finally
        StopDirectoryWatch;
        SetCurrentDir(FOriginalDirectory);
        if FOriginalTmp = '' then
          SetEnvironmentVariable('TMP', nil)
        else
          SetEnvironmentVariable('TMP', PChar(FOriginalTmp));
        if FOriginalTemp = '' then
          SetEnvironmentVariable('TEMP', nil)
        else
          SetEnvironmentVariable('TEMP', PChar(FOriginalTemp));
      end;
    end;
  except
    on Error: Exception do
    begin
      InfrastructureFailure := Error.ClassName + ': ' + Error.Message;
      RunCase('suite-infrastructure', procedure begin raise Exception.Create(InfrastructureFailure); end);
    end;
  end;
  StopDirectoryWatch;
  SetCurrentDir(FOriginalDirectory);
  RunCase('environment-restored',
    procedure
    begin
      Require((GetEnvironmentVariable('TEMP') = FOriginalTemp) and (GetEnvironmentVariable('TMP') = FOriginalTmp), 'TEMP/TMP wurden nicht wiederhergestellt.');
    end);
  FEvidence.AddPair('environment_restored', TJSONBool.Create((GetEnvironmentVariable('TEMP') = FOriginalTemp) and (GetEnvironmentVariable('TMP') = FOriginalTmp)));
  FEvidence.AddPair('finished_at', DateToISO8601(Now, False));
  FEvidence.AddPair('passed', TJSONNumber.Create(FPassed));
  FEvidence.AddPair('failed', TJSONNumber.Create(FFailed));
  FEvidence.AddPair('total', TJSONNumber.Create(FPassed + FFailed));
  TFile.WriteAllText(FEvidenceFile, FEvidence.ToJSON, TEncoding.UTF8);
  Result := Ord(FFailed <> 0);
end;

// Aufruf: MemoryTransferTests DLL ValidationRoot ValidXml InvalidBusinessXml EvidenceJson.
procedure Run;
var
  Suite: TMemoryTransferSuite;
begin
  if ParamCount <> 5 then
    raise Exception.Create('Aufruf: MemoryTransferTests DLL ValidationRoot ValidXml InvalidBusinessXml EvidenceJson');
  Suite := TMemoryTransferSuite.Create(ParamStr(1), ParamStr(2), ParamStr(3), ParamStr(4), ParamStr(5));
  try
    ExitCode := Suite.Execute;
  finally
    FreeAndNil(Suite);
  end;
end;

begin
  SetTextCodePage(Output, CP_UTF8);
  SetTextCodePage(ErrOutput, CP_UTF8);
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    try
      Run;
    except
      on Error: Exception do
      begin
        WriteLn(Error.ClassName, ': ', Error.Message);
        ExitCode := 1;
      end;
    end;
  finally
    CoUninitialize;
  end;
end.
