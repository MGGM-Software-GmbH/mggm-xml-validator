unit MGKositEngine;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Winapi.Windows, Winapi.MSXML, MGKositNative, MGKositTypes;

type
  EMGKositEngine = class(Exception);

  // Ein Validator verwendet diese Engine ausschließlich im erzeugenden Thread.
  TMGKositEngine = class
  private
    FNative: TMGKositNative;
    FOwnerThread: DWORD;
    FMustUninitialize: Boolean;
    FResourceRoots: TArray<string>;
    FSchemaCaches: TDictionary<string, IXMLDOMSchemaCollection2>;
    FMemoryResources: TDictionary<string, TBytes>;
    FCheckedStylesheets: TDictionary<string, Boolean>;
    FSchemaCompilationCount: Integer;
    FSchemaCompilationMs, FSchemaValidationMs, FXPathMs, FTransformationMs, FDocumentParsingMs: Double;
    FDomMs: Double;
    procedure RequireOwnerThread;
    function CreateDocument(const AllowInternalDtd: Boolean): IXMLDOMDocument3;
    function RequireReadableFile(const FileName: string): string;
    function RequireResourceFile(const FileName: string): string;
    function RequireCheckedStylesheet(const FileName: string): string;
    procedure CheckStylesheetResources(const FileName: string; const CheckedFiles: TDictionary<string, Boolean>);
    function LoadSchema(const FileName: string): IXMLDOMDocument3;
    function GetSchemaCache(const SchemaFiles: TArray<string>): IXMLDOMSchemaCollection2;
    function ValidateSchemaInstance(const XmlFile: string; const SchemaFiles: TArray<string>; out Diagnostic: string): Boolean;
    function GetMemorySchemaCache(const SchemaFiles: TArray<string>): IXMLDOMSchemaCollection2;
    procedure CollectMemorySchemas(const ResourceUri: string; const Documents: TDictionary<string, IXMLDOMDocument3>);
    procedure CollectFileSchemas(const FileName, InheritedNamespace: string; const IsInclude: Boolean; const Documents: TDictionary<string, IXMLDOMDocument3>);
    procedure ApplySchemaRedefinition(const Document: IXMLDOMDocument3; const Redefinition: IXMLDOMElement;
      const Documents: TDictionary<string, IXMLDOMDocument3>; const TargetNamespace: string);
  public
    constructor Create(const SaxonLibraryFile: string);
    destructor Destroy; override;
    procedure Close;
    procedure BeginDocument(const XmlFile: string);
    procedure EndDocument;
    function Statistics: TMGKositStatistics;
    procedure ConfigureResourceRoots(const RootDirectories: TArray<string>);
    function NewDocument(const Xml: string = ''): IXMLDOMDocument3;
    function LoadDocument(const FileName: string): IXMLDOMDocument3;
    function ReadFileBytes(const FileName: string): TBytes;
    function ValidateSchemas(const XmlFile: string; const SchemaFiles: TArray<string>; out Diagnostic: string): Boolean;
    function EvaluateBoolean(const XmlFile, Expression: string; const Namespaces: TArray<string>): Boolean;
    procedure Transform(const XmlFile, StylesheetFile, OutputFile: string; const InputDocumentFile: string = '');
    function Version: string;
    procedure RegisterMemoryResource(const ResourceUri: string; const Content: TBytes);
    function LoadDocumentBytes(const Content: TBytes; const BaseUri: string = ''): IXMLDOMDocument3;
    function ValidateDocumentSchemas(const Document: IXMLDOMDocument3; const SchemaFiles: TArray<string>; out Diagnostic: string; const OriginalContent: TBytes = nil): Boolean;
    function ValidateDocumentSchemaDiagnostics(const Document: IXMLDOMDocument3; const SchemaFiles: TArray<string>; out Diagnostics: TArray<string>;
      const OriginalContent: TBytes = nil): Boolean;
    procedure BeginDocumentBytes(const Content: TBytes; const BaseUri: string);
    function EvaluateBooleanBytes(const Content: TBytes; const BaseUri, Expression: string; const Namespaces: TArray<string>): Boolean;
    function TransformBytes(const Content: TBytes; const BaseUri, StylesheetFile: string;
      const InputDocument: TBytes = nil; const InputDocumentBaseUri: string = ''): TBytes;
  end;

implementation

uses
  System.Variants, System.IOUtils, System.StrUtils, System.NetEncoding, System.RegularExpressions, System.Diagnostics, Winapi.ActiveX, Winapi.ShlwApi, System.Win.ComObj;

const
  UnitName = 'MGKositEngine';
  SchemaNamespace = 'http://www.w3.org/2001/XMLSchema';

// Das Präfix gilt ausschließlich für lokale Win32-Dateizugriffe, niemals für Dokument- oder Ressourcen-URIs.
function ExtendedLocalPath(const FileName: string): string;
var
  AbsoluteFileName: string;
begin
  if Trim(FileName) = '' then
    raise EMGKositEngine.Create('Ein lokaler Dateipfad muss angegeben werden.');
  AbsoluteFileName := ExpandFileName(FileName);
  if StartsText('\\', AbsoluteFileName) then
    raise EMGKositEngine.Create('Netzwerkpfade sind für die Validierung nicht erlaubt: ' + AbsoluteFileName);
  Result := '\\?\' + AbsoluteFileName;
end;

// MSXML erhält unveränderte Bytes; die Windows-Dateinamenslänge beeinflusst das Parsen nicht.
function LoadDomBytes(const Document: IXMLDOMDocument3; const Content: TBytes): Boolean;
var
  Stream: TBytesStream;
  Adapter: IStream;
  Source: OleVariant;
begin
  Stream := TBytesStream.Create(Content);
  try
    Adapter := TStreamAdapter.Create(Stream, soReference);
    Source := IUnknown(Adapter);
    Result := Boolean(Document.load(Source));
  finally
    VarClear(Source);
    Adapter := nil;
    FreeAndNil(Stream);
  end;
end;

// Das aufgelöste Handle verhindert ein Verlassen freigegebener Verzeichnisse über Junctions.
function CanonicalLocalPath(const FileName: string; const IsDirectory: Boolean): string;
var
  FileHandle: THandle;
  Flags, RequiredLength, ErrorCode: DWORD;
  RequestedPath: string;
begin
  if Trim(FileName) = '' then
    raise EMGKositEngine.Create('Ein lokaler Dateipfad muss angegeben werden.');
  Result := ExpandFileName(FileName);
  RequestedPath := Result;
  if StartsText('\\', Result) then
    raise EMGKositEngine.Create('Netzwerkpfade sind für die Validierung nicht erlaubt: ' + Result);
  Flags := FILE_ATTRIBUTE_NORMAL;
  if IsDirectory then
    Flags := FILE_FLAG_BACKUP_SEMANTICS;
  FileHandle := CreateFile(PChar(ExtendedLocalPath(Result)), 0, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING, Flags, 0);
  if FileHandle = INVALID_HANDLE_VALUE then
  begin
    // Die Systemmeldung allein nennt weder den fehlenden Import noch seine Herkunft.
    ErrorCode := GetLastError;
    raise EMGKositEngine.CreateFmt('Lokale Ressource fehlt oder ist nicht lesbar: %s (Systemfehler %d: %s)',
      [RequestedPath, ErrorCode, SysErrorMessage(ErrorCode)]);
  end;
  try
    SetLength(Result, 32768);
    RequiredLength := GetFinalPathNameByHandle(FileHandle, PChar(Result), Length(Result), 0);
    if RequiredLength = 0 then
    begin
      ErrorCode := GetLastError;
      raise EMGKositEngine.CreateFmt('Lokaler Ressourcenpfad kann nicht aufgelöst werden: %s (Systemfehler %d: %s)',
        [RequestedPath, ErrorCode, SysErrorMessage(ErrorCode)]);
    end;
    if RequiredLength >= DWORD(Length(Result)) then
      raise EMGKositEngine.Create('Der aufgelöste Dateipfad überschreitet die unterstützte Länge.');
    SetLength(Result, RequiredLength);
    if StartsText('\\?\UNC\', Result) then
      raise EMGKositEngine.Create('Netzwerkziele sind für die Validierung nicht erlaubt: ' + Result);
    if StartsText('\\?\', Result) then
      Delete(Result, 1, 4);
  finally
    CloseHandle(FileHandle);
  end;
end;

// Nur XML-/XSD-Inhaltsfehler dürfen als fachliches Validierungsergebnis erscheinen.
function IsXmlContentError(const ErrorCode: Integer): Boolean;
begin
  Result := (Cardinal(ErrorCode) and $FFFF0000) = $C00C0000;
end;

// Die Position und Datei bleiben unabhängig von der lokalisierten COM-Meldung erhalten.
function DescribeParseError(const ParseError: IXMLDOMParseError): string;
begin
  Result := Format('MSXML 0x%s: %s [Datei: %s; Zeile: %d; Position: %d]',
    [IntToHex(Cardinal(Integer(ParseError.errorCode)), 8), Trim(string(ParseError.reason)),
     string(ParseError.url), Integer(ParseError.line), Integer(ParseError.linepos)]);
end;

// Bereits initialisierte MTA-Threads werden akzeptiert, ohne deren COM-Zähler zu verändern.
constructor TMGKositEngine.Create(const SaxonLibraryFile: string);
var
  InitializationResult: HRESULT;
begin
  inherited Create;
  FOwnerThread := GetCurrentThreadId;
  InitializationResult := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  FMustUninitialize := Succeeded(InitializationResult);
  if not FMustUninitialize and (InitializationResult <> RPC_E_CHANGED_MODE) then
    OleCheck(InitializationResult);
  FNative := TMGKositNative.Create(SaxonLibraryFile);
  FSchemaCaches := TDictionary<string, IXMLDOMSchemaCollection2>.Create;
  FMemoryResources := TDictionary<string, TBytes>.Create;
  FCheckedStylesheets := TDictionary<string, Boolean>.Create;
end;

// Kompilierte Schemas und alle übrigen COM-Objekte werden vor CoUninitialize freigegeben.
destructor TMGKositEngine.Destroy;
begin
  RequireOwnerThread;
  try
    FreeAndNil(FSchemaCaches);
    FreeAndNil(FMemoryResources);
    FreeAndNil(FCheckedStylesheets);
    FreeAndNil(FNative);
  finally
    if FMustUninitialize then
    begin
      FMustUninitialize := False;
      CoUninitialize;
    end;
    inherited Destroy;
  end;
end;

// Der Aufrufer kann den geprüften Native-Abbau vor der Objektfreigabe ausdrücklich anfordern.
procedure TMGKositEngine.Close;
begin
  RequireOwnerThread;
  FSchemaCaches.Clear;
  FCheckedStylesheets.Clear;
  FNative.Close;
end;

// Ein Quelldokument wird nur während genau einer Rechnungsprüfung gemeinsam verwendet.
procedure TMGKositEngine.BeginDocument(const XmlFile: string);
var
  Watch: TStopwatch;
begin
  RequireOwnerThread;
  Watch := TStopwatch.StartNew;
  try
    FNative.BeginDocument(RequireReadableFile(XmlFile));
  finally
    FDocumentParsingMs := FDocumentParsingMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

// Der Dokumentkontext endet nach genau einer Validierung und gibt den gehaltenen XDM-Handle frei.
procedure TMGKositEngine.EndDocument;
begin
  RequireOwnerThread;
  FNative.EndDocument;
end;

// Die Zähler stammen von tatsächlich erzeugten Engine-Objekten derselben Instanz.
function TMGKositEngine.Statistics: TMGKositStatistics;
begin
  RequireOwnerThread;
  Result.SchemaCompilationCount := FSchemaCompilationCount;
  Result.StylesheetCompilationCount := FNative.StylesheetCompilationCount;
  Result.XPathProcessorCount := FNative.XPathProcessorCount;
  Result.SourceParseCount := FNative.SourceParseCount;
  Result.SchemaCompilationMs := FSchemaCompilationMs;
  Result.SchemaValidationMs := FSchemaValidationMs;
  Result.XPathMs := FXPathMs;
  Result.TransformationMs := FTransformationMs;
  Result.DocumentParsingMs := FDocumentParsingMs;
  Result.SvrlProjectionMs := 0;
  Result.DomMs := FDomMs;
  Result.WorkingDirectoryMs := 0;
  Result.TemporaryCleanupMs := 0;
end;

// COM und Native-Isolate haben denselben Thread-Besitzer.
procedure TMGKositEngine.RequireOwnerThread;
begin
  if FOwnerThread <> GetCurrentThreadId then
    raise EMGKositEngine.Create('Die KoSIT-Engine wird aus einem anderen Thread verwendet.');
end;

// Nur ausdrücklich konfigurierte lokale Repositories dürfen Schemaressourcen bereitstellen.
procedure TMGKositEngine.ConfigureResourceRoots(const RootDirectories: TArray<string>);
var
  RootIndex: Integer;
  Roots: TArray<string>;
begin
  RequireOwnerThread;
  if Length(RootDirectories) = 0 then
    raise EMGKositEngine.Create('Mindestens ein lokales Regelverzeichnis muss konfiguriert werden.');
  SetLength(Roots, Length(RootDirectories));
  for RootIndex := 0 to High(RootDirectories) do
  begin
    if not DirectoryExists(ExtendedLocalPath(RootDirectories[RootIndex])) then
      raise EMGKositEngine.Create('Das Regelverzeichnis fehlt: ' + RootDirectories[RootIndex]);
    Roots[RootIndex] := IncludeTrailingPathDelimiter(CanonicalLocalPath(RootDirectories[RootIndex], True));
  end;
  FResourceRoots := Roots;
  // Geänderte Freigaben dürfen keine bereits kompilierten Schemas überleben.
  FSchemaCaches.Clear;
  FCheckedStylesheets.Clear;
end;

// Datei-I/O-Fehler dürfen keine fachlich ungültige XML-Instanz vortäuschen.
function TMGKositEngine.RequireReadableFile(const FileName: string): string;
var
  InputStream: TFileStream;
begin
  Result := CanonicalLocalPath(FileName, False);
  InputStream := TFileStream.Create(ExtendedLocalPath(Result), fmOpenRead or fmShareDenyWrite);
  FreeAndNil(InputStream);
end;

// Der lokale Dateizugriff verwendet immer den langen Win32-Pfad, die Dokumentidentität bleibt unverändert.
function TMGKositEngine.ReadFileBytes(const FileName: string): TBytes;
var
  Stream: TFileStream;
begin
  RequireOwnerThread;
  Stream := TFileStream.Create(ExtendedLocalPath(RequireReadableFile(FileName)), fmOpenRead or fmShareDenyWrite);
  try
    if Stream.Size > High(Integer) then
      raise EMGKositEngine.Create('Die XML-/Schemadatei überschreitet die unterstützte Größe: ' + FileName);
    SetLength(Result, Integer(Stream.Size));
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    FreeAndNil(Stream);
  end;
end;

// Die Prüfung verwendet den physisch aufgelösten Dateipfad und eine Verzeichnisgrenze.
function TMGKositEngine.RequireResourceFile(const FileName: string): string;
var
  Root: string;
begin
  if Length(FResourceRoots) = 0 then
    raise EMGKositEngine.Create('Die lokalen Regelverzeichnisse wurden nicht konfiguriert.');
  Result := RequireReadableFile(FileName);
  for Root in FResourceRoots do
    if SameText(Copy(Result, 1, Length(Root)), Root) then
      Exit;
  raise EMGKositEngine.Create('Die Regelressource liegt außerhalb der konfigurierten Verzeichnisse: ' + Result);
end;

// Nur das bereits kompilierte Hauptstylesheet darf seinen geprüften Importgraphen wiederverwenden.
// Bei einem neuen Hauptstylesheet werden auch schon anderweitig verwendete Imports erneut geprüft, da Saxon sie neu einliest.
function TMGKositEngine.RequireCheckedStylesheet(const FileName: string): string;
var
  CheckedFiles: TDictionary<string, Boolean>;
begin
  Result := RequireResourceFile(FileName);
  if FCheckedStylesheets.ContainsKey(Result) then Exit;
  CheckedFiles := TDictionary<string, Boolean>.Create;
  try
    CheckStylesheetResources(Result, CheckedFiles);
  finally
    FreeAndNil(CheckedFiles);
  end;
end;

// Windows löst lokale URI-Referenzen einschließlich Prozentkodierung und xml:base wie der Stylesheetprozessor auf.
function StylesheetReferencePath(const FileName: string; const Reference: IXMLDOMElement): string;
var
  Buffer: string;
  BufferLength: DWORD;
  BaseUri, Location: string;

  // Die Reihenfolge beginnt am Dokumentelement, damit nähere xml:base-Angaben auf der geerbten Basis aufbauen.
  procedure ApplyBase(const Node: IXMLDOMNode);
  var
    BaseAttribute: IXMLDOMNode;
  begin
    if Node = nil then Exit;
    ApplyBase(Node.parentNode);
    if Node.attributes = nil then Exit;
    BaseAttribute := Node.attributes.getNamedItem('xml:base');
    if BaseAttribute = nil then Exit;
    BufferLength := 32768;
    SetLength(Buffer, BufferLength);
    if Failed(UrlCombine(PChar(BaseUri), PChar(BaseAttribute.text), PChar(Buffer), BufferLength, 0)) then
      raise EMGKositEngine.Create('Die Stylesheet-Basis kann nicht aufgelöst werden: ' + string(BaseAttribute.text));
    BaseUri := PChar(Buffer);
  end;

begin
  BufferLength := 32768;
  SetLength(Buffer, BufferLength);
  if Failed(UrlCreateFromPath(PChar(FileName), PChar(Buffer), @BufferLength, 0)) then
    raise EMGKositEngine.Create('Die lokale Stylesheet-URI kann nicht gebildet werden: ' + FileName);
  BaseUri := PChar(Buffer);
  ApplyBase(Reference);
  Location := VarToStr(Reference.getAttribute('href'));
  BufferLength := 32768;
  SetLength(Buffer, BufferLength);
  if Failed(UrlCombine(PChar(BaseUri), PChar(Location), PChar(Buffer), BufferLength, 0)) then
    raise EMGKositEngine.Create('Die Stylesheet-Referenz kann nicht aufgelöst werden: ' + Location);
  BaseUri := PChar(Buffer);
  // Andere Protokolle werden unverändert durch das Native-Protokollverbot diagnostiziert.
  if not StartsText('file:', BaseUri) then Exit('');
  // Datei-URIs kodieren UTF-8. Die ANSI-Dekodierung von PathCreateFromUrl verändert beispielsweise ä.
  // Ein Pluszeichen ist im URI-Pfad ein Dateinamenbestandteil und kein Formular-Leerzeichen.
  BaseUri := TNetEncoding.URL.Decode(StringReplace(BaseUri, '+', '%2B', [rfReplaceAll]));
  if StartsText('file:///', BaseUri) then
    Result := Copy(BaseUri, 9, MaxInt)
  else if StartsText('file://', BaseUri) then
    Result := '\\' + Copy(BaseUri, 8, MaxInt)
  else
  begin
    Result := Copy(BaseUri, 6, MaxInt);
    if StartsText('/', Result) then Delete(Result, 1, 1);
  end;
  Result := StringReplace(Result, '/', '\', [rfReplaceAll]);
end;

// Auch nachgeladene Stylesheets müssen innerhalb der freigegebenen Wurzeln liegen.
procedure TMGKositEngine.CheckStylesheetResources(const FileName: string; const CheckedFiles: TDictionary<string, Boolean>);
var
  AbsoluteFileName, ImportedFile: string;
  Document: IXMLDOMDocument3;
  References: IXMLDOMNodeList;
  ReferenceIndex: Integer;
begin
  AbsoluteFileName := RequireResourceFile(FileName);
  if CheckedFiles.ContainsKey(AbsoluteFileName) then Exit;
  CheckedFiles.Add(AbsoluteFileName, True);
  Document := LoadDocument(AbsoluteFileName);
  Document.setProperty('SelectionNamespaces', 'xmlns:xsl="http://www.w3.org/1999/XSL/Transform"');
  if Document.selectSingleNode('//xsl:result-document') <> nil then
    raise EMGKositEngine.Create('xsl:result-document ist für lokale Validierungsregeln nicht erlaubt: ' + AbsoluteFileName);
  References := Document.selectNodes('/xsl:stylesheet/xsl:include | /xsl:stylesheet/xsl:import | /xsl:transform/xsl:include | /xsl:transform/xsl:import');
  for ReferenceIndex := 0 to References.length - 1 do
  begin
    ImportedFile := StylesheetReferencePath(AbsoluteFileName, References.item[ReferenceIndex] as IXMLDOMElement);
    if ImportedFile <> '' then
      CheckStylesheetResources(ImportedFile, CheckedFiles);
  end;
end;

// DTD-Freigaben gelten ausschließlich für bereits auf das Repository begrenzte XSD-Dateien.
function TMGKositEngine.CreateDocument(const AllowInternalDtd: Boolean): IXMLDOMDocument3;
begin
  RequireOwnerThread;
  Result := CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
  Result.async := False;
  Result.validateOnParse := False;
  Result.resolveExternals := False;
  Result.setProperty('ProhibitDTD', not AllowInternalDtd);
  Result.setProperty('UseInlineSchema', False);
  Result.setProperty('MultipleErrorMessages', True);
end;

// Konfigurationen und Instanzen werden ohne DTD, externe Ressourcen und Inline-Schemas gelesen.
function TMGKositEngine.NewDocument(const Xml: string): IXMLDOMDocument3;
var
  Watch: TStopwatch;
begin
  RequireOwnerThread;
  Watch := TStopwatch.StartNew;
  try
    Result := CreateDocument(False);
    if (Xml <> '') and not Boolean(Result.loadXML(Xml)) then
      raise EMGKositEngine.Create('XML kann nicht gelesen werden. ' + DescribeParseError(Result.parseError));
  finally
    FDomMs := FDomMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

// Lokale XML-Dateien werden ohne externe Referenzen und ohne MSXML-Dateipfadgrenze aus Bytes geladen.
function TMGKositEngine.LoadDocument(const FileName: string): IXMLDOMDocument3;
var
  AbsoluteFileName: string;
  Watch: TStopwatch;
begin
  RequireOwnerThread;
  Watch := TStopwatch.StartNew;
  try
    AbsoluteFileName := RequireReadableFile(FileName);
    Result := CreateDocument(False);
    if not LoadDomBytes(Result, ReadFileBytes(AbsoluteFileName)) then
      raise EMGKositEngine.Create('XML kann nicht gelesen werden. ' + AbsoluteFileName + ': ' + DescribeParseError(Result.parseError));
  finally
    FDomMs := FDomMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

// Das originale UBL-Signaturschema benötigt interne DTD-Deklarationen, keine externen Entitäten.
function TMGKositEngine.LoadSchema(const FileName: string): IXMLDOMDocument3;
var
  AbsoluteFileName, DtdText: string;
begin
  AbsoluteFileName := RequireResourceFile(FileName);
  Result := CreateDocument(True);
  if not LoadDomBytes(Result, ReadFileBytes(AbsoluteFileName)) then
    raise EMGKositEngine.Create('Das Schema kann nicht gelesen werden. ' + AbsoluteFileName + ': ' + DescribeParseError(Result.parseError));
  if Result.doctype <> nil then
  begin
    DtdText := Result.doctype.xml;
    if TRegEx.IsMatch(DtdText, '\b(?:SYSTEM|PUBLIC)\s+["'']') then
      raise EMGKositEngine.Create('Externe DTD-Ressourcen sind im Schema nicht erlaubt: ' + AbsoluteFileName);
  end;
  if Result.documentElement = nil then
    raise EMGKositEngine.Create('Das Schema enthält kein Wurzelelement: ' + AbsoluteFileName);
  if (string(Result.documentElement.namespaceURI) <> SchemaNamespace) or (string(Result.documentElement.baseName) <> 'schema') then
    raise EMGKositEngine.Create('Die Regelressource enthält kein XML-Schema: ' + AbsoluteFileName);
end;

// Der gesamte Importgraph wird vor dem MSXML-Cache auf lokale erlaubte Ziele geprüft.
// Import und Include werden vollständig geprüft und als Namespace-Komponenten registriert; MSXML lädt keine Dateien nach.
procedure TMGKositEngine.CollectFileSchemas(const FileName, InheritedNamespace: string; const IsInclude: Boolean;
  const Documents: TDictionary<string, IXMLDOMDocument3>);
var
  AbsoluteFileName, TargetNamespace, CacheKey, Location, ImportedFile, ExpectedNamespace: string;
  Document, ImportedDocument: IXMLDOMDocument3;
  References: IXMLDOMNodeList;
  Reference: IXMLDOMElement;
  ReferenceIndex: Integer;
begin
  AbsoluteFileName := RequireResourceFile(FileName);
  Document := LoadSchema(AbsoluteFileName);
  Document.setProperty('SelectionNamespaces', 'xmlns:xs="http://www.w3.org/2001/XMLSchema"');
  if Document.selectSingleNode('//*[@xml:base]') <> nil then
    raise EMGKositEngine.Create('xml:base ist in lokalen Schemaressourcen nicht erlaubt: ' + AbsoluteFileName);
  TargetNamespace := VarToStr(Document.documentElement.getAttribute('targetNamespace'));
  if IsInclude then
  begin
    if (TargetNamespace <> '') and (TargetNamespace <> InheritedNamespace) then
      raise EMGKositEngine.Create('Abweichender Namespace im lokalen Schema-Include: ' + AbsoluteFileName);
    if (TargetNamespace = '') and (InheritedNamespace <> '') then
    begin
      TargetNamespace := InheritedNamespace;
      Document.documentElement.setAttribute('targetNamespace', TargetNamespace);
      if VarToStr(Document.documentElement.getAttribute('xmlns')) = '' then
        Document.documentElement.setAttribute('xmlns', TargetNamespace);
    end;
  end;
  CacheKey := AbsoluteFileName + #0 + TargetNamespace;
  if Documents.ContainsKey(CacheKey) then Exit;
  Documents.Add(CacheKey, Document);
  References := Document.selectNodes('/xs:schema/xs:import | /xs:schema/xs:include | /xs:schema/xs:redefine');
  for ReferenceIndex := 0 to References.length - 1 do
  begin
    Reference := References.item[ReferenceIndex] as IXMLDOMElement;
    Location := VarToStr(Reference.getAttribute('schemaLocation'));
    if Location = '' then Continue;
    // Ein URI-Protokoll darf weder Netzwerkzugriff noch eine abweichende URI-Auflösung auslösen.
    if (Pos(':', Location) <> 0) or StartsText('\\', Location) or StartsText('//', Location) or
       (Pos('%', Location) <> 0) or (Pos('#', Location) <> 0) or (Pos('?', Location) <> 0) then
      raise EMGKositEngine.Create('Das Schema verwendet keinen lokalen relativen Import: ' + Location);
    ImportedFile := RequireResourceFile(ExpandFileName(ExtractFilePath(AbsoluteFileName) + StringReplace(Location, '/', '\', [rfReplaceAll])));
    if Reference.baseName = 'import' then
    begin
      CollectFileSchemas(ImportedFile, '', False, Documents);
      ExpectedNamespace := VarToStr(Reference.getAttribute('namespace'));
      if not Documents.TryGetValue(ImportedFile + #0 + ExpectedNamespace, ImportedDocument) then
        raise EMGKositEngine.Create('Abweichender Namespace im lokalen Schemaimport: ' + ImportedFile);
      Reference.removeAttribute('schemaLocation');
    end
    else
    begin
      CollectFileSchemas(ImportedFile, TargetNamespace, True, Documents);
      if Reference.baseName = 'redefine' then
        ApplySchemaRedefinition(Document, Reference, Documents, TargetNamespace);
      Document.documentElement.removeChild(Reference);
    end;
  end;
end;

// Präfixauflösung erfolgt am jeweiligen Knoten, damit lokale Namespace-Deklarationen erhalten bleiben.
function SchemaQNameNamespace(const Node: IXMLDOMNode; const Prefix: string): string;
var
  CurrentNode, Attribute: IXMLDOMNode;
  AttributeName: string;
begin
  Result := '';
  AttributeName := 'xmlns';
  if Prefix <> '' then AttributeName := AttributeName + ':' + Prefix;
  CurrentNode := Node;
  while CurrentNode <> nil do
  begin
    if CurrentNode.attributes <> nil then
    begin
      Attribute := CurrentNode.attributes.getNamedItem(AttributeName);
      if Attribute <> nil then Exit(string(Attribute.text));
    end;
    CurrentNode := CurrentNode.parentNode;
  end;
end;

// Beim Verschieben aus xs:redefine müssen auch nur dort deklarierte Präfixe an der Komponente erhalten bleiben.
procedure PreserveSchemaNamespaces(const Component: IXMLDOMNode);
var
  CurrentNode, Attribute: IXMLDOMNode;
  Names: TStringList;
  AttributeIndex: Integer;
  AttributeName: string;
begin
  Names := TStringList.Create;
  try
    Names.CaseSensitive := True;
    CurrentNode := Component;
    while CurrentNode <> nil do
    begin
      if CurrentNode.attributes <> nil then
        for AttributeIndex := 0 to CurrentNode.attributes.length - 1 do
        begin
          Attribute := CurrentNode.attributes.item[AttributeIndex];
          AttributeName := string(Attribute.nodeName);
          if ((AttributeName = 'xmlns') or StartsStr('xmlns:', AttributeName)) and (Names.IndexOf(AttributeName) < 0) then
          begin
            Names.Add(AttributeName);
            if CurrentNode <> Component then
              (Component as IXMLDOMElement).setAttribute(AttributeName, string(Attribute.text));
          end;
        end;
      CurrentNode := CurrentNode.parentNode;
    end;
  finally
    FreeAndNil(Names);
  end;
end;

// Die vorherige Komponente erhält einen internen Namen; Selbstreferenzen der Neudefinition beziehen sich auf diesen Stand.
procedure TMGKositEngine.ApplySchemaRedefinition(const Document: IXMLDOMDocument3; const Redefinition: IXMLDOMElement;
  const Documents: TDictionary<string, IXMLDOMDocument3>; const TargetNamespace: string);
var
  Components, References: IXMLDOMNodeList;
  Component, Original, Reference, Attribute: IXMLDOMNode;
  Candidate: IXMLDOMDocument3;
  ComponentName, PreviousName, PreviousPrefix, PreviousQName, QName, Prefix, LocalName: string;
  ComponentIndex, ReferenceIndex, Separator, ReplacementCount, PrefixIndex: Integer;
begin
  Components := Redefinition.selectNodes('*');
  for ComponentIndex := 0 to Components.length - 1 do
  begin
    Component := Components.item[ComponentIndex];
    if Component.baseName = 'annotation' then Continue;
    if not ((Component.baseName = 'simpleType') or (Component.baseName = 'complexType') or
      (Component.baseName = 'group') or (Component.baseName = 'attributeGroup')) then
      raise EMGKositEngine.Create('Nicht zulässige Komponente in xs:redefine: ' + string(Component.baseName));
    ComponentName := VarToStr((Component as IXMLDOMElement).getAttribute('name'));
    Original := nil;
    for Candidate in Documents.Values do
      if VarToStr(Candidate.documentElement.getAttribute('targetNamespace')) = TargetNamespace then
      begin
        Original := Candidate.selectSingleNode('/xs:schema/xs:' + string(Component.baseName) + '[@name="' + ComponentName + '"]');
        if Original <> nil then Break;
      end;
    if Original = nil then
      raise EMGKositEngine.Create('Die neu definierte Schemakomponente fehlt: ' + ComponentName);
    PreviousName := 'MGKositPrevious_' + IntToStr(Documents.Count) + '_' + IntToStr(ComponentIndex) + '_' + ComponentName;
    (Original as IXMLDOMElement).setAttribute('name', PreviousName);
    PreserveSchemaNamespaces(Component);
    ReplacementCount := 0;
    // Typen, Elemente und Gruppen besitzen getrennte XSD-Namensräume für ihre Komponenten.
    if Component.baseName = 'simpleType' then
      References := Component.selectNodes('./xs:restriction[@base]')
    else if Component.baseName = 'complexType' then
      References := Component.selectNodes('./xs:simpleContent/*[@base] | ./xs:complexContent/*[@base]')
    else if Component.baseName = 'group' then
      References := Component.selectNodes('.//xs:group[@ref]')
    else
      References := Component.selectNodes('.//xs:attributeGroup[@ref]');
    for ReferenceIndex := 0 to References.length - 1 do
    begin
      Reference := References.item[ReferenceIndex];
      Attribute := Reference.attributes.getNamedItem('base');
      if Attribute = nil then Attribute := Reference.attributes.getNamedItem('ref');
      QName := string(Attribute.text);
      Separator := Pos(':', QName);
      Prefix := '';
      LocalName := QName;
      if Separator > 0 then
      begin
        Prefix := Copy(QName, 1, Separator - 1);
        LocalName := Copy(QName, Separator + 1, MaxInt);
      end;
      if (LocalName = ComponentName) and (SchemaQNameNamespace(Reference, Prefix) = TargetNamespace) then
      begin
        PreviousQName := PreviousName;
        if TargetNamespace <> '' then
        begin
          // Die konkrete Referenz kann ein am Komponentenkopf verfügbares Präfix lokal überschatten.
          PreviousPrefix := 'mgkositPrevious';
          PrefixIndex := 0;
          while (SchemaQNameNamespace(Reference, PreviousPrefix) <> '') and (SchemaQNameNamespace(Reference, PreviousPrefix) <> TargetNamespace) do
          begin
            Inc(PrefixIndex);
            PreviousPrefix := 'mgkositPrevious' + IntToStr(PrefixIndex);
          end;
          (Reference as IXMLDOMElement).setAttribute('xmlns:' + PreviousPrefix, TargetNamespace);
          PreviousQName := PreviousPrefix + ':' + PreviousName;
        end;
        Attribute.text := PreviousQName;
        Inc(ReplacementCount);
      end;
    end;
    if ((Component.baseName = 'simpleType') or (Component.baseName = 'complexType')) and (ReplacementCount <> 1) then
      raise EMGKositEngine.Create('Eine Typ-Neudefinition benötigt genau einen Bezug auf den vorherigen Typ: ' + ComponentName);
    Document.documentElement.appendChild(Component);
  end;
end;

// Die geordnete Quellenliste bezeichnet ein kompiliertes Schema einschließlich seiner geprüften Imports.
function TMGKositEngine.GetSchemaCache(const SchemaFiles: TArray<string>): IXMLDOMSchemaCollection2;
var
  CacheKey, SchemaFile, TargetNamespace: string;
  ResolvedFiles: TArray<string>;
  SchemaDocument: IXMLDOMDocument3;
  SchemaDocumentVariant: OleVariant;
  Documents: TDictionary<string, IXMLDOMDocument3>;
  FileIndex: Integer;
  Watch: TStopwatch;
begin
  if Length(SchemaFiles) = 0 then
    raise EMGKositEngine.Create('Die Schema-Validierung benötigt mindestens eine XSD-Datei.');
  if FMemoryResources.ContainsKey(SchemaFiles[0]) then
    Exit(GetMemorySchemaCache(SchemaFiles));
  SetLength(ResolvedFiles, Length(SchemaFiles));
  CacheKey := '';
  for FileIndex := 0 to High(SchemaFiles) do
  begin
    ResolvedFiles[FileIndex] := RequireResourceFile(SchemaFiles[FileIndex]);
    CacheKey := CacheKey + IntToStr(Length(ResolvedFiles[FileIndex])) + ':' + ResolvedFiles[FileIndex];
  end;
  if FSchemaCaches.TryGetValue(CacheKey, Result) then
    Exit;
  Watch := TStopwatch.StartNew;
  Documents := TDictionary<string, IXMLDOMDocument3>.Create;
  try
    for SchemaFile in ResolvedFiles do
      CollectFileSchemas(SchemaFile, '', False, Documents);
    Result := CreateOleObject('Msxml2.XMLSchemaCache.6.0') as IXMLDOMSchemaCollection2;
    // Mehrere Quellen dürfen sich gegenseitig referenzieren; kompiliert wird nach dem Befüllen.
    Result.validateOnLoad := False;
    for SchemaDocument in Documents.Values do
    begin
      TargetNamespace := VarToStr(SchemaDocument.documentElement.getAttribute('targetNamespace'));
      // Die kontrolliert aufgelösten Includes und Imports stehen bereits gemeinsam im Cache.
      SchemaDocumentVariant := IDispatch(SchemaDocument);
      Result.add(TargetNamespace, SchemaDocumentVariant);
      VarClear(SchemaDocumentVariant);
    end;
    Result.validate;
    // Nur erfolgreiche Kompilierungen werden gespeichert; reparierte Ressourcen bleiben erneut prüfbar.
    FSchemaCaches.Add(CacheKey, Result);
    Inc(FSchemaCompilationCount);
  finally
    VarClear(SchemaDocumentVariant);
    FreeAndNil(Documents);
    FSchemaCompilationMs := FSchemaCompilationMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

// Schemafehler bleiben Infrastrukturfehler, XML-/XSD-Befunde der Instanz liefern False mit Diagnose.
function TMGKositEngine.ValidateSchemas(const XmlFile: string; const SchemaFiles: TArray<string>; out Diagnostic: string): Boolean;
var
  Watch: TStopwatch;
begin
  RequireOwnerThread;
  Watch := TStopwatch.StartNew;
  try
    Result := ValidateSchemaInstance(XmlFile, SchemaFiles, Diagnostic);
  finally
    FSchemaValidationMs := FSchemaValidationMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

// Jede XML-Instanz erhält ein frisches DOM mit dem wiederverwendeten kompilierten Schema.
function TMGKositEngine.ValidateSchemaInstance(const XmlFile: string; const SchemaFiles: TArray<string>; out Diagnostic: string): Boolean;
var
  AbsoluteXmlFile: string;
  InstanceDocument: IXMLDOMDocument3;
  SchemaCache: IXMLDOMSchemaCollection2;
  ParseError: IXMLDOMParseError;
  SchemaCacheVariant: OleVariant;
  NamespaceIndex: Integer;
  RootNamespaceKnown: Boolean;
begin
  RequireOwnerThread;
  Result := False;
  Diagnostic := '';
  AbsoluteXmlFile := RequireReadableFile(XmlFile);
  SchemaCache := GetSchemaCache(SchemaFiles);
  InstanceDocument := CreateDocument(False);
  SchemaCacheVariant := IDispatch(SchemaCache);
  InstanceDocument.schemas := SchemaCacheVariant;
  // Schemafehler müssen beim Parsen entstehen, weil DOM.validate die Quellposition verwirft.
  InstanceDocument.validateOnParse := True;
  VarClear(SchemaCacheVariant);
  if not LoadDomBytes(InstanceDocument, ReadFileBytes(AbsoluteXmlFile)) then
  begin
    ParseError := InstanceDocument.parseError;
    Diagnostic := DescribeParseError(ParseError);
    if not IsXmlContentError(Integer(ParseError.errorCode)) then
      raise EMGKositEngine.Create('Die Instanz kann nicht geladen werden. ' + Diagnostic);
    Exit;
  end;
  RootNamespaceKnown := False;
  for NamespaceIndex := 0 to SchemaCache.length - 1 do
    if string(SchemaCache.namespaceURI[NamespaceIndex]) = string(InstanceDocument.documentElement.namespaceURI) then
      RootNamespaceKnown := True;
  if not RootNamespaceKnown then
  begin
    Diagnostic := 'Für den Instanz-Namespace ist kein Schema konfiguriert: ' + string(InstanceDocument.documentElement.namespaceURI);
    Exit;
  end;
  ParseError := InstanceDocument.validate;
  if Integer(ParseError.errorCode) <> 0 then
  begin
    Diagnostic := DescribeParseError(ParseError);
    if not IsXmlContentError(Integer(ParseError.errorCode)) then
      raise EMGKositEngine.Create('Die Schema-Validierung ist fehlgeschlagen. ' + Diagnostic);
    Exit;
  end;
  Result := True;
end;

// Der Originalausdruck wird ohne Ersatzregeln durch die XPath-Engine ausgewertet.
function TMGKositEngine.EvaluateBoolean(const XmlFile, Expression: string; const Namespaces: TArray<string>): Boolean;
var
  Watch: TStopwatch;
begin
  RequireOwnerThread;
  Watch := TStopwatch.StartNew;
  try
    Result := FNative.EvaluateBoolean(RequireReadableFile(XmlFile), Expression, Namespaces);
  finally
    FXPathMs := FXPathMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

// Nur Stylesheets aus freigegebenen Regelverzeichnissen werden ausgeführt.
procedure TMGKositEngine.Transform(const XmlFile, StylesheetFile, OutputFile: string; const InputDocumentFile: string);
var
  ParameterFile, ResourceName: string;
  Watch: TStopwatch;
begin
  RequireOwnerThread;
  Watch := TStopwatch.StartNew;
  try
    ParameterFile := '';
    if InputDocumentFile <> '' then
      ParameterFile := RequireReadableFile(InputDocumentFile);
    ResourceName := RequireCheckedStylesheet(StylesheetFile);
    FNative.Transform(RequireReadableFile(XmlFile), ResourceName, OutputFile, ParameterFile);
    // Ein Compilerfehler darf noch keine Sicherheitsfreigabe für eine später reparierte Datei hinterlassen.
    FCheckedStylesheets.AddOrSetValue(ResourceName, True);
  finally
    FTransformationMs := FTransformationMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

// Die Version stammt aus dem tatsächlich geladenen Native-Prozessor.
function TMGKositEngine.Version: string;
begin
  RequireOwnerThread;
  Result := FNative.Version;
end;

// Eingebettete Regeln werden als unveränderliche Bytes registriert, ohne temporäre Materialisierung.
procedure TMGKositEngine.RegisterMemoryResource(const ResourceUri: string; const Content: TBytes);
begin
  RequireOwnerThread;
  if (ResourceUri = '') or (Length(Content) = 0) then
    raise EMGKositEngine.Create('Eine Speicherressource benötigt URI und Inhalt');
  FNative.RegisterMemoryStylesheet(ResourceUri, Content);
  // RegisterMemoryStylesheet verwirft sämtliche Native-Kompilate, einschließlich lokaler Stylesheets.
  FCheckedStylesheets.Clear;
  FMemoryResources.AddOrSetValue(ResourceUri, Copy(Content));
  FSchemaCaches.Clear;
end;

// MSXML liest den Byte-Stream selbst und berücksichtigt BOM sowie die XML-Kodierungsdeklaration.
function TMGKositEngine.LoadDocumentBytes(const Content: TBytes; const BaseUri: string): IXMLDOMDocument3;
var
  Watch: TStopwatch;
begin
  RequireOwnerThread;
  Watch := TStopwatch.StartNew;
  try
    Result := CreateDocument(False);
    if not LoadDomBytes(Result, Content) then
      raise EMGKositEngine.Create('XML kann nicht gelesen werden. ' + BaseUri + ': ' + DescribeParseError(Result.parseError));
  finally
    FDomMs := FDomMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

// Der zyklische Importgraph wird vor dem Kompilieren geschlossen; Originalbytes bleiben unverändert.
procedure TMGKositEngine.CollectMemorySchemas(const ResourceUri: string; const Documents: TDictionary<string, IXMLDOMDocument3>);
var
  Content: TBytes;
  Document, ImportedDocument: IXMLDOMDocument3;
  Imports: IXMLDOMNodeList;
  ImportNode: IXMLDOMElement;
  ImportIndex: Integer;
  Location, ImportedUri, ExpectedNamespace: string;
begin
  if Documents.ContainsKey(ResourceUri) then
    Exit;
  if not FMemoryResources.TryGetValue(ResourceUri, Content) then
    raise EMGKositEngine.Create('Nicht registrierter Schemaimport: ' + ResourceUri);
  Document := LoadDocumentBytes(Content, ResourceUri);
  if (Document.documentElement = nil) or (string(Document.documentElement.namespaceURI) <> SchemaNamespace) or
     (string(Document.documentElement.baseName) <> 'schema') then
    raise EMGKositEngine.Create('Die Speicherressource enthält kein XML-Schema: ' + ResourceUri);
  Document.setProperty('SelectionNamespaces', 'xmlns:xs="http://www.w3.org/2001/XMLSchema"');
  if Document.selectSingleNode('//*[@xml:base] | /xs:schema/xs:include | /xs:schema/xs:redefine') <> nil then
    raise EMGKositEngine.Create('Speicherschemas dürfen weder xml:base noch include/redefine verwenden: ' + ResourceUri);
  Documents.Add(ResourceUri, Document);
  Imports := Document.selectNodes('/xs:schema/xs:import');
  for ImportIndex := 0 to Imports.length - 1 do
  begin
    ImportNode := Imports.item[ImportIndex] as IXMLDOMElement;
    Location := VarToStr(ImportNode.getAttribute('schemaLocation'));
    if Location = '' then
      Continue;
    if (Pos(':', Location) > 0) or (Pos('/', Location) > 0) or (Pos('\', Location) > 0) or
       (Pos('%', Location) > 0) or (Pos('?', Location) > 0) or (Pos('#', Location) > 0) then
      raise EMGKositEngine.Create('Kein direkter registrierter Schemaimport: ' + Location);
    ImportedUri := Copy(ResourceUri, 1, LastDelimiter('/', ResourceUri)) + Location;
    CollectMemorySchemas(ImportedUri, Documents);
    ImportedDocument := Documents[ImportedUri];
    ExpectedNamespace := VarToStr(ImportNode.getAttribute('namespace'));
    if ExpectedNamespace <> VarToStr(ImportedDocument.documentElement.getAttribute('targetNamespace')) then
      raise EMGKositEngine.Create('Abweichender Namespace im registrierten Schemaimport: ' + ImportedUri);
    // Der Import bleibt bestehen; seine explizit registrierte Namespace-Komponente ersetzt nur den Transport-URI.
    ImportNode.removeAttribute('schemaLocation');
  end;
end;

// Alle importierten Namespace-Komponenten werden gemeinsam und erst nach geschlossenem Graph kompiliert.
function TMGKositEngine.GetMemorySchemaCache(const SchemaFiles: TArray<string>): IXMLDOMSchemaCollection2;
var
  Documents: TDictionary<string, IXMLDOMDocument3>;
  ResourceUri, CacheKey, TargetNamespace: string;
  Document: IXMLDOMDocument3;
  Source: OleVariant;
  Watch: TStopwatch;
begin
  CacheKey := 'memory:';
  for ResourceUri in SchemaFiles do
    CacheKey := CacheKey + IntToStr(Length(ResourceUri)) + ':' + ResourceUri;
  if FSchemaCaches.TryGetValue(CacheKey, Result) then
    Exit;
  Watch := TStopwatch.StartNew;
  Documents := TDictionary<string, IXMLDOMDocument3>.Create;
  try
    for ResourceUri in SchemaFiles do
      CollectMemorySchemas(ResourceUri, Documents);
    Result := CreateOleObject('Msxml2.XMLSchemaCache.6.0') as IXMLDOMSchemaCollection2;
    Result.validateOnLoad := False;
    for Document in Documents.Values do
    begin
      TargetNamespace := VarToStr(Document.documentElement.getAttribute('targetNamespace'));
      Source := IDispatch(Document);
      Result.add(TargetNamespace, Source);
      VarClear(Source);
    end;
    Result.validate;
    FSchemaCaches.Add(CacheKey, Result);
    Inc(FSchemaCompilationCount);
  finally
    VarClear(Source);
    FreeAndNil(Documents);
    FSchemaCompilationMs := FSchemaCompilationMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

// Originalbytes erhalten ihre Parserpositionen; für erzeugte DOMs gilt ihre XML-Serialisierung als Quelle.
function TMGKositEngine.ValidateDocumentSchemas(const Document: IXMLDOMDocument3; const SchemaFiles: TArray<string>; out Diagnostic: string;
  const OriginalContent: TBytes): Boolean;
var
  Diagnostics: TArray<string>;
begin
  Result := ValidateDocumentSchemaDiagnostics(Document, SchemaFiles, Diagnostics, OriginalContent);
  Diagnostic := string.Join(sLineBreak, Diagnostics);
end;

// Jeder vom Parser gemeldete Schemafehler bleibt als eigene Diagnose erhalten, auch bei identischer Fehlerart.
function TMGKositEngine.ValidateDocumentSchemaDiagnostics(const Document: IXMLDOMDocument3; const SchemaFiles: TArray<string>; out Diagnostics: TArray<string>;
  const OriginalContent: TBytes): Boolean;
var
  SchemaCache: IXMLDOMSchemaCollection2;
  ValidationDocument: IXMLDOMDocument3;
  Source, PreviousSchemas: OleVariant;
  ParseError: IXMLDOMParseError;
  ExtendedError: IXMLDOMParseError2;
  ParseErrors: IXMLDOMParseErrorCollection;
  NamespaceIndex, ErrorIndex: Integer;
  RootNamespaceKnown, Loaded: Boolean;
  Watch: TStopwatch;
begin
  RequireOwnerThread;
  Result := False;
  Diagnostics := nil;
  if (Document = nil) or (Document.documentElement = nil) then
    raise EMGKositEngine.Create('Die Schema-Validierung benötigt ein XML-Dokument mit Wurzelelement');
  Watch := TStopwatch.StartNew;
  try
    SchemaCache := GetSchemaCache(SchemaFiles);
    RootNamespaceKnown := False;
    for NamespaceIndex := 0 to SchemaCache.length - 1 do
      if string(SchemaCache.namespaceURI[NamespaceIndex]) = string(Document.documentElement.namespaceURI) then
        RootNamespaceKnown := True;
    if not RootNamespaceKnown then
    begin
      Diagnostics := ['Für den Instanz-Namespace ist kein Schema konfiguriert: ' + string(Document.documentElement.namespaceURI)];
      Exit;
    end;
    ValidationDocument := CreateDocument(False);
    ValidationDocument.validateOnParse := True;
    PreviousSchemas := ValidationDocument.schemas;
    Source := IDispatch(SchemaCache);
    try
      ValidationDocument.schemas := Source;
      if OriginalContent = nil then
        Loaded := ValidationDocument.loadXML(Document.xml)
      else
        Loaded := LoadDomBytes(ValidationDocument, OriginalContent);
      if not Loaded then
        ParseError := ValidationDocument.parseError
      else
        ParseError := ValidationDocument.validate;
      if Integer(ParseError.errorCode) <> 0 then
      begin
        if not IsXmlContentError(Integer(ParseError.errorCode)) then
          raise EMGKositEngine.Create('Die Schema-Validierung ist fehlgeschlagen. ' + DescribeParseError(ParseError));
        ExtendedError := ParseError as IXMLDOMParseError2;
        ParseErrors := ExtendedError.allErrors;
        SetLength(Diagnostics, ParseErrors.length);
        for ErrorIndex := 0 to ParseErrors.length - 1 do
          Diagnostics[ErrorIndex] := DescribeParseError(ParseErrors.item[ErrorIndex]);
        Exit;
      end;
      Result := True;
    finally
      ValidationDocument.schemas := PreviousSchemas;
      VarClear(Source);
      VarClear(PreviousSchemas);
    end;
  finally
    FSchemaValidationMs := FSchemaValidationMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

// Das originale XDM wird ausschließlich für die Dauer der aktuellen Validierung gehalten.
procedure TMGKositEngine.BeginDocumentBytes(const Content: TBytes; const BaseUri: string);
var
  Watch: TStopwatch;
begin
  RequireOwnerThread;
  Watch := TStopwatch.StartNew;
  try
    FNative.BeginDocumentBytes(Content, BaseUri);
  finally
    FDocumentParsingMs := FDocumentParsingMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

// Der Originalausdruck wird ohne Ersatzregeln über dem Speicher-XDM ausgewertet.
function TMGKositEngine.EvaluateBooleanBytes(const Content: TBytes; const BaseUri, Expression: string; const Namespaces: TArray<string>): Boolean;
var
  Watch: TStopwatch;
begin
  RequireOwnerThread;
  Watch := TStopwatch.StartNew;
  try
    Result := FNative.EvaluateBooleanBytes(Content, BaseUri, Expression, Namespaces);
  finally
    FXPathMs := FXPathMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

// Nur registrierte Ressourcen oder geprüfte lokale Stylesheets dürfen ausgeführt werden.
function TMGKositEngine.TransformBytes(const Content: TBytes; const BaseUri, StylesheetFile: string;
  const InputDocument: TBytes; const InputDocumentBaseUri: string): TBytes;
var
  ResourceName: string;
  Watch: TStopwatch;
  IsLocalStylesheet: Boolean;
begin
  RequireOwnerThread;
  Watch := TStopwatch.StartNew;
  try
    IsLocalStylesheet := not FMemoryResources.ContainsKey(StylesheetFile);
    if not IsLocalStylesheet then
      ResourceName := StylesheetFile
    else
      ResourceName := RequireCheckedStylesheet(StylesheetFile);
    Result := FNative.TransformBytes(Content, BaseUri, ResourceName, BaseUri, InputDocument, InputDocumentBaseUri);
    if IsLocalStylesheet then
      FCheckedStylesheets.AddOrSetValue(ResourceName, True);
  finally
    FTransformationMs := FTransformationMs + Watch.Elapsed.TotalMilliseconds;
  end;
end;

end.
