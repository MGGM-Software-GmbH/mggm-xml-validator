unit uKositCli;

interface

function RunValidatorCli: Integer;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Generics.Collections, Winapi.Windows, Winapi.ActiveX,
  Winapi.MSXML, MGKositTypes, MGKositValidator, MGKositEngine;

type
  EKositArguments = class(Exception);

  TScenarioArgument = record
    Name, FileName: string;
  end;

  TKositCli = class
  private
    FScenarios: TList<TScenarioArgument>;
    FRepositories: TDictionary<string, string>;
    FInputs: TList<string>;
    FOutputDirectory, FLibraryFile, FPrefix, FPostfix, FAssertionsFile: string;
    FHtml, FSerializeInput, FPrint, FJson, FHelp, FDebug: Boolean;
    FAssertionCount, FAssertionFailures: Integer;
    function NextValue(var Index: Integer; const Option: string): string;
    procedure Parse;
    procedure AddInput(const FileName: string);
    function ReportName(const FileName: string): string;
    procedure CheckOutputNames;
    function LoadAssertions(const Engine: TMGKositEngine): IXMLDOMDocument3;
    function CheckAssertions(const Engine: TMGKositEngine; const Document: IXMLDOMDocument3; const ReportFile, InputName: string): Integer;
    function ResultJson(const Validation: TMGKositValidationResult; const FileName, ReportFile: string): TJSONObject;
  public
    constructor Create;
    destructor Destroy; override;
    function Run: Integer;
  end;

// Ungültige Optionen sind ein Aufruffehler, auch wenn weitere Argumente gültig wären.
function TKositCli.NextValue(var Index: Integer; const Option: string): string;
begin
  Inc(Index);
  if Index > ParamCount then
    raise EKositArguments.Create('Wert fehlt für ' + Option);
  Result := ParamStr(Index);
  if Result = '' then
    raise EKositArguments.Create('Leerer Wert für ' + Option);
  if Result.StartsWith('-') then
    raise EKositArguments.Create('Wert fehlt für ' + Option + ': ' + Result);
end;

// Benannte Szenarien und Repositories werden wie beim bisherigen Tool zugeordnet.
procedure TKositCli.Parse;
var
  Index, Separator, RepositoryIndex, ScenarioIndex: Integer;
  Argument, Value, Name, LogLevel: string;
  Scenario: TScenarioArgument;
  Positional, SharedRepository: Boolean;
begin
  Index := 1;
  RepositoryIndex := 0;
  Positional := False;
  while Index <= ParamCount do
  begin
    Argument := ParamStr(Index);
    if Positional then
      AddInput(Argument)
    else if Argument = '--' then
      Positional := True
    else if (Argument = '-?') or (Argument = '--help') then
      FHelp := True
    else if (Argument = '-s') or (Argument = '--scenarios') then
    begin
      Value := NextValue(Index, Argument);
      Separator := Pos('=', Value);
      if Separator > 0 then
      begin
        Scenario.Name := Copy(Value, 1, Separator - 1);
        Scenario.FileName := Copy(Value, Separator + 1, MaxInt);
      end
      else
      begin
        Scenario.Name := '#' + IntToStr(FScenarios.Count + 1);
        Scenario.FileName := Value;
      end;
      if (Scenario.Name = '') or (Scenario.FileName = '') then
        raise EKositArguments.Create('Ungültige Szenarioangabe: ' + Value);
      for ScenarioIndex := 0 to FScenarios.Count - 1 do
        if FScenarios[ScenarioIndex].Name = Scenario.Name then
          raise EKositArguments.Create('Doppelter Szenarioname: ' + Scenario.Name);
      FScenarios.Add(Scenario);
    end
    else if (Argument = '-r') or (Argument = '--repository') then
    begin
      Value := NextValue(Index, Argument);
      Separator := Pos('=', Value);
      if Separator > 0 then
      begin
        Name := Copy(Value, 1, Separator - 1);
        Value := Copy(Value, Separator + 1, MaxInt);
      end
      else
      begin
        Inc(RepositoryIndex);
        Name := '#' + IntToStr(RepositoryIndex);
      end;
      if (Name = '') or not DirectoryExists(Value) or FRepositories.ContainsKey(Name) then
        raise EKositArguments.Create('Ungültiges oder doppeltes Repository: ' + Name + ' (' + Value + ')');
      FRepositories.Add(Name, ExpandFileName(Value));
    end
    else if (Argument = '-o') or (Argument = '--output-directory') then
      FOutputDirectory := ExpandFileName(NextValue(Index, Argument))
    else if Argument = '--saxon-library' then
      FLibraryFile := ExpandFileName(NextValue(Index, Argument))
    else if (Argument = '-h') or (Argument = '--html') or (Argument = '--extract-html') then
      FHtml := True
    else if Argument = '--serialize-report-input' then
      FSerializeInput := True
    else if Argument = '--report-prefix' then
      FPrefix := NextValue(Index, Argument)
    else if Argument = '--report-postfix' then
      FPostfix := NextValue(Index, Argument)
    else if (Argument = '-p') or (Argument = '--print') then
      FPrint := True
    else if Argument = '--json' then
      FJson := True
    else if (Argument = '-c') or (Argument = '--check-assertions') then
      FAssertionsFile := ExpandFileName(NextValue(Index, Argument))
    else if (Argument = '-X') or (Argument = '--debug-logging') or (Argument = '-d') or (Argument = '--debug') then
      FDebug := True
    else if (Argument = '-l') or (Argument = '--log-level') then
    begin
      LogLevel := UpperCase(NextValue(Index, Argument));
      if (LogLevel <> 'OFF') and (LogLevel <> 'ERROR') and (LogLevel <> 'WARN') and (LogLevel <> 'INFO') and (LogLevel <> 'DEBUG') and (LogLevel <> 'TRACE') then
        raise EKositArguments.Create('Unbekannte Protokollstufe: ' + LogLevel);
      FDebug := LogLevel <> 'OFF';
    end
    else if (Argument = '-') or not Argument.StartsWith('-') then
      AddInput(Argument)
    else
      raise EKositArguments.Create('Unbekannte oder nicht unterstützte Option: ' + Argument);
    Inc(Index);
  end;
  if FJson and FPrint then
    raise EKositArguments.Create('--json und --print können nicht gemeinsam verwendet werden');
  if not FHelp and ((FScenarios.Count = 0) or (FInputs.Count = 0)) then
    raise EKositArguments.Create('Mindestens eine Szenariodatei (-s) und eine Eingabe sind erforderlich');
  // Ein einzelnes unbenanntes -r weist allen Definitionen ausdrücklich dasselbe Ressourcenverzeichnis zu.
  SharedRepository := (FRepositories.Count = 1) and FRepositories.ContainsKey('#1');
  for Scenario in FScenarios do
    if (FRepositories.Count > 0) and not SharedRepository and not FRepositories.ContainsKey(Scenario.Name) then
      raise EKositArguments.Create('Repository für Szenariodefinition fehlt: ' + Scenario.Name);
  for Name in FRepositories.Keys do
  begin
    Positional := False;
    for Scenario in FScenarios do
      if Name = Scenario.Name then
        Positional := True;
    if not Positional and not SharedRepository then
      WriteLn(ErrOutput, 'Warnung: Repositorydefinition wird nicht verwendet: ' + Name);
  end;
end;

// Verzeichnisse enthalten ausschließlich ihre unmittelbaren XML-Dateien.
procedure TKositCli.AddInput(const FileName: string);
var
  Child: string;
begin
  if DirectoryExists(FileName) then
  begin
    for Child in TDirectory.GetFiles(FileName) do
      if SameText(TPath.GetExtension(Child), '.xml') then
        FInputs.Add(ExpandFileName(Child));
  end
  else if FileName = '-' then
  begin
    if FInputs.Contains('-') then
      raise EKositArguments.Create('stdin darf nur einmal angegeben werden');
    FInputs.Add(FileName);
  end
  else
  begin
    if not FileExists(FileName) then
      raise EKositArguments.Create('Eingabedatei fehlt: ' + FileName);
    FInputs.Add(ExpandFileName(FileName));
  end;
end;

// Die XML-Berichtsnamen entsprechen der Prefix-/Postfix-Strategie des Originals.
function TKositCli.ReportName(const FileName: string): string;
var
  BaseName: string;
begin
  BaseName := ExtractFileName(FileName);
  if FileName = '-' then
    BaseName := 'stdin.xml';
  if SameText(TPath.GetExtension(BaseName), '.xml') then
    BaseName := ChangeFileExt(BaseName, '');
  Result := BaseName;
  if FPrefix <> '' then
    Result := FPrefix + '-' + Result;
  if FPostfix <> '' then
    Result := Result + '-' + FPostfix
  else if FPrefix = '' then
    Result := Result + '-report';
  Result := Result + '.xml';
end;

// Kein Bericht darf einen vorhandenen Bericht oder eine andere Batch-Eingabe überschreiben.
procedure TKositCli.CheckOutputNames;
var
  Names: TStringList;
  Input, OutputName, BaseName: string;
  NameCharacter: Char;

  procedure Reserve(const FileName: string);
  begin
    if FileExists(FileName) or DirectoryExists(FileName) or (Names.IndexOf(FileName) >= 0) then
      raise EKositArguments.Create('Ausgabedatei existiert bereits oder ist doppelt: ' + FileName);
    Names.Add(FileName);
  end;

begin
  if (Pos('\', FPrefix + FPostfix) > 0) or (Pos('/', FPrefix + FPostfix) > 0) or (Pos(':', FPrefix + FPostfix) > 0) then
    raise EKositArguments.Create('Report-Präfix und -Postfix dürfen keine Pfade enthalten');
  for NameCharacter in FPrefix + FPostfix do
    if CharInSet(NameCharacter, [#0..#31, '<', '>', '"', '|', '?', '*']) then
      raise EKositArguments.Create('Report-Präfix oder -Postfix enthält ein ungültiges Dateinamenzeichen');
  Names := TStringList.Create;
  try
    Names.CaseSensitive := False;
    for Input in FInputs do
    begin
      OutputName := TPath.Combine(FOutputDirectory, ReportName(Input));
      Reserve(OutputName);
      BaseName := ChangeFileExt(ExtractFileName(Input), '');
      if Input = '-' then
        BaseName := 'stdin';
      if FHtml then
        Reserve(TPath.Combine(FOutputDirectory, BaseName + '-report.html'));
      if FSerializeInput then
        Reserve(TPath.Combine(FOutputDirectory, BaseName + '-reportInput.xml'));
    end;
  finally
    FreeAndNil(Names);
  end;
end;

// Die Struktur entspricht assertions.xsd des KoSIT-Modells; Annotationen beeinflussen die Prüfung nicht.
// Das eingebettete Schema benötigt beim ausgelieferten CLI keinen Quellcodepfad.
function TKositCli.LoadAssertions(const Engine: TMGKositEngine): IXMLDOMDocument3;
const
  AssertionsNamespace = 'http://www.xoev.de/de/validator/framework/1/assertions';
  AssertionsSchema =
    '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:a="http://www.xoev.de/de/validator/framework/1/assertions" ' +
    'targetNamespace="http://www.xoev.de/de/validator/framework/1/assertions" elementFormDefault="qualified" attributeFormDefault="unqualified">' +
    '<xs:element name="assertions"><xs:complexType><xs:sequence>' +
    '<xs:element name="namespace" type="a:NamespaceType" minOccurs="0" maxOccurs="unbounded"/>' +
    '<xs:element name="assertion" type="a:AssertionType" minOccurs="0" maxOccurs="unbounded"/>' +
    '</xs:sequence></xs:complexType></xs:element>' +
    '<xs:complexType name="NamespaceType"><xs:simpleContent><xs:extension base="xs:anyURI">' +
    '<xs:attribute name="prefix" use="required"/></xs:extension></xs:simpleContent></xs:complexType>' +
    '<xs:complexType name="AssertionType"><xs:simpleContent><xs:extension base="xs:token">' +
    '<xs:attribute name="report-doc" type="xs:anyURI" use="required"/><xs:attribute name="test" type="xs:string" use="required"/>' +
    '</xs:extension></xs:simpleContent></xs:complexType></xs:schema>';
var
  SchemaDocument: IXMLDOMDocument3;
  SchemaCache: IXMLDOMSchemaCollection2;
  ParseError: IXMLDOMParseError;
  SchemaVariant: OleVariant;
begin
  try
    Result := Engine.LoadDocument(FAssertionsFile);
    SchemaDocument := Engine.NewDocument(AssertionsSchema);
    SchemaCache := CoXMLSchemaCache60.Create;
    SchemaCache.validateOnLoad := True;
    SchemaVariant := IDispatch(SchemaDocument);
    SchemaCache.add(AssertionsNamespace, SchemaVariant);
    SchemaVariant := IDispatch(SchemaCache);
    Result.schemas := SchemaVariant;
    ParseError := Result.validate;
    if ParseError.errorCode <> 0 then
      raise EKositArguments.Create('Ungültige Assertions-Datei: ' + string(ParseError.reason));
  except
    on Error: Exception do
      raise EKositArguments.Create('Assertions-Datei kann nicht verwendet werden: ' + Error.Message);
  end;
end;

// Assertions verwenden die gleiche XPath-Engine wie die Szenarioauswahl.
function TKositCli.CheckAssertions(const Engine: TMGKositEngine; const Document: IXMLDOMDocument3; const ReportFile, InputName: string): Integer;
var
  Nodes: IXMLDOMNodeList;
  Node: IXMLDOMNode;
  Namespaces: TArray<string>;
  Index, NamespaceCount, PreviousAssertionCount: Integer;
  ReportDocument, Test: string;
begin
  Result := 0;
  PreviousAssertionCount := FAssertionCount;
  if (Document.documentElement.namespaceURI <> 'http://www.xoev.de/de/validator/framework/1/assertions') or
     (Document.documentElement.baseName <> 'assertions') then
    raise EKositArguments.Create('Die Assertions-Datei besitzt kein gültiges assertions-Wurzelelement');
  Document.setProperty('SelectionNamespaces', 'xmlns:a="http://www.xoev.de/de/validator/framework/1/assertions"');
  Nodes := Document.selectNodes('/a:assertions/a:namespace');
  SetLength(Namespaces, Nodes.length * 2);
  NamespaceCount := 0;
  for Index := 0 to Nodes.length - 1 do
  begin
    Node := Nodes.item[Index];
    if Node.attributes.getNamedItem('prefix') = nil then
      raise EKositArguments.Create('Namespace-Angabe benötigt prefix');
    Namespaces[NamespaceCount] := Node.attributes.getNamedItem('prefix').text;
    Namespaces[NamespaceCount + 1] := Node.text;
    Inc(NamespaceCount, 2);
  end;
  Nodes := Document.selectNodes('/a:assertions/a:assertion');
  for Index := 0 to Nodes.length - 1 do
  begin
    Node := Nodes.item[Index];
    if (Node.attributes.getNamedItem('report-doc') = nil) or (Node.attributes.getNamedItem('test') = nil) then
      raise EKositArguments.Create('Assertions benötigen report-doc und test');
    ReportDocument := Node.attributes.getNamedItem('report-doc').text;
    if ReportDocument.StartsWith(InputName) or (InputName + '.xml').EndsWith(ReportDocument) then
    begin
      Test := Node.attributes.getNamedItem('test').text;
      Inc(FAssertionCount);
      if not Engine.EvaluateBoolean(ReportFile, Test, Namespaces) then
      begin
        Inc(Result);
        Inc(FAssertionFailures);
        WriteLn(ErrOutput, 'Assertion fehlgeschlagen: ', Test);
      end;
    end;
  end;
  // Ohne Zuordnung wurde keine Assertion ausgeführt; dies darf nicht still als Prüfung erscheinen.
  if FAssertionCount = PreviousAssertionCount then
    WriteLn(ErrOutput, 'Keine Assertions für Bericht: ' + ReportFile);
end;

// Akzeptanz und technische Fehler bleiben im maschinenlesbaren Ergebnis unabhängig.
function TKositCli.ResultJson(const Validation: TMGKositValidationResult; const FileName, ReportFile: string): TJSONObject;
var
  Findings: TJSONArray;
  FindingJson: TJSONObject;
  Finding: TMGKositFinding;
  Acceptance: string;
begin
  case Validation.Acceptance of
    kaAccept: Acceptance := 'ACCEPTABLE';
    kaReject: Acceptance := 'REJECT';
  else
    Acceptance := 'UNDEFINED';
  end;
  Result := TJSONObject.Create;
  Result.AddPair('input', FileName);
  Result.AddPair('scenario', Validation.ScenarioName);
  Result.AddPair('status', string(KositStatus(Validation)));
  Result.AddPair('acceptance', Acceptance);
  Result.AddPair('schema_valid', TJSONBool.Create(Validation.SchemaValid));
  Result.AddPair('processing_error', TJSONBool.Create(Validation.ProcessingError));
  Result.AddPair('error', Validation.ErrorMessage);
  Result.AddPair('report', ReportFile);
  Findings := TJSONArray.Create;
  Result.AddPair('findings', Findings);
  for Finding in Validation.Findings do
  begin
    FindingJson := TJSONObject.Create;
    FindingJson.AddPair('level', Finding.Level);
    FindingJson.AddPair('code', Finding.Code);
    FindingJson.AddPair('text', Finding.Text);
    FindingJson.AddPair('location', Finding.Location);
    FindingJson.AddPair('validation_step', Finding.ValidationStep);
    Findings.AddElement(FindingJson);
  end;
end;

// Die Bibliothek braucht weder CLI-Optionen noch einen externen Java-Prozess.
constructor TKositCli.Create;
begin
  inherited;
  FScenarios := TList<TScenarioArgument>.Create;
  FRepositories := TDictionary<string, string>.Create;
  FInputs := TList<string>.Create;
  FOutputDirectory := GetCurrentDir;
  FLibraryFile := TPath.Combine(ExtractFilePath(ExpandFileName(ParamStr(0))), 'saxonc-core-he.dll');
end;

// Bei einem Parserfehler werden auch bereits eingelesene Argumente freigegeben.
destructor TKositCli.Destroy;
begin
  FreeAndNil(FInputs);
  FreeAndNil(FRepositories);
  FreeAndNil(FScenarios);
  inherited;
end;

// Jede Eingabe liefert dasselbe Ergebnisobjekt wie der Stream-Adapter.
function TKositCli.Run: Integer;
var
  Validator: TMGKositValidator;
  AssertionEngine: TMGKositEngine;
  Scenario: TScenarioArgument;
  Validation: TMGKositValidationResult;
  Input, Repository, ReportFile, BaseName: string;
  JsonResults: TJSONArray;
  Stdin: TMemoryStream;
  AssertionsDocument: IXMLDOMDocument3;
  InputHandle: THandle;
  Buffer: array[0..65535] of Byte;
  BytesRead, ReadError: DWORD;
begin
  Result := 0;
  Parse;
  if FHelp then
  begin
    WriteLn('MGGM XML Validator für Delphi (Win64, SaxonC-HE 12.10.1 und MSXML 6)');
    WriteLn('MGGMXmlValidator -s [name=]scenarios.xml [-r [name=]repository] -o verzeichnis [--html] datei.xml ...');
    WriteLn('  --saxon-library DLL       Absoluter Pfad zur SaxonC-Core-DLL');
    WriteLn('  --json                   Strukturierte Ergebnisse auf stdout');
    WriteLn('  -p, --print              XML-Berichte auf stdout');
    WriteLn('  --serialize-report-input Berichtseingabe zusätzlich schreiben');
    WriteLn('  --report-prefix TEXT     XML-Berichtspräfix');
    WriteLn('  --report-postfix TEXT    XML-Berichtspostfix');
    WriteLn('  -c, --check-assertions XML  XPath-Assertions prüfen');
    WriteLn('  -X, -d, -l LEVEL         Diagnoseausgabe aktivieren');
    WriteLn('  -? oder --help           Hilfe; -h bedeutet wie beim Original HTML');
    WriteLn('  -                        XML von stdin lesen');
    Exit;
  end;
  CheckOutputNames;
  if not DirectoryExists(FOutputDirectory) and not ForceDirectories(FOutputDirectory) then
    raise EKositArguments.Create('Ausgabeverzeichnis kann nicht angelegt werden: ' + FOutputDirectory);
  JsonResults := TJSONArray.Create;
  try
    Validator := TMGKositValidator.Create(FLibraryFile);
    try
      for Scenario in FScenarios do
      begin
        if not FRepositories.TryGetValue(Scenario.Name, Repository) then
        begin
          if (FRepositories.Count = 1) and FRepositories.ContainsKey('#1') then
            Repository := FRepositories['#1']
          else
            Repository := '';
        end;
        Validator.AddScenario(Scenario.FileName, Repository);
      end;
      if FDebug then
        WriteLn(ErrOutput, 'Geladene Szenarien: ', Validator.ScenarioCount);
      AssertionEngine := nil;
      AssertionsDocument := nil;
      try
        if FAssertionsFile <> '' then
        begin
          AssertionEngine := TMGKositEngine.Create(FLibraryFile);
          AssertionsDocument := LoadAssertions(AssertionEngine);
        end;
        for Input in FInputs do
        begin
          BaseName := ChangeFileExt(ExtractFileName(Input), '');
          if Input = '-' then
          begin
            BaseName := 'stdin';
            Stdin := TMemoryStream.Create;
            try
              // Pipes besitzen weder Größe noch Seek; gelesen wird bis zum tatsächlichen EOF.
              InputHandle := GetStdHandle(STD_INPUT_HANDLE);
              if (InputHandle = 0) or (InputHandle = INVALID_HANDLE_VALUE) then
                raise EKositArguments.Create('stdin besitzt kein gültiges Handle');
              while True do
              begin
                if not ReadFile(InputHandle, Buffer[0], SizeOf(Buffer), BytesRead, nil) then
                begin
                  ReadError := GetLastError;
                  if ReadError = ERROR_BROKEN_PIPE then
                    Break;
                  RaiseLastOSError(ReadError);
                end;
                if BytesRead = 0 then
                  Break;
                Stdin.WriteBuffer(Buffer[0], BytesRead);
              end;
              Stdin.Position := 0;
              Validation := Validator.ValidateStream(Stdin, 'stdin.xml');
            finally
              FreeAndNil(Stdin);
            end;
          end
          else
            Validation := Validator.ValidateFile(Input);
          ReportFile := TPath.Combine(FOutputDirectory, ReportName(Input));
          if Validation.ReportXml <> '' then
            TFile.WriteAllText(ReportFile, Validation.ReportXml, TEncoding.UTF8);
          if FHtml and (Validation.ReportHtml <> '') then
            TFile.WriteAllText(TPath.Combine(FOutputDirectory, BaseName + '-report.html'), Validation.ReportHtml, TEncoding.UTF8);
          if FSerializeInput and (Validation.ReportInputXml <> '') then
            TFile.WriteAllText(TPath.Combine(FOutputDirectory, BaseName + '-reportInput.xml'), Validation.ReportInputXml, TEncoding.UTF8);
          JsonResults.AddElement(ResultJson(Validation, Input, ReportFile));
          if FPrint then
            WriteLn(Validation.ReportXml)
          else if not FJson then
            WriteLn(KositStatus(Validation), ' ', Input, ' ', Validation.ScenarioName);
          if Validation.ProcessingError then
            WriteLn(ErrOutput, Validation.ErrorMessage);
          if Validation.ProcessingError or (Validation.Acceptance <> kaAccept) then
            Inc(Result);
          if AssertionEngine <> nil then
            CheckAssertions(AssertionEngine, AssertionsDocument, ReportFile, BaseName);
        end;
        if FAssertionCount > 0 then
        begin
          if FAssertionFailures = 0 then
            Result := 0
          else
            Inc(Result, FAssertionFailures);
        end;
        if FJson then
          WriteLn(JsonResults.ToJSON);
      finally
        AssertionsDocument := nil;
        FreeAndNil(AssertionEngine);
      end;
    finally
      FreeAndNil(Validator);
    end;
  finally
    FreeAndNil(JsonResults);
  end;
end;

// Aufruffehler erhalten einen eigenen Exit-Code und täuschen keine Validierung vor.
function RunValidatorCli: Integer;
var
  Cli: TKositCli;
begin
  Cli := TKositCli.Create;
  try
    try
      Result := Cli.Run;
    except
      on Error: EKositArguments do
      begin
        WriteLn(ErrOutput, Error.Message);
        WriteLn(ErrOutput, 'Aufruf: MGGMXmlValidator -s scenarios.xml -o verzeichnis datei.xml');
        Result := 2;
      end;
    end;
  finally
    FreeAndNil(Cli);
  end;
end;

end.
