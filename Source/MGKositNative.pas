unit MGKositNative;

interface

uses
  System.SysUtils, System.IOUtils, System.NetEncoding, System.RegularExpressions, System.Generics.Collections, Winapi.Windows;

type
  EMGKositNative = class(Exception);

  // Die Bindung gilt für die C-Exports des gepinnten SaxonC-Core-SDKs 12.10.1.
  TMGKositNative = class
  private type
    TCreateIsolate = function(Parameters: Pointer; out Isolate, Thread: Pointer): Integer; cdecl;
    TTearDown = function(Thread: Pointer): Integer; cdecl;
    TCreateProcessor = function(Thread: Pointer; Licensed: Integer): Int64; cdecl;
    TCreateXPath = function(Thread, Processor: Pointer): Int64; cdecl;
    TCreateData = function(Thread: Pointer; Capacity: Integer): Int64; cdecl;
    TGetResultDocuments = function(Thread, Allocator, Handler: Pointer): Pointer; cdecl;
    TAddProperty = procedure(Thread, Data: Pointer; Name, Value: PAnsiChar); cdecl;
    TAddParameter = procedure(Thread, Data: Pointer; Name: PAnsiChar; Value: Pointer); cdecl;
    TDestroyHandle = procedure(Thread, Handle: Pointer); cdecl;
    TParseFile = function(Thread, Processor: Pointer; DirectoryName, FileName: PAnsiChar): Int64; cdecl;
    TParseString = function(Thread: Pointer; DirectoryName: PAnsiChar; Processor, Builder, Validator: Pointer; Source, Encoding: PAnsiChar): Int64; cdecl;
    TSetBaseUri = function(Thread, Builder: Pointer; Uri: PAnsiChar): Int64; cdecl;
    TDeclareNamespace = function(Thread, XPath: Pointer; Prefix, NamespaceUri: PAnsiChar): Int64; cdecl;
    TBooleanValue = function(Thread, XPath: Pointer; DirectoryName, Expression, Encoding: PAnsiChar; Data: Pointer): Integer; cdecl;
    TCompileStylesheet = function(Thread, Processor: Pointer; DirectoryName, Stylesheet: PAnsiChar; Jit: Integer; Data: Pointer): Int64; cdecl;
    TCompileNode = function(Thread, Processor: Pointer; DirectoryName: PAnsiChar; Stylesheet: Pointer; Jit: Integer; Data: Pointer): Int64; cdecl;
    TTransformBytes = function(Thread, Allocator: Pointer; DirectoryName: PAnsiChar; Processor, Executable: Pointer;
      Source, Stylesheet: PAnsiChar; Data: Pointer): PAnsiChar; cdecl;
    TProductVersion = function(Thread, Processor: Pointer): PAnsiChar; cdecl;
    TErrorMessage = function(Thread: Pointer): PAnsiChar; cdecl;
    TClearException = procedure(Thread: Pointer); cdecl;
    TCheckException = function(Thread: Pointer): Byte; cdecl;
    TConfiguration = function(Thread, Processor: Pointer; Name, Value: PAnsiChar): Int64; cdecl;
  private
    FLibrary: HMODULE;
    FIsolate, FThread: Pointer;
    FProcessor: Int64;
    FXsltProcessor, FDocument: Int64;
    FDocumentFile: string;
    FDocumentBytes: TBytes;
    FDocumentBaseUri: string;
    FDocumentIsBytes: Boolean;
    FMemoryStylesheets: TDictionary<string, TBytes>;
    FStylesheets, FXPaths: TDictionary<string, Int64>;
    FXPathBaseUris: TDictionary<Int64, string>;
    FStylesheetCompilationCount, FXPathProcessorCount, FSourceParseCount: Integer;
    FCreateXslt: TCreateXPath;
    FCompileStylesheet: TCompileStylesheet;
    FCompileNode: TCompileNode;
    FOwnerThread: DWORD;
    FCaptureSecondaryResults: Boolean;
    FCreateIsolate: TCreateIsolate;
    FTearDown: TTearDown;
    FCreateProcessor: TCreateProcessor;
    FCreateXPath: TCreateXPath;
    FCreateData: TCreateData;
    FCreateResultHandler: TCreateData;
    FGetResultDocuments: TGetResultDocuments;
    FAddProperty: TAddProperty;
    FAddParameter: TAddParameter;
    FDestroyHandle: TDestroyHandle;
    FParseFile: TParseFile;
    FParseString: TParseString;
    FCreateBuilder: TCreateXPath;
    FSetBaseUri: TSetBaseUri;
    FSetXPathBaseUri: TSetBaseUri;
    FDeclareNamespace: TDeclareNamespace;
    FBooleanValue: TBooleanValue;
    FTransformBytes: TTransformBytes;
    FProductVersion: TProductVersion;
    FErrorMessage: TErrorMessage;
    FClearException: TClearException;
    FConfiguration: TConfiguration;
    FCheckException: TCheckException;
    procedure CheckException(const Operation: string);
    function RequireExport(const Name: AnsiString): Pointer;
    procedure RequireOwnerThread;
    procedure RaiseNativeError(const Operation: string);
    procedure ReleaseHandle(var Handle: Int64);
    function ParseDocument(const XmlFile: string): Int64;
    function AcquireDocument(const XmlFile: string; out Owned: Boolean): Int64;
    function ParseDocumentBytes(const XmlBytes: TBytes; const BaseUri: string; const CountAsSource: Boolean = True): Int64;
    function AcquireDocumentBytes(const XmlBytes: TBytes; const BaseUri: string; out Owned: Boolean): Int64;
    function GetXPath(const Namespaces: array of string; const BaseUri: string = ''): Int64;
    procedure SetXPathBaseUri(const XPathHandle: Int64; const BaseUri: string);
    procedure RequireNoSecondaryResults(const Handler: Int64);
    function GetStylesheet(const StylesheetFile: string): Int64;
    procedure ClearCaches;
  public
    constructor Create(const LibraryFile: string);
    destructor Destroy; override;
    procedure Close;
    // Stylesheets und ihre Includes bleiben während der Instanzlebensdauer unverändert.
    procedure BeginDocument(const XmlFile: string);
    procedure BeginDocumentBytes(const XmlBytes: TBytes; const BaseUri: string);
    procedure RegisterMemoryStylesheet(const ResourceUri: string; const Content: TBytes);
    procedure EndDocument;
    property StylesheetCompilationCount: Integer read FStylesheetCompilationCount;
    property XPathProcessorCount: Integer read FXPathProcessorCount;
    property SourceParseCount: Integer read FSourceParseCount;
    function Version: string;
    procedure Configure(const Name, Value: string);
    function EvaluateBoolean(const XmlFile, Expression: string; const Namespaces: array of string): Boolean;
    procedure Transform(const XmlFile, StylesheetFile, OutputFile: string; const InputDocumentFile: string = '');
    function EvaluateBooleanBytes(const XmlBytes: TBytes; const BaseUri, Expression: string; const Namespaces: array of string): Boolean;
    function TransformBytes(const XmlBytes: TBytes; const BaseUri, StylesheetFile, OutputBaseUri: string;
      const InputDocumentBytes: TBytes = nil; const InputDocumentBaseUri: string = ''): TBytes;
  end;

implementation

const
  UnitName = 'MGKositNative';

// Die Allokationslänge erhält eingebettete Nullbytes etwa bei UTF-16-Ausgabe.
// Native char* enthält zusätzlich genau ein abschließendes Nullbyte.
function AllocateNativeResult(Size: NativeUInt): Pointer; cdecl;
var
  Header: PNativeUInt;
begin
  Result := nil;
  if Size > High(NativeUInt) - SizeOf(NativeUInt) then
    Exit;
  Header := HeapAlloc(GetProcessHeap, 0, Size + SizeOf(NativeUInt));
  if Header <> nil then
  begin
    Header^ := Size;
    Result := Pointer(NativeUInt(Header) + SizeOf(NativeUInt));
  end;
end;

// Saxon benötigt für relative result-document-Ziele die URI des tatsächlichen Ausgabeortes.
function OutputFileUri(const FileName: string): string;
var
  PathText: string;
  PathBytes: TBytes;
  PathByte: Byte;
begin
  PathText := StringReplace(FileName, '\', '/', [rfReplaceAll]);
  if Copy(PathText, 1, 2) = '//' then
    Result := 'file:'
  else
    Result := 'file:///';
  // Prozentkodierung erfolgt auf UTF-8-Bytes, niemals auf der Windows-ANSI-Codepage.
  PathBytes := TEncoding.UTF8.GetBytes(PathText);
  for PathByte in PathBytes do
    if CharInSet(Char(PathByte), ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/', ':']) then
      Result := Result + Char(PathByte)
    else
      Result := Result + '%' + IntToHex(PathByte, 2);
end;

// Dateiaufrufer dürfen native Windows-Pfade liefern; logische URIs bleiben unverändert.
function NormalizeDocumentUri(const Value: string): string;
begin
  if ((Length(Value) >= 3) and (Value[2] = ':') and CharInSet(Value[3], ['\', '/'])) or (Copy(Value, 1, 2) = '\\') then
    Result := OutputFileUri(Value)
  else
    Result := Value;
end;

// Der Saxon-C-Einstiegspunkt benötigt für dateibezogene XPath-Ausdrücke ein vorhandenes Arbeitsverzeichnis.
procedure RequireXPathDirectory(const DirectoryName: string);
begin
  if not DirectoryExists(DirectoryName) then
    raise EMGKositNative.Create('Das XPath-Quellverzeichnis ist nicht vorhanden oder nicht zugänglich: ' + DirectoryName);
end;

// Der C-Einstiegspunkt setzt den statischen XPath-Kontext aus seinem Verzeichnisargument.
// Wie bei der Dateischnittstelle gilt für Dateiquellen das Quellverzeichnis, während XDM den ganzen URI behält.
function XPathDirectory(const BaseUri: string): string;
var
  NormalizedUri, DirectoryUri, PathText: string;
begin
  if TPath.IsPathRooted(BaseUri) then
  begin
    Result := ExtractFileDir(ExpandFileName(BaseUri));
    RequireXPathDirectory(Result);
    Exit;
  end;
  NormalizedUri := NormalizeDocumentUri(BaseUri);
  if SameText(Copy(NormalizedUri, 1, 5), 'file:') then
  begin
    DirectoryUri := Copy(NormalizedUri, 1, LastDelimiter('/', NormalizedUri));
    if SameText(Copy(DirectoryUri, 1, 8), 'file:///') then
      PathText := Copy(DirectoryUri, 9, MaxInt)
    else if SameText(Copy(DirectoryUri, 1, 7), 'file://') then
      PathText := '\\' + Copy(DirectoryUri, 8, MaxInt)
    else if SameText(Copy(DirectoryUri, 1, 6), 'file:/') then
      PathText := Copy(DirectoryUri, 7, MaxInt)
    else
      raise EMGKositNative.Create('Der Datei-Basis-URI benötigt einen absoluten Pfad: ' + BaseUri);
    // Ein Pluszeichen ist im URI-Pfad wörtlich; Formularkodierung darf daraus kein Leerzeichen machen.
    PathText := TNetEncoding.URL.Decode(StringReplace(PathText, '+', '%2B', [rfReplaceAll]));
    Result := StringReplace(PathText, '/', '\', [rfReplaceAll]);
    if not ((Length(Result) = 3) and (Result[2] = ':')) then
      Result := ExcludeTrailingPathDelimiter(Result);
    RequireXPathDirectory(Result);
  end
  else
    Result := GetCurrentDir;
end;

// Fehlende Exports sind ein ABI-Fehler und dürfen keinen Ersatzpfad auslösen.
function TMGKositNative.RequireExport(const Name: AnsiString): Pointer;
begin
  Result := GetProcAddress(FLibrary, PAnsiChar(Name));
  if Result = nil then
    raise EMGKositNative.Create('SaxonC-Export fehlt: ' + string(Name));
end;

// Ein Isolate und seine Handles gehören ausschließlich dem erzeugenden Thread.
procedure TMGKositNative.RequireOwnerThread;
begin
  if GetCurrentThreadId <> FOwnerThread then
    raise EMGKositNative.Create('SaxonC-Isolate wird aus einem anderen Thread verwendet');
  if FThread = nil then
    raise EMGKositNative.Create('SaxonC-Isolate ist geschlossen');
end;

// Negative Native-Rückgaben bleiben von einem fachlichen XPath-False unterscheidbar.
procedure TMGKositNative.RaiseNativeError(const Operation: string);
var
  ErrorBuffer: PAnsiChar;
  MessageText: string;
begin
  // Wie c_getErrorMessage im SDK: zuerst kopieren, dann die Native-Exception löschen.
  ErrorBuffer := FErrorMessage(FThread);
  try
    if ErrorBuffer <> nil then
      MessageText := string(UTF8String(ErrorBuffer))
    else
      MessageText := 'Native Fehlerdiagnose fehlt';
  finally
    FClearException(FThread);
  end;
  raise EMGKositNative.Create(Operation + ': ' + MessageText);
end;

// ObjectHandles gehören dem Isolate; Delphi gibt nur die Handle-Referenz zurück.
procedure TMGKositNative.ReleaseHandle(var Handle: Int64);
begin
  if Handle > 0 then
    FDestroyHandle(FThread, Pointer(NativeInt(Handle)));
  Handle := 0;
end;

// Jede fehlgeschlagene Native-Operation erhält ihre eigene Diagnose.
procedure TMGKositNative.CheckException(const Operation: string);
begin
  if FCheckException(FThread) <> 0 then
    RaiseNativeError(Operation);
end;

// Absolute DLL-Auswahl vermeidet Änderungen am systemweiten PATH und an Installationen.
constructor TMGKositNative.Create(const LibraryFile: string);
var
  LibraryPath: string;
begin
  inherited Create;
  // Erst ein erfolgreich gesetztes restriktives Profil darf die zusätzliche Ausgabekontrolle abschalten.
  FCaptureSecondaryResults := True;
  FStylesheets := TDictionary<string, Int64>.Create;
  FXPaths := TDictionary<string, Int64>.Create;
  FXPathBaseUris := TDictionary<Int64, string>.Create;
  FMemoryStylesheets := TDictionary<string, TBytes>.Create;
  FOwnerThread := GetCurrentThreadId;
{$IFNDEF WIN64}
  raise EMGKositNative.Create('SaxonC-HE 12.10 benötigt die Win64-Ausgabe; eine passende Win32-Engine ist nicht installiert.');
{$ENDIF}
  if not TPath.IsPathRooted(LibraryFile) then
    raise EMGKositNative.Create('Der SaxonC-DLL-Pfad muss absolut angegeben werden.');
  LibraryPath := ExpandFileName(LibraryFile);
  if not FileExists(LibraryPath) then
    raise EMGKositNative.Create('SaxonC-DLL fehlt: ' + LibraryPath);
  FLibrary := LoadLibraryEx(PChar(LibraryPath), 0, LOAD_WITH_ALTERED_SEARCH_PATH);
  if FLibrary = 0 then
    RaiseLastOSError;
  FCreateIsolate := TCreateIsolate(RequireExport('graal_create_isolate'));
  FTearDown := TTearDown(RequireExport('graal_tear_down_isolate'));
  FCreateProcessor := TCreateProcessor(RequireExport('createSaxonProcessor'));
  FCreateXPath := TCreateXPath(RequireExport('createXPathProcessorWithProcessor'));
  FCreateData := TCreateData(RequireExport('createProcessorDataWithCapacity'));
  FCreateResultHandler := TCreateData(RequireExport('createSaxonCResultDocumentHandler'));
  FGetResultDocuments := TGetResultDocuments(RequireExport('j_getResultDocuments'));
  FAddProperty := TAddProperty(RequireExport('addProcessorPropertyPair'));
  FAddParameter := TAddParameter(RequireExport('addProcessorDataPair'));
  FDestroyHandle := TDestroyHandle(RequireExport('j_handles_destroy'));
  FParseFile := TParseFile(RequireExport('parseXmlFile'));
  FParseString := TParseString(RequireExport('j_main_parseXmlString'));
  FCompileNode := TCompileNode(RequireExport('j_compileFromXdmNode'));
  FCreateBuilder := TCreateXPath(RequireExport('createDocumentBuilder'));
  FSetBaseUri := TSetBaseUri(RequireExport('j_db_setBaseURI'));
  FSetXPathBaseUri := TSetBaseUri(RequireExport('j_xp_setBaseURI'));
  FDeclareNamespace := TDeclareNamespace(RequireExport('j_xp_declareNamespace'));
  FBooleanValue := TBooleanValue(RequireExport('j_effectiveBooleanValue'));
  FCreateXslt := TCreateXPath(RequireExport('createXslt30WithProcessor'));
  FCompileStylesheet := TCompileStylesheet(RequireExport('j_compileFromFile'));
  FTransformBytes := TTransformBytes(RequireExport('j_transformToString'));
  FProductVersion := TProductVersion(RequireExport('j_c_getProductVersion'));
  FErrorMessage := TErrorMessage(RequireExport('j_getErrorMessageInJavaMem'));
  FClearException := TClearException(RequireExport('j_clearException'));
  FConfiguration := TConfiguration(RequireExport('j_applyPropertyToConfiguration'));
  FCheckException := TCheckException(RequireExport('j_checkForException'));
  if FCreateIsolate(nil, FIsolate, FThread) <> 0 then
    raise EMGKositNative.Create('GraalVM-Isolate kann nicht angelegt werden');
  FProcessor := FCreateProcessor(FThread, 0);
  if FProcessor <= 0 then
    RaiseNativeError('Prozessor anlegen');
  if not TRegEx.IsMatch(Version, '(^|[^0-9])12[.]10([.]1)?([^0-9.]|$)') then
    raise EMGKositNative.Create('Die SaxonC-Core-Bindung benötigt Saxon-HE 12.10; geladen wurde ' + Version + '.');
  Configure('http://saxon.sf.net/feature/allowedProtocols', 'file');
  Configure('http://saxon.sf.net/feature/allow-external-functions', 'false');
  Configure('http://saxon.sf.net/feature/xinclude-aware', 'false');
  Configure('http://saxon.sf.net/feature/parserFeature?uri=http%3A%2F%2Fapache.org%2Fxml%2Ffeatures%2Fdisallow-doctype-decl', 'true');
  Configure('http://saxon.sf.net/feature/parserFeature?uri=http%3A%2F%2Fxml.org%2Fsax%2Ffeatures%2Fexternal-general-entities', 'false');
  Configure('http://saxon.sf.net/feature/parserFeature?uri=http%3A%2F%2Fxml.org%2Fsax%2Ffeatures%2Fexternal-parameter-entities', 'false');
end;

// Isolate-Lebensdauer und Handles werden unabhängig vom Erfolg der Prüfung beendet.
destructor TMGKositNative.Destroy;
begin
  try
    if FThread <> nil then
      Close;
  finally
    // Eine fehlgeschlagene Isolate-Freigabe darf keinen noch laufenden Native-Code entladen.
    if (FThread = nil) and (FLibrary <> 0) then
      FreeLibrary(FLibrary);
    FreeAndNil(FStylesheets);
    FreeAndNil(FXPaths);
    FreeAndNil(FXPathBaseUris);
    FreeAndNil(FMemoryStylesheets);
    inherited Destroy;
  end;
end;

// Ein explizites Close meldet einen fehlgeschlagenen Abbau, bevor die DLL entladen wird.
procedure TMGKositNative.Close;
var
  Status: Integer;
begin
  if FThread = nil then
    Exit;
  RequireOwnerThread;
  EndDocument;
  ClearCaches;
  ReleaseHandle(FXsltProcessor);
  ReleaseHandle(FProcessor);
  Status := FTearDown(FThread);
  if Status <> 0 then
    raise EMGKositNative.CreateFmt('GraalVM-Isolate kann nicht beendet werden: %d', [Status]);
  FThread := nil;
  FIsolate := nil;
end;

// Der SDK-Wrapper verwendet denselben nicht besitzenden Versionszeiger.
function TMGKositNative.Version: string;
var
  VersionBuffer: PAnsiChar;
begin
  RequireOwnerThread;
  VersionBuffer := FProductVersion(FThread, Pointer(NativeInt(FProcessor)));
  if VersionBuffer = nil then
    RaiseNativeError('Version ermitteln');
  Result := string(UTF8String(VersionBuffer));
  CheckException('Version ermitteln');
end;

// Native Konfigurationsfehler bleiben sichtbar, statt Optionen still zu ignorieren.
procedure TMGKositNative.Configure(const Name, Value: string);
var
  NameUtf8, ValueUtf8: UTF8String;
begin
  RequireOwnerThread;
  if FDocument > 0 then
    raise EMGKositNative.Create('Die Konfiguration darf während einer Dokumentverarbeitung nicht geändert werden');
  NameUtf8 := UTF8String(Name);
  ValueUtf8 := UTF8String(Value);
  FClearException(FThread);
  if FConfiguration(FThread, Pointer(NativeInt(FProcessor)), PAnsiChar(NameUtf8), PAnsiChar(ValueUtf8)) = -2 then
    RaiseNativeError('Konfiguration ' + Name);
  CheckException('Konfiguration ' + Name);
  if Name = 'http://saxon.sf.net/feature/allow-external-functions' then
    FCaptureSecondaryResults := not SameText(Value, 'false');
  // Kompilierte Kontexte müssen die aktuellen Sicherheits- und Prozessoroptionen verwenden.
  ClearCaches;
end;

// Die C-API erwartet nullterminierte Zeichen, deshalb werden XML-Kodierungen vorab nach UTF-8 überführt.
function XmlBytesToUtf8(const Content: TBytes): UTF8String;
var
  Encoding: TEncoding;
  Offset, HeaderLength: Integer;
  Header, XmlText: string;
  Declaration: TMatch;
begin
  Encoding := nil;
  Offset := 0;
  if (Length(Content) >= 3) and (Content[0] = $EF) and (Content[1] = $BB) and (Content[2] = $BF) then
  begin
    Encoding := TEncoding.UTF8;
    Offset := 3;
  end
  else if (Length(Content) >= 2) and (Content[0] = $FF) and (Content[1] = $FE) then
  begin
    Encoding := TEncoding.Unicode;
    Offset := 2;
  end
  else if (Length(Content) >= 2) and (Content[0] = $FE) and (Content[1] = $FF) then
  begin
    Encoding := TEncoding.BigEndianUnicode;
    Offset := 2;
  end;
  if Encoding = nil then
  begin
    if (Length(Content) >= 4) and (Content[0] = 0) and (Content[1] = Ord('<')) and (Content[2] = 0) then
      Encoding := TEncoding.BigEndianUnicode
    else if (Length(Content) >= 4) and (Content[0] = Ord('<')) and (Content[1] = 0) and (Content[3] = 0) then
      Encoding := TEncoding.Unicode;
  end;
  if Encoding <> nil then
    XmlText := Encoding.GetString(Content, Offset, Length(Content) - Offset)
  else
  begin
    HeaderLength := 0;
    if (Length(Content) >= 5) and (Content[0] = Ord('<')) and (Content[1] = Ord('?')) and
       (Content[2] = Ord('x')) and (Content[3] = Ord('m')) and (Content[4] = Ord('l')) then
    begin
      HeaderLength := 5;
      while HeaderLength < Length(Content) do
      begin
        Inc(HeaderLength);
        if (Content[HeaderLength - 2] = Ord('?')) and (Content[HeaderLength - 1] = Ord('>')) then
          Break;
      end;
    end;
    Header := TEncoding.ANSI.GetString(Content, 0, HeaderLength);
    Declaration := TRegEx.Match(Header, '^<\?xml\s[^?]*encoding\s*=\s*["'']([^"'']+)["'']');
    if Declaration.Success then
      Encoding := TEncoding.GetEncoding(Declaration.Groups[1].Value)
    else
      Encoding := TEncoding.GetEncoding(65001);
    try
      XmlText := Encoding.GetString(Content);
    finally
      FreeAndNil(Encoding);
    end;
  end;
  if Pos(#0, XmlText) > 0 then
    raise EMGKositNative.Create('XML enthält ein unzulässiges Nullzeichen');
  Result := UTF8String(XmlText);
end;

// Der DocumentBuilder erhält den logischen Original-URI ohne eine Datei als Transportmedium.
function TMGKositNative.ParseDocumentBytes(const XmlBytes: TBytes; const BaseUri: string; const CountAsSource: Boolean): Int64;
var
  Builder: Int64;
  SourceUtf8, BaseUtf8: UTF8String;
begin
  SourceUtf8 := XmlBytesToUtf8(XmlBytes);
  BaseUtf8 := UTF8String(NormalizeDocumentUri(BaseUri));
  Builder := FCreateBuilder(FThread, Pointer(NativeInt(FProcessor)));
  if Builder <= 0 then
    RaiseNativeError('Dokumentparser anlegen');
  try
    if FSetBaseUri(FThread, Pointer(NativeInt(Builder)), PAnsiChar(BaseUtf8)) = -2 then
      RaiseNativeError('Dokument-Basis-URI setzen');
    CheckException('Dokument-Basis-URI setzen');
    Result := FParseString(FThread, nil, Pointer(NativeInt(FProcessor)), Pointer(NativeInt(Builder)), nil, PAnsiChar(SourceUtf8), 'UTF-8');
    if Result <= 0 then
      RaiseNativeError('Speicherdokument einlesen');
    try
      CheckException('Speicherdokument einlesen');
      if CountAsSource then
        Inc(FSourceParseCount);
    except
      ReleaseHandle(Result);
      raise;
    end;
  finally
    ReleaseHandle(Builder);
  end;
end;

// Nur ein Bytekontext mit gleichem URI und Inhalt darf wiederverwendet werden, niemals ein Dateikontext.
function TMGKositNative.AcquireDocumentBytes(const XmlBytes: TBytes; const BaseUri: string; out Owned: Boolean): Int64;
begin
  Owned := not ((FDocument > 0) and FDocumentIsBytes and (FDocumentBaseUri = BaseUri) and (Length(XmlBytes) = Length(FDocumentBytes)));
  if not Owned and (Length(XmlBytes) > 0) then
    Owned := not CompareMem(@XmlBytes[0], @FDocumentBytes[0], Length(XmlBytes));
  if Owned then
    Result := ParseDocumentBytes(XmlBytes, BaseUri)
  else
    Result := FDocument;
end;

// Die Kopie schützt den aktiven Parserkontext vor nachträglicher Änderung des Aufruferpuffers.
procedure TMGKositNative.BeginDocumentBytes(const XmlBytes: TBytes; const BaseUri: string);
begin
  RequireOwnerThread;
  if FDocument > 0 then
    raise EMGKositNative.Create('Ein Quelldokument ist bereits aktiv');
  FClearException(FThread);
  FDocument := ParseDocumentBytes(XmlBytes, BaseUri);
  FDocumentBytes := Copy(XmlBytes);
  FDocumentBaseUri := BaseUri;
  FDocumentIsBytes := True;
end;

// Registrierungen sind ausdrücklich benannte Ressourcen, kein Ersatzpfad für fehlende Dateien.
procedure TMGKositNative.RegisterMemoryStylesheet(const ResourceUri: string; const Content: TBytes);
begin
  RequireOwnerThread;
  if FDocument > 0 then
    raise EMGKositNative.Create('Ressourcen dürfen während einer Dokumentverarbeitung nicht geändert werden');
  FMemoryStylesheets.AddOrSetValue(ResourceUri, Copy(Content));
  ClearCaches;
end;

// Jeder Parseraufruf besitzt einen eigenen Handle; Fehler erzeugen keinen Cacheeintrag.
function TMGKositNative.ParseDocument(const XmlFile: string): Int64;
var
  DirectoryUtf8, FileUtf8: UTF8String;
begin
  DirectoryUtf8 := UTF8String(ExtractFileDir(ExpandFileName(XmlFile)));
  FileUtf8 := UTF8String(ExpandFileName(XmlFile));
  Result := FParseFile(FThread, Pointer(NativeInt(FProcessor)), PAnsiChar(DirectoryUtf8), PAnsiChar(FileUtf8));
  if Result <= 0 then
    RaiseNativeError('Quelldokument einlesen');
  try
    CheckException('Quelldokument einlesen');
    Inc(FSourceParseCount);
  except
    ReleaseHandle(Result);
    raise;
  end;
end;

// Nur das ausdrücklich aktive Eingabedokument wird aufrufübergreifend wiederverwendet.
function TMGKositNative.AcquireDocument(const XmlFile: string; out Owned: Boolean): Int64;
begin
  Owned := not ((FDocument > 0) and not FDocumentIsBytes and SameText(ExpandFileName(XmlFile), FDocumentFile));
  if Owned then
    Result := ParseDocument(XmlFile)
  else
    Result := FDocument;
end;

// Eine verschachtelte Validierung darf den noch verwendeten Dokumenthandle nicht ersetzen.
procedure TMGKositNative.BeginDocument(const XmlFile: string);
begin
  RequireOwnerThread;
  if FDocument > 0 then
    raise EMGKositNative.Create('Ein Quelldokument ist bereits aktiv');
  FClearException(FThread);
  FDocument := ParseDocument(XmlFile);
  FDocumentFile := ExpandFileName(XmlFile);
  FDocumentIsBytes := False;
end;

// Nach Validierungsende darf derselbe Dateiname neue Inhalte enthalten.
procedure TMGKositNative.EndDocument;
begin
  RequireOwnerThread;
  ReleaseHandle(FDocument);
  FDocumentFile := '';
  FDocumentBytes := nil;
  FDocumentBaseUri := '';
  FDocumentIsBytes := False;
end;

// Abhängige Handles werden vor ihrem Saxon-Prozessor und dem Isolate freigegeben.
procedure TMGKositNative.ClearCaches;
var
  Handle: Int64;
begin
  if FStylesheets <> nil then
  begin
    for Handle in FStylesheets.Values do
      FDestroyHandle(FThread, Pointer(NativeInt(Handle)));
    FStylesheets.Clear;
  end;
  if FXPaths <> nil then
  begin
    for Handle in FXPaths.Values do
      FDestroyHandle(FThread, Pointer(NativeInt(Handle)));
    FXPaths.Clear;
  end;
  if FXPathBaseUris <> nil then
    FXPathBaseUris.Clear;
end;

// Laut SDK invalidiert eine Änderung des statischen Kontexts den kompilierten XPath-Cache.
// Gleiche Basis-URIs vermeiden diese Invalidierung; pro Namespace-Satz bleibt genau ein Prozessor erhalten.
procedure TMGKositNative.SetXPathBaseUri(const XPathHandle: Int64; const BaseUri: string);
var
  CurrentUri, NormalizedUri: string;
  UriUtf8: UTF8String;
begin
  NormalizedUri := NormalizeDocumentUri(BaseUri);
  if FXPathBaseUris.TryGetValue(XPathHandle, CurrentUri) and (CurrentUri = NormalizedUri) then
    Exit;
  UriUtf8 := UTF8String(NormalizedUri);
  if FSetXPathBaseUri(FThread, Pointer(NativeInt(XPathHandle)), PAnsiChar(UriUtf8)) = -2 then
    RaiseNativeError('XPath-Basis-URI setzen');
  CheckException('XPath-Basis-URI setzen');
  FXPathBaseUris.AddOrSetValue(XPathHandle, NormalizedUri);
end;

// Präfixe werden an der Original-XPath-Engine registriert; der Ausdruck bleibt unverändert.
// Eine erneute Namespace-Deklaration würde den Saxon-Ausdruckscache leeren.
function TMGKositNative.GetXPath(const Namespaces: array of string; const BaseUri: string): Int64;
var
  CacheKey, NamespacePart: string;
  PrefixIndex: Integer;
  PrefixUtf8, UriUtf8: UTF8String;
begin
  if Odd(Length(Namespaces)) then
    raise EMGKositNative.Create('Namespace-Liste muss aus Präfix/URI-Paaren bestehen');
  CacheKey := '';
  for NamespacePart in Namespaces do
    CacheKey := CacheKey + IntToStr(Length(NamespacePart)) + ':' + NamespacePart;
  if FXPaths.TryGetValue(CacheKey, Result) then
  begin
    SetXPathBaseUri(Result, BaseUri);
    Exit;
  end;
  Result := FCreateXPath(FThread, Pointer(NativeInt(FProcessor)));
  if Result <= 0 then
    RaiseNativeError('XPath-Prozessor anlegen');
  try
    SetXPathBaseUri(Result, BaseUri);
    PrefixIndex := 0;
    while PrefixIndex < Length(Namespaces) do
    begin
      PrefixUtf8 := UTF8String(Namespaces[PrefixIndex]);
      UriUtf8 := UTF8String(Namespaces[PrefixIndex + 1]);
      if FDeclareNamespace(FThread, Pointer(NativeInt(Result)), PAnsiChar(PrefixUtf8), PAnsiChar(UriUtf8)) = -2 then
        RaiseNativeError('XPath-Namespace registrieren');
      CheckException('XPath-Namespace registrieren');
      Inc(PrefixIndex, 2);
    end;
    FXPaths.Add(CacheKey, Result);
    Inc(FXPathProcessorCount);
  except
    FXPathBaseUris.Remove(Result);
    ReleaseHandle(Result);
    raise;
  end;
end;

// Der Cache gehört zur Instanz und setzt unveränderte vertrauenswürdige Stylesheets voraus.
function TMGKositNative.GetStylesheet(const StylesheetFile: string): Int64;
var
  CacheKey: string;
  DirectoryUtf8, FileUtf8: UTF8String;
  Content: TBytes;
  StylesheetNode: Int64;
  IsMemoryResource: Boolean;
begin
  IsMemoryResource := FMemoryStylesheets.TryGetValue(StylesheetFile, Content);
  if IsMemoryResource then
    CacheKey := StylesheetFile
  else
    CacheKey := ExpandFileName(StylesheetFile);
  if FStylesheets.TryGetValue(CacheKey, Result) then
    Exit;
  if FXsltProcessor = 0 then
  begin
    FXsltProcessor := FCreateXslt(FThread, Pointer(NativeInt(FProcessor)));
    if FXsltProcessor <= 0 then
    begin
      FXsltProcessor := 0;
      RaiseNativeError('XSLT-Prozessor anlegen');
    end;
  end;
  DirectoryUtf8 := UTF8String(ExtractFileDir(CacheKey));
  FileUtf8 := UTF8String(CacheKey);
  if IsMemoryResource then
  begin
    StylesheetNode := ParseDocumentBytes(Content, StylesheetFile, False);
    try
      Result := FCompileNode(FThread, Pointer(NativeInt(FXsltProcessor)), nil, Pointer(NativeInt(StylesheetNode)), 0, nil);
    finally
      ReleaseHandle(StylesheetNode);
    end;
  end
  else
    Result := FCompileStylesheet(FThread, Pointer(NativeInt(FXsltProcessor)), PAnsiChar(DirectoryUtf8), PAnsiChar(FileUtf8), 0, nil);
  if Result <= 0 then
    RaiseNativeError('Stylesheet kompilieren');
  try
    CheckException('Stylesheet kompilieren');
    FStylesheets.Add(CacheKey, Result);
    Inc(FStylesheetCompilationCount);
  except
    ReleaseHandle(Result);
    raise;
  end;
end;

// Kontextdaten bleiben aufruflokal, während der statische XPath-Kontext erhalten bleibt.
function TMGKositNative.EvaluateBoolean(const XmlFile, Expression: string; const Namespaces: array of string): Boolean;
var
  XPathHandle, DataHandle, DocumentHandle: Int64;
  NativeResult: Integer;
  DocumentOwned: Boolean;
  DirectoryUtf8, ExpressionUtf8: UTF8String;
begin
  RequireOwnerThread;
  DirectoryUtf8 := UTF8String(ExtractFileDir(ExpandFileName(XmlFile)));
  ExpressionUtf8 := UTF8String(Expression);
  FClearException(FThread);
  XPathHandle := GetXPath(Namespaces, XPathDirectory(XmlFile));
  DocumentHandle := AcquireDocument(XmlFile, DocumentOwned);
  try
    DataHandle := FCreateData(FThread, 2);
    if DataHandle <= 0 then
      RaiseNativeError('XPath-Kontext anlegen');
    try
      FAddParameter(FThread, Pointer(NativeInt(DataHandle)), 'node', Pointer(NativeInt(DocumentHandle)));
      FAddProperty(FThread, Pointer(NativeInt(DataHandle)), 'caching:', 'true');
      CheckException('XPath-Kontext setzen');
      NativeResult := FBooleanValue(FThread, Pointer(NativeInt(XPathHandle)), PAnsiChar(DirectoryUtf8), PAnsiChar(ExpressionUtf8), 'UTF-8', Pointer(NativeInt(DataHandle)));
      if NativeResult = -2 then
        RaiseNativeError('XPath auswerten');
      CheckException('XPath auswerten');
      if (NativeResult <> 0) and (NativeResult <> 1) then
        raise EMGKositNative.CreateFmt('XPath lieferte einen unbekannten Status: %d', [NativeResult]);
      Result := NativeResult <> 0;
    finally
      ReleaseHandle(DataHandle);
    end;
  finally
    if DocumentOwned then
      ReleaseHandle(DocumentHandle);
  end;
end;

// Der Dokumentparameter ist ein XDM-Dokument, kein Dateiname und kein XML-String.
// Saxon serialisiert in eigenen Bytes; Delphi besitzt Zielpuffer und Dateilebensdauer.
// So hält ein XSLT-Abbruch keine native Dateiressource am Hauptausgabeziel offen.
procedure TMGKositNative.Transform(const XmlFile, StylesheetFile, OutputFile: string; const InputDocumentFile: string);
var
  DataHandle, DocumentHandle, SourceHandle, ExecutableHandle: Int64;
  ResultBuffer: PAnsiChar;
  ResultHeader: PNativeUInt;
  ResultBytes: TBytes;
  SourceOwned, DocumentOwned: Boolean;
  DirectoryUtf8, OutputUtf8: UTF8String;
begin
  RequireOwnerThread;
  DirectoryUtf8 := UTF8String(ExtractFileDir(ExpandFileName(StylesheetFile)));
  OutputUtf8 := UTF8String(OutputFileUri(ExpandFileName(OutputFile)));
  DocumentHandle := 0;
  DocumentOwned := False;
  SourceHandle := 0;
  SourceOwned := False;
  FClearException(FThread);
  ExecutableHandle := GetStylesheet(StylesheetFile);
  DataHandle := FCreateData(FThread, 2);
  if DataHandle <= 0 then
    RaiseNativeError('Transformationsparameter anlegen');
  try
    SourceHandle := AcquireDocument(XmlFile, SourceOwned);
    FAddParameter(FThread, Pointer(NativeInt(DataHandle)), 'node', Pointer(NativeInt(SourceHandle)));
    FAddProperty(FThread, Pointer(NativeInt(DataHandle)), 'baseoutput', PAnsiChar(OutputUtf8));
    CheckException('Transformationsquelle setzen');
    if InputDocumentFile <> '' then
    begin
      DocumentHandle := AcquireDocument(InputDocumentFile, DocumentOwned);
      FAddParameter(FThread, Pointer(NativeInt(DataHandle)), 'param:input-document', Pointer(NativeInt(DocumentHandle)));
      CheckException('Dokumentparameter setzen');
    end;
    ResultBuffer := FTransformBytes(FThread, @AllocateNativeResult, PAnsiChar(DirectoryUtf8), nil, Pointer(NativeInt(ExecutableHandle)), nil,
      nil, Pointer(NativeInt(DataHandle)));
    if ResultBuffer = nil then
      RaiseNativeError('XSLT ausführen');
    ResultHeader := PNativeUInt(NativeUInt(ResultBuffer) - SizeOf(NativeUInt));
    try
      CheckException('XSLT ausführen');
      if (ResultHeader^ = 0) or (PByte(NativeUInt(ResultBuffer) + ResultHeader^ - 1)^ <> 0) then
        raise EMGKositNative.Create('SaxonC lieferte keinen nullterminierten Ergebnispuffer');
      SetLength(ResultBytes, ResultHeader^ - 1);
      if Length(ResultBytes) > 0 then
        Move(ResultBuffer^, ResultBytes[0], Length(ResultBytes));
      TFile.WriteAllBytes(OutputFile, ResultBytes);
    finally
      if not HeapFree(GetProcessHeap, 0, ResultHeader) then
        RaiseLastOSError;
    end;
  finally
    ReleaseHandle(DataHandle);
    if DocumentOwned then
      ReleaseHandle(DocumentHandle);
    if SourceOwned then
      ReleaseHandle(SourceHandle);
  end;
end;


// Kontextdaten bleiben aufruflokal, während der statische XPath-Kontext erhalten bleibt.
function TMGKositNative.EvaluateBooleanBytes(const XmlBytes: TBytes; const BaseUri, Expression: string; const Namespaces: array of string): Boolean;
var
  XPathHandle, DataHandle, DocumentHandle: Int64;
  NativeResult: Integer;
  DocumentOwned: Boolean;
  DirectoryUtf8, ExpressionUtf8: UTF8String;
begin
  RequireOwnerThread;
  DirectoryUtf8 := UTF8String(XPathDirectory(BaseUri));
  ExpressionUtf8 := UTF8String(Expression);
  FClearException(FThread);
  DocumentHandle := AcquireDocumentBytes(XmlBytes, BaseUri, DocumentOwned);
  try
    XPathHandle := GetXPath(Namespaces, string(DirectoryUtf8));
    DataHandle := FCreateData(FThread, 2);
    if DataHandle <= 0 then
      RaiseNativeError('XPath-Kontext anlegen');
    try
      FAddParameter(FThread, Pointer(NativeInt(DataHandle)), 'node', Pointer(NativeInt(DocumentHandle)));
      FAddProperty(FThread, Pointer(NativeInt(DataHandle)), 'caching:', 'true');
      CheckException('XPath-Kontext setzen');
      NativeResult := FBooleanValue(FThread, Pointer(NativeInt(XPathHandle)), PAnsiChar(DirectoryUtf8), PAnsiChar(ExpressionUtf8), 'UTF-8', Pointer(NativeInt(DataHandle)));
      if NativeResult = -2 then
        RaiseNativeError('XPath auswerten');
      CheckException('XPath auswerten');
      if (NativeResult <> 0) and (NativeResult <> 1) then
        raise EMGKositNative.CreateFmt('XPath lieferte einen unbekannten Status: %d', [NativeResult]);
      Result := NativeResult <> 0;
    finally
      ReleaseHandle(DataHandle);
    end;
  finally
    if DocumentOwned then
      ReleaseHandle(DocumentHandle);
  end;
end;

// Die Byte-API liefert nur das Hauptresultat; sekundäre Dokumente dürfen weder verschwinden noch Dateien erzeugen.
procedure TMGKositNative.RequireNoSecondaryResults(const Handler: Int64);
var
  Buffer: Pointer;
  Header: PNativeUInt;
  Count, DocumentIndex, DocumentHandle: Int64;
begin
  Buffer := FGetResultDocuments(FThread, @AllocateNativeResult, Pointer(NativeInt(Handler)));
  if Buffer = nil then
  begin
    CheckException('Sekundäre Transformationsdokumente prüfen');
    Exit;
  end;
  Header := PNativeUInt(NativeUInt(Buffer) - SizeOf(NativeUInt));
  try
    CheckException('Sekundäre Transformationsdokumente prüfen');
    if Header^ < SizeOf(Int64) then
      raise EMGKositNative.Create('SaxonC lieferte einen ungültigen ResultDocument-Puffer');
    Count := PInt64(Buffer)^;
    if (Count < 0) or (UInt64(Count) > (Header^ div SizeOf(Int64)) - 1) then
      raise EMGKositNative.Create('SaxonC lieferte eine ungültige ResultDocument-Anzahl');
    for DocumentIndex := 1 to Count do
    begin
      DocumentHandle := PInt64(NativeUInt(Buffer) + NativeUInt(DocumentIndex) * SizeOf(Int64))^;
      ReleaseHandle(DocumentHandle);
    end;
    if Count > 0 then
      raise EMGKositNative.Create('Die Speicher-API unterstützt keine sekundären xsl:result-document-Ausgaben; es wurden keine Dateien geschrieben');
  finally
    if not HeapFree(GetProcessHeap, 0, Header) then
      RaiseLastOSError;
  end;
end;

// Quelle und Dokumentparameter sind XDM-Dokumente; das Hauptresultat bleibt ein Delphi-Bytepuffer.
// Der aufruflokale SDK-Handler verhindert auch vor einem XSLT-Abbruch externe sekundäre Schreibziele.
function TMGKositNative.TransformBytes(const XmlBytes: TBytes; const BaseUri, StylesheetFile, OutputBaseUri: string;
  const InputDocumentBytes: TBytes; const InputDocumentBaseUri: string): TBytes;
var
  DataHandle, DocumentHandle, SourceHandle, ExecutableHandle, ResultHandler: Int64;
  ResultBuffer: PAnsiChar;
  ResultHeader: PNativeUInt;
  SourceOwned, DocumentOwned: Boolean;
  DirectoryUtf8, OutputUtf8: UTF8String;
begin
  RequireOwnerThread;
  DirectoryUtf8 := UTF8String(GetCurrentDir);
  OutputUtf8 := UTF8String(NormalizeDocumentUri(OutputBaseUri));
  DocumentHandle := 0;
  DocumentOwned := False;
  SourceHandle := 0;
  SourceOwned := False;
  ResultHandler := 0;
  FClearException(FThread);
  ExecutableHandle := GetStylesheet(StylesheetFile);
  DataHandle := FCreateData(FThread, 2);
  if DataHandle <= 0 then
    RaiseNativeError('Transformationsparameter anlegen');
  try
    // Im restriktiven Profil verbietet Saxon result-document bereits beim Kompilieren.
    if FCaptureSecondaryResults then
    begin
      ResultHandler := FCreateResultHandler(FThread, 0);
      if ResultHandler <= 0 then
        RaiseNativeError('ResultDocument-Handler anlegen');
      FAddParameter(FThread, Pointer(NativeInt(DataHandle)), 'rd', Pointer(NativeInt(ResultHandler)));
      CheckException('ResultDocument-Handler setzen');
    end;
    SourceHandle := AcquireDocumentBytes(XmlBytes, BaseUri, SourceOwned);
    FAddParameter(FThread, Pointer(NativeInt(DataHandle)), 'node', Pointer(NativeInt(SourceHandle)));
    FAddProperty(FThread, Pointer(NativeInt(DataHandle)), 'baseoutput', PAnsiChar(OutputUtf8));
    CheckException('Transformationsquelle setzen');
    if Length(InputDocumentBytes) > 0 then
    begin
      DocumentHandle := AcquireDocumentBytes(InputDocumentBytes, InputDocumentBaseUri, DocumentOwned);
      FAddParameter(FThread, Pointer(NativeInt(DataHandle)), 'param:input-document', Pointer(NativeInt(DocumentHandle)));
      CheckException('Dokumentparameter setzen');
    end;
    ResultBuffer := FTransformBytes(FThread, @AllocateNativeResult, PAnsiChar(DirectoryUtf8), nil, Pointer(NativeInt(ExecutableHandle)), nil,
      nil, Pointer(NativeInt(DataHandle)));
    if ResultBuffer = nil then
      RaiseNativeError('XSLT ausführen');
    ResultHeader := PNativeUInt(NativeUInt(ResultBuffer) - SizeOf(NativeUInt));
    try
      CheckException('XSLT ausführen');
      if ResultHandler > 0 then
        RequireNoSecondaryResults(ResultHandler);
      if (ResultHeader^ = 0) or (PByte(NativeUInt(ResultBuffer) + ResultHeader^ - 1)^ <> 0) then
        raise EMGKositNative.Create('SaxonC lieferte keinen nullterminierten Ergebnispuffer');
      SetLength(Result, ResultHeader^ - 1);
      if Length(Result) > 0 then
        Move(ResultBuffer^, Result[0], Length(Result));
    finally
      if not HeapFree(GetProcessHeap, 0, ResultHeader) then
        RaiseLastOSError;
    end;
  finally
    ReleaseHandle(DataHandle);
    ReleaseHandle(ResultHandler);
    if DocumentOwned then
      ReleaseHandle(DocumentHandle);
    if SourceOwned then
      ReleaseHandle(SourceHandle);
  end;
end;

end.
