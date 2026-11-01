program CliTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Hash, System.NetEncoding, System.Win.ComObj,
  Winapi.Windows, Winapi.ActiveX, Winapi.MSXML;

type
  TProcessResult = record
    ExitCode: DWORD;
    OutputText, ErrorText: string;
  end;

// Windows-CRT-Quoting erhält Leerzeichen, Anführungszeichen und abschließende Backslashes.
function QuoteArgument(const Value: string): string;
var
  Character: Char;
  SlashCount: Integer;
begin
  Result := '"';
  SlashCount := 0;
  for Character in Value do
  begin
    if Character = '\' then
      Inc(SlashCount)
    else
    begin
      if Character = '"' then
        Result := Result + StringOfChar('\', SlashCount * 2 + 1) + Character
      else
        Result := Result + StringOfChar('\', SlashCount) + Character;
      SlashCount := 0;
    end;
  end;
  Result := Result + StringOfChar('\', SlashCount * 2) + '"';
end;

// Jeder Kindprozess erhält eigene Ausgabedateien und ausschließlich direkte CLI-Argumente.
function ExecuteCli(const Executable, DirectoryName: string; const Arguments: TArray<string>; const PipeInput: TBytes): TProcessResult;
var
  Security: TSecurityAttributes;
  Startup: TStartupInfo;
  Process: TProcessInformation;
  InputRead, InputWrite, OutputHandle, ErrorHandle: THandle;
  CommandLine, Argument, OutputFile, ErrorFile: string;
  Offset, Written, Remaining, WaitStatus: DWORD;
  ProcessStarted, ProcessFinished: Boolean;
begin
  InputRead := 0;
  InputWrite := 0;
  OutputHandle := INVALID_HANDLE_VALUE;
  ErrorHandle := INVALID_HANDLE_VALUE;
  ProcessStarted := False;
  ProcessFinished := False;
  FillChar(Security, SizeOf(Security), 0);
  Security.nLength := SizeOf(Security);
  Security.bInheritHandle := True;
  FillChar(Process, SizeOf(Process), 0);
  OutputFile := TPath.Combine(DirectoryName, 'stdout.txt');
  ErrorFile := TPath.Combine(DirectoryName, 'stderr.txt');
  try
    if not CreatePipe(InputRead, InputWrite, @Security, 0) then
      RaiseLastOSError;
    if not SetHandleInformation(InputWrite, HANDLE_FLAG_INHERIT, 0) then
      RaiseLastOSError;
    OutputHandle := CreateFile(PChar(OutputFile), GENERIC_WRITE, FILE_SHARE_READ, @Security, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
    if OutputHandle = INVALID_HANDLE_VALUE then
      RaiseLastOSError;
    ErrorHandle := CreateFile(PChar(ErrorFile), GENERIC_WRITE, FILE_SHARE_READ, @Security, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
    if ErrorHandle = INVALID_HANDLE_VALUE then
      RaiseLastOSError;
    FillChar(Startup, SizeOf(Startup), 0);
    Startup.cb := SizeOf(Startup);
    Startup.dwFlags := STARTF_USESTDHANDLES;
    Startup.hStdInput := InputRead;
    Startup.hStdOutput := OutputHandle;
    Startup.hStdError := ErrorHandle;
    CommandLine := QuoteArgument(Executable);
    for Argument in Arguments do
      CommandLine := CommandLine + ' ' + QuoteArgument(Argument);
    UniqueString(CommandLine);
    if not CreateProcess(PChar(Executable), PChar(CommandLine), nil, nil, True, CREATE_NO_WINDOW, nil, PChar(DirectoryName), Startup, Process) then
      RaiseLastOSError;
    ProcessStarted := True;
    CloseHandle(InputRead);
    InputRead := 0;
    Offset := 0;
    while Offset < DWORD(Length(PipeInput)) do
    begin
      Remaining := DWORD(Length(PipeInput)) - Offset;
      if Remaining > 4096 then
        Remaining := 4096;
      if not WriteFile(InputWrite, PipeInput[Offset], Remaining, Written, nil) then
        RaiseLastOSError;
      if Written = 0 then
        raise Exception.Create('stdin-Pipe nimmt keine Bytes an');
      Inc(Offset, Written);
    end;
    CloseHandle(InputWrite);
    InputWrite := 0;
    WaitStatus := WaitForSingleObject(Process.hProcess, 120000);
    if WaitStatus <> WAIT_OBJECT_0 then
      raise Exception.CreateFmt('CLI-Prozess nicht beendet, Wait-Status %d', [WaitStatus]);
    ProcessFinished := True;
    if not GetExitCodeProcess(Process.hProcess, Result.ExitCode) then
      RaiseLastOSError;
  finally
    if InputRead <> 0 then CloseHandle(InputRead);
    if InputWrite <> 0 then CloseHandle(InputWrite);
    if OutputHandle <> INVALID_HANDLE_VALUE then CloseHandle(OutputHandle);
    if ErrorHandle <> INVALID_HANDLE_VALUE then CloseHandle(ErrorHandle);
    if ProcessStarted then
    begin
      if not ProcessFinished then
      begin
        TerminateProcess(Process.hProcess, 253);
        WaitForSingleObject(Process.hProcess, 10000);
      end;
      CloseHandle(Process.hThread);
      CloseHandle(Process.hProcess);
    end;
  end;
  Result.OutputText := TFile.ReadAllText(OutputFile, TEncoding.UTF8);
  Result.ErrorText := TFile.ReadAllText(ErrorFile, TEncoding.UTF8);
end;

// Der öffentliche JSON-Vertrag trennt Annahme, Status, Schema und technische Verarbeitung.
function MatchesPublicResult(const JsonText, Status, Acceptance: string; const SchemaValid: Boolean): Boolean;
var
  Parsed: TJSONValue;
  Items: TJSONArray;
  Item: TJSONObject;
begin
  Result := False;
  Parsed := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Parsed is TJSONArray) then Exit;
    Items := TJSONArray(Parsed);
    if (Items.Count <> 1) or not (Items.Items[0] is TJSONObject) then Exit;
    Item := TJSONObject(Items.Items[0]);
    Result := (Item.GetValue<string>('status') = Status) and (Item.GetValue<string>('acceptance') = Acceptance)
      and (Item.GetValue<Boolean>('schema_valid') = SchemaValid) and not Item.GetValue<Boolean>('processing_error');
  finally
    FreeAndNil(Parsed);
  end;
end;

// Rückgabeartefakte werden über Namespaces und Inhalte statt über eine beliebige Datei geprüft.
function ParseTestXml(const Xml: string): IXMLDOMDocument3;
begin
  Result := CoDOMDocument60.Create;
  Result.async := False;
  Result.resolveExternals := False;
  Result.setProperty('ProhibitDTD', True);
  if not Result.loadXML(Xml) then raise Exception.Create('Ungültiges XML-Testartefakt: ' + Result.parseError.reason);
  Result.setProperty('SelectionLanguage', 'XPath');
  Result.setProperty('SelectionNamespaces', 'xmlns:r="http://www.xoev.de/de/validator/varl/1" ' +
    'xmlns:s="http://www.xoev.de/de/validator/framework/1/scenarios" xmlns:i="http://www.xoev.de/de/validator/framework/1/createreportinput"');
end;

// Der erwartete Hash stammt unmittelbar aus den eingespeisten Bytes.
function InputHash(const Bytes: TBytes): string;
var
  Stream: TBytesStream;
begin
  Stream := TBytesStream.Create(Bytes);
  try
    Result := TNetEncoding.Base64.EncodeBytesToString(THashSHA2.GetHashBytes(Stream));
  finally
    FreeAndNil(Stream);
  end;
end;

// Getrennte Konfigurations- und Ressourcenpfade machen Repositoryzuordnungen beobachtbar.
function WriteContractConfiguration(const DirectoryName, Name, RuleBody: string): string;
var
  Resources: string;
begin
  Resources := TPath.Combine(DirectoryName, 'resources');
  ForceDirectories(Resources);
  TFile.WriteAllText(TPath.Combine(Resources, Name + '.xsd'),
    '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:element name="' + Name + '" type="xs:string"/></xs:schema>', TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(Resources, Name + '.xsl'),
    '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:svrl="http://purl.oclc.org/dsdl/svrl" version="2.0">' +
    '<xsl:template match="/"><svrl:schematron-output>' + RuleBody + '</svrl:schematron-output></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(Resources, 'identity.xsl'),
    '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="2.0">' +
    '<xsl:template match="/"><xsl:copy-of select="."/></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
  Result := TPath.Combine(DirectoryName, Name + '.scenarios.xml');
  TFile.WriteAllText(Result, '<scenarios xmlns="http://www.xoev.de/de/validator/framework/1/scenarios" frameworkVersion="1.1.2">' +
    '<name>CLI contracts</name><date>2026-11-01</date><description><p>Generierte CLI-Vertragsfälle</p></description>' +
    '<scenario><name>' + Name + '</name><match>/' + Name + '</match><validateWithXmlSchema><resource><name>Schema</name>' +
    '<location>' + Name + '.xsd</location></resource></validateWithXmlSchema><validateWithSchematron><resource><name>Rules</name>' +
    '<location>' + Name + '.xsl</location></resource></validateWithSchematron></scenario>' +
    '<noScenarioReport><resource><name>Identity</name><location>identity.xsl</location></resource></noScenarioReport></scenarios>', TEncoding.UTF8);
end;

// Ein neuer Evidence-Ordner verhindert die Wiederverwendung alter Berichte oder Prozessausgaben.
procedure RunTests;
const
  AssertionsStart = '<assertions xmlns="http://www.xoev.de/de/validator/framework/1/assertions">';
var
  Executable, LibraryFile, ValidationRoot, ValidXml, InvalidXml, EvidenceDirectory, ConfigFile, Repository: string;
  CaseDirectory, OutputDirectory, InputFile, AssertionsFile, ExpectedReport, CollisionFile, FirstConfig, SecondConfig, SecondInput: string;
  CaseName, Diagnostic: string;
  Evidence, CaseEvidence: TJSONObject;
  Cases: TJSONArray;
  Arguments, BaseArguments: TArray<string>;
  ProcessResult: TProcessResult;
  Document: IXMLDOMDocument3;
  Node: IXMLDOMNode;
  Json: TJSONValue;
  Items: TJSONArray;
  PipeInput: TBytes;
  CaseIndex, PassedCount, NamingVariant: Integer;
  ExpectedExit: DWORD;
  Passed: Boolean;
begin
  if ParamCount <> 6 then
    raise Exception.Create('Aufruf: CliTests CLIExe DLL ValidationRoot ValidXml InvalidBusinessXml EvidenceDirectory');
  Executable := ExpandFileName(ParamStr(1));
  LibraryFile := ExpandFileName(ParamStr(2));
  ValidationRoot := ExpandFileName(ParamStr(3));
  ValidXml := ExpandFileName(ParamStr(4));
  InvalidXml := ExpandFileName(ParamStr(5));
  EvidenceDirectory := ExpandFileName(ParamStr(6));
  if FileExists(EvidenceDirectory) or DirectoryExists(EvidenceDirectory) then
    raise Exception.Create('Evidence-Verzeichnis muss neu sein: ' + EvidenceDirectory);
  if not FileExists(Executable) or not FileExists(LibraryFile) or not FileExists(ValidXml) or not FileExists(InvalidXml) then
    raise Exception.Create('CLI, DLL oder Eingabedatei fehlt');
  Repository := TPath.Combine(ValidationRoot, 'validator-configuration-xrechnung\3.0.2');
  ConfigFile := TPath.Combine(Repository, 'scenarios.xml');
  if not FileExists(ConfigFile) then
    raise Exception.Create('XRechnung-Konfiguration fehlt: ' + ConfigFile);
  ForceDirectories(EvidenceDirectory);
  Evidence := TJSONObject.Create;
  try
    Cases := TJSONArray.Create;
    Evidence.AddPair('cases', Cases);
    PassedCount := 0;
    for CaseIndex := 0 to 55 do
    begin
      case CaseIndex of
        0: CaseName := 'help';
        1: CaseName := 'unknown-option';
        2: CaseName := 'missing-option-value';
        3: CaseName := 'missing-library';
        4: CaseName := 'missing-configuration';
        5: CaseName := 'output-collision';
        6: CaseName := 'prefix-postfix';
        7: CaseName := 'named-repository';
        8: CaseName := 'assertions-pass';
        9: CaseName := 'assertions-fail';
        10: CaseName := 'assertions-malformed';
        11: CaseName := 'assertions-missing-prefix';
        12: CaseName := 'stdin-pipe';
        13: CaseName := 'invalid-prefix';
        14: CaseName := 'assertions-invalid-xpath';
        15: CaseName := 'default-library-foreign-cwd';
        16: CaseName := 'json-accepted-contract';
        17: CaseName := 'json-rejected-contract';
        18: CaseName := 'duplicate-report-name';
        19: CaseName := 'html-reportinput-collision';
        20: CaseName := 'print-report';
        21: CaseName := 'directory-input-direct-xml-only';
        22: CaseName := 'cli-no-arguments';
        23: CaseName := 'cli-missing-scenario-option';
        24: CaseName := 'cli-invalid-repository';
        25: CaseName := 'cli-missing-input';
        26: CaseName := 'cli-multiple-inputs';
        27: CaseName := 'cli-multiple-named-scenarios';
        28: CaseName := 'cli-multiple-shared-repository';
        29: CaseName := 'cli-multiple-ordered-scenarios';
        30: CaseName := 'cli-unmatched-named-repository';
        31: CaseName := 'cli-unused-repository';
        32: CaseName := 'cli-missing-assertions';
        33: CaseName := 'cli-html-and-report-input';
        34: CaseName := 'cli-xslt-runtime-error';
        35: CaseName := 'cli-no-input';
      else
        CaseName := 'cli-naming-variant-' + IntToStr(CaseIndex - 36);
      end;
      CaseDirectory := TPath.Combine(EvidenceDirectory, CaseName);
      OutputDirectory := TPath.Combine(CaseDirectory, 'Ausgaben mit Leerzeichen');
      ForceDirectories(OutputDirectory);
      InputFile := TPath.Combine(CaseDirectory, 'invoice.xml');
      if CaseIndex in [8, 17] then TFile.Copy(InvalidXml, InputFile) else TFile.Copy(ValidXml, InputFile);
      AssertionsFile := TPath.Combine(CaseDirectory, 'assertions.xml');
      ExpectedReport := TPath.Combine(OutputDirectory, 'invoice-report.xml');
      CollisionFile := ExpectedReport;
      BaseArguments := TArray<string>.Create('--saxon-library', LibraryFile, '-s', ConfigFile, '-o', OutputDirectory);
      Arguments := BaseArguments + TArray<string>.Create(InputFile);
      PipeInput := nil;
      ExpectedExit := 0;
      case CaseIndex of
        0: Arguments := TArray<string>.Create('--help');
        1: begin Arguments := TArray<string>.Create('--nicht-vorhanden'); ExpectedExit := 2; end;
        2: begin Arguments := TArray<string>.Create('-s', '-o'); ExpectedExit := 2; end;
        3: begin
          Arguments := TArray<string>.Create('--saxon-library', TPath.Combine(CaseDirectory, 'missing.dll'), '-s', ConfigFile, '-o', OutputDirectory, InputFile);
          ExpectedExit := 254;
        end;
        4: begin
          Arguments := TArray<string>.Create('--saxon-library', LibraryFile, '-s', TPath.Combine(CaseDirectory, 'missing.xml'), '-o', OutputDirectory, InputFile);
          ExpectedExit := 254;
        end;
        5: begin TFile.WriteAllText(CollisionFile, 'unverändert', TEncoding.UTF8); ExpectedExit := 2; end;
        6: begin
          Arguments := BaseArguments + TArray<string>.Create('--report-prefix', 'Prüfung', '--report-postfix', 'Ende', InputFile);
          ExpectedReport := TPath.Combine(OutputDirectory, 'Prüfung-invoice-Ende.xml');
        end;
        7: Arguments := TArray<string>.Create('--saxon-library', LibraryFile, '-s', 'xrechnung=' + ConfigFile, '-r', 'xrechnung=' + Repository,
          '-o', OutputDirectory, InputFile);
        8, 9, 10, 11, 14: begin
          case CaseIndex of
            8: Diagnostic := AssertionsStart + '<assertion report-doc="invoice-report.xml" test="true()"/></assertions>';
            9: begin
              Diagnostic := AssertionsStart + '<assertion report-doc="invoice-report.xml" test="false()"/></assertions>';
              ExpectedExit := 1;
            end;
            10: begin Diagnostic := '<assertions>'; ExpectedExit := 2; end;
            11: begin Diagnostic := AssertionsStart + '<namespace>urn:test</namespace></assertions>'; ExpectedExit := 2; end;
          else
            Diagnostic := AssertionsStart + '<assertion report-doc="invoice-report.xml" test="//*["/></assertions>';
            ExpectedExit := 254;
          end;
          TFile.WriteAllText(AssertionsFile, Diagnostic, TEncoding.UTF8);
          Arguments := BaseArguments + TArray<string>.Create('-c', AssertionsFile, InputFile);
        end;
        12: begin
          Arguments := BaseArguments + TArray<string>.Create('-');
          PipeInput := TFile.ReadAllBytes(ValidXml);
          ExpectedReport := TPath.Combine(OutputDirectory, 'stdin-report.xml');
        end;
        13: begin
          Arguments := BaseArguments + TArray<string>.Create('--report-prefix', '..\außerhalb', InputFile);
          ExpectedExit := 2;
        end;
        15: Arguments := TArray<string>.Create('-s', ConfigFile, '-o', OutputDirectory, InputFile);
        16, 17: begin
          Arguments := BaseArguments + TArray<string>.Create('--json', InputFile);
          if CaseIndex = 17 then ExpectedExit := 1;
        end;
        18: begin
          ForceDirectories(TPath.Combine(CaseDirectory, 'second'));
          TFile.Copy(ValidXml, TPath.Combine(CaseDirectory, 'second\invoice.xml'));
          Arguments := BaseArguments + TArray<string>.Create(InputFile, TPath.Combine(CaseDirectory, 'second\invoice.xml'));
          ExpectedExit := 2;
        end;
        19: begin
          CollisionFile := TPath.Combine(OutputDirectory, 'invoice-reportInput.xml');
          TFile.WriteAllText(CollisionFile, 'unverändert', TEncoding.UTF8);
          Arguments := BaseArguments + TArray<string>.Create('--html', '--serialize-report-input', InputFile);
          ExpectedExit := 2;
        end;
        20: Arguments := BaseArguments + TArray<string>.Create('--print', InputFile);
        21: begin
          ForceDirectories(TPath.Combine(CaseDirectory, 'inputs\nested'));
          TFile.Copy(ValidXml, TPath.Combine(CaseDirectory, 'inputs\direct.XML'));
          TFile.WriteAllText(TPath.Combine(CaseDirectory, 'inputs\ignored.txt'), '<ungültig', TEncoding.UTF8);
          TFile.WriteAllText(TPath.Combine(CaseDirectory, 'inputs\nested\ignored.xml'), '<ungültig', TEncoding.UTF8);
          Arguments := BaseArguments + TArray<string>.Create('--json', TPath.Combine(CaseDirectory, 'inputs'));
          ExpectedReport := TPath.Combine(OutputDirectory, 'direct-report.xml');
        end;
        22: begin Arguments := nil; ExpectedExit := 2; end;
        23: begin Arguments := TArray<string>.Create(InputFile); ExpectedExit := 2; end;
        24: begin Arguments := BaseArguments + TArray<string>.Create('-r', TPath.Combine(CaseDirectory, 'missing-repository'), InputFile); ExpectedExit := 2; end;
        25: begin Arguments := BaseArguments + TArray<string>.Create(TPath.Combine(CaseDirectory, 'missing-input.xml')); ExpectedExit := 2; end;
        26: begin
          SecondInput := TPath.Combine(CaseDirectory, 'second.xml');
          TFile.Copy(InvalidXml, SecondInput);
          Arguments := BaseArguments + TArray<string>.Create('--json', InputFile, SecondInput);
          ExpectedExit := 1;
        end;
        27..31: begin
          FirstConfig := WriteContractConfiguration(CaseDirectory, 'first', '');
          SecondConfig := WriteContractConfiguration(CaseDirectory, 'second', '');
          InputFile := TPath.Combine(CaseDirectory, 'first.xml');
          SecondInput := TPath.Combine(CaseDirectory, 'second.xml');
          TFile.WriteAllText(InputFile, '<first>valid</first>', TEncoding.UTF8);
          TFile.WriteAllText(SecondInput, '<second>valid</second>', TEncoding.UTF8);
          ExpectedReport := TPath.Combine(OutputDirectory, 'first-report.xml');
          Arguments := TArray<string>.Create('--saxon-library', LibraryFile, '--json', '-o', OutputDirectory);
          if CaseIndex = 29 then
            Arguments := Arguments + TArray<string>.Create('-s', FirstConfig, '-s', SecondConfig, '-r', TPath.Combine(CaseDirectory, 'resources'),
              '-r', TPath.Combine(CaseDirectory, 'resources'))
          else
          begin
            Arguments := Arguments + TArray<string>.Create('-s', 'first=' + FirstConfig);
            if CaseIndex <> 31 then Arguments := Arguments + TArray<string>.Create('-s', 'second=' + SecondConfig);
            if CaseIndex = 28 then Arguments := Arguments + TArray<string>.Create('-r', TPath.Combine(CaseDirectory, 'resources'))
            else
            begin
              Arguments := Arguments + TArray<string>.Create('-r', 'first=' + TPath.Combine(CaseDirectory, 'resources'));
              if CaseIndex = 27 then Arguments := Arguments + TArray<string>.Create('-r', 'second=' + TPath.Combine(CaseDirectory, 'resources'));
              if CaseIndex = 30 then Arguments := Arguments + TArray<string>.Create('-r', 'typo=' + TPath.Combine(CaseDirectory, 'resources'));
              if CaseIndex = 31 then Arguments := Arguments + TArray<string>.Create('-r', 'unused=' + TPath.Combine(CaseDirectory, 'resources'));
            end;
          end;
          Arguments := Arguments + TArray<string>.Create(InputFile);
          if CaseIndex <> 31 then Arguments := Arguments + TArray<string>.Create(SecondInput);
          if CaseIndex = 30 then ExpectedExit := 2;
        end;
        32: begin
          TFile.WriteAllText(AssertionsFile, AssertionsStart + '<assertion report-doc="different-report.xml" test="false()"/></assertions>', TEncoding.UTF8);
          Arguments := BaseArguments + TArray<string>.Create('-c', AssertionsFile, InputFile);
        end;
        33: Arguments := BaseArguments + TArray<string>.Create('--html', '--serialize-report-input', InputFile);
        34: begin
          FirstConfig := WriteContractConfiguration(CaseDirectory, 'first', '<xsl:sequence select="error(QName(''urn:cli'', ''BROKEN''), ''runtime-contract'')"/>');
          InputFile := TPath.Combine(CaseDirectory, 'first.xml');
          TFile.WriteAllText(InputFile, '<first>valid</first>', TEncoding.UTF8);
          Arguments := TArray<string>.Create('--saxon-library', LibraryFile, '-s', FirstConfig, '-r', TPath.Combine(CaseDirectory, 'resources'),
            '--serialize-report-input', '--html', '--json', '-o', OutputDirectory, InputFile);
          ExpectedExit := 1;
        end;
        35: begin Arguments := BaseArguments; ExpectedExit := 2; end;
        36..55: begin
          NamingVariant := (CaseIndex - 36) mod 4;
          case (CaseIndex - 36) div 4 of
            0: Diagnostic := 'test';
            1: Diagnostic := 'test.xml';
            2: Diagnostic := 'test.second.xml';
            3: Diagnostic := 'test.ext';
          else
            Diagnostic := 'some.name.with.dots.xml';
          end;
          InputFile := TPath.Combine(CaseDirectory, Diagnostic);
          TFile.Copy(ValidXml, InputFile);
          if SameText(ExtractFileExt(Diagnostic), '.xml') then Diagnostic := ChangeFileExt(Diagnostic, '');
          Arguments := BaseArguments;
          case NamingVariant of
            0: Diagnostic := Diagnostic + '-report';
            1: begin Arguments := Arguments + TArray<string>.Create('--report-prefix', 'prefix'); Diagnostic := 'prefix-' + Diagnostic; end;
            2: begin Arguments := Arguments + TArray<string>.Create('--report-prefix', 'prefix', '--report-postfix', 'postfix'); Diagnostic := 'prefix-' + Diagnostic + '-postfix'; end;
            3: begin Arguments := Arguments + TArray<string>.Create('--report-postfix', 'postfix'); Diagnostic := Diagnostic + '-postfix'; end;
          end;
          ExpectedReport := TPath.Combine(OutputDirectory, Diagnostic + '.xml');
          Arguments := Arguments + TArray<string>.Create(InputFile);
        end;
      end;
      CaseEvidence := TJSONObject.Create;
      Cases.AddElement(CaseEvidence);
      CaseEvidence.AddPair('name', CaseName);
      CaseEvidence.AddPair('expected_exit_code', TJSONNumber.Create(Int64(ExpectedExit)));
      Diagnostic := '';
      Passed := False;
      try
        ProcessResult := ExecuteCli(Executable, CaseDirectory, Arguments, PipeInput);
        CaseEvidence.AddPair('exit_code', TJSONNumber.Create(Int64(ProcessResult.ExitCode)));
        Diagnostic := ProcessResult.ErrorText;
        Passed := ProcessResult.ExitCode = ExpectedExit;
        if CaseIndex in [6, 7, 8, 12, 15, 16, 17, 20, 21] then Passed := Passed and FileExists(ExpectedReport);
        if CaseIndex = 0 then Passed := Passed and ProcessResult.OutputText.Contains('MGGM XML Validator für Delphi') and ProcessResult.OutputText.Contains('MGGMXmlValidator -s');
        if CaseIndex = 5 then Passed := Passed and (TFile.ReadAllText(CollisionFile, TEncoding.UTF8) = 'unverändert');
        if CaseIndex = 4 then Passed := Passed and Diagnostic.Contains('missing.xml');
        if CaseIndex = 12 then
        begin
          Document := ParseTestXml(TFile.ReadAllText(ExpectedReport, TEncoding.UTF8));
          Node := Document.selectSingleNode('/r:report/r:documentIdentification/r:documentHash/r:hashValue');
          Passed := Passed and (Document.selectSingleNode('/r:report/r:assessment/r:accept') <> nil)
            and (Node <> nil) and (Node.text = InputHash(PipeInput));
        end;
        if CaseIndex = 16 then Passed := Passed and MatchesPublicResult(ProcessResult.OutputText, 'V', 'ACCEPTABLE', True);
        if CaseIndex = 17 then Passed := Passed and MatchesPublicResult(ProcessResult.OutputText, 'E', 'REJECT', True);
        if CaseIndex = 18 then Passed := Passed and Diagnostic.Contains('doppelt') and not FileExists(ExpectedReport);
        if CaseIndex = 19 then Passed := Passed and Diagnostic.Contains('existiert')
          and (TFile.ReadAllText(CollisionFile, TEncoding.UTF8) = 'unverändert') and not FileExists(ExpectedReport)
          and not FileExists(TPath.Combine(OutputDirectory, 'invoice-report.html'));
        if CaseIndex = 20 then Passed := Passed and ProcessResult.OutputText.Contains('http://www.xoev.de/de/validator/varl/1')
          and ProcessResult.OutputText.Contains('<rep:accept') and not ProcessResult.OutputText.Contains('V ' + InputFile);
        if CaseIndex = 21 then Passed := Passed and MatchesPublicResult(ProcessResult.OutputText, 'V', 'ACCEPTABLE', True)
          and not FileExists(TPath.Combine(OutputDirectory, 'ignored-report.xml'));
        if CaseIndex in [22, 35] then Passed := Passed and Diagnostic.Contains('Szenariodatei') and Diagnostic.Contains('Aufruf: MGGMXmlValidator')
          and (Length(TDirectory.GetFiles(OutputDirectory)) = 0);
        if CaseIndex = 23 then Passed := Passed and Diagnostic.Contains('Szenariodatei (-s)');
        if CaseIndex = 24 then Passed := Passed and Diagnostic.Contains('Repository') and Diagnostic.Contains('missing-repository');
        if CaseIndex = 25 then Passed := Passed and Diagnostic.Contains('Eingabedatei fehlt') and Diagnostic.Contains('missing-input.xml');
        if CaseIndex in [26, 27, 28, 29] then
        begin
          Json := TJSONObject.ParseJSONValue(ProcessResult.OutputText);
          try
            Passed := Passed and (Json is TJSONArray);
            if Json is TJSONArray then
            begin
              Items := TJSONArray(Json);
              Passed := Passed and (Items.Count = 2);
              if Items.Count = 2 then
              begin
                Passed := Passed and (Items.Items[0].GetValue<string>('status') = 'V')
                  and (Items.Items[0].GetValue<string>('acceptance') = 'ACCEPTABLE');
                if CaseIndex = 26 then
                  Passed := Passed and (Items.Items[1].GetValue<string>('status') = 'E')
                    and (Items.Items[1].GetValue<string>('acceptance') = 'REJECT')
                else
                  Passed := Passed and (Items.Items[0].GetValue<string>('scenario') = 'first')
                    and (Items.Items[1].GetValue<string>('scenario') = 'second')
                    and (Items.Items[1].GetValue<string>('status') = 'V')
                    and (Items.Items[1].GetValue<string>('acceptance') = 'ACCEPTABLE');
              end;
            end;
          finally
            FreeAndNil(Json);
          end;
          Passed := Passed and FileExists(ExpectedReport) and FileExists(TPath.Combine(OutputDirectory, 'second-report.xml'))
            and (Length(TDirectory.GetFiles(OutputDirectory)) = 2);
        end;
        if CaseIndex = 30 then Passed := Passed and Diagnostic.Contains('Repository für Szenariodefinition fehlt: second')
          and (Length(TDirectory.GetFiles(OutputDirectory)) = 0);
        if CaseIndex = 31 then Passed := Passed and Diagnostic.Contains('Warnung:') and Diagnostic.Contains('unused')
          and MatchesPublicResult(ProcessResult.OutputText, 'V', 'ACCEPTABLE', True);
        if CaseIndex = 32 then Passed := Passed and Diagnostic.Contains('Keine Assertions für Bericht:') and Diagnostic.Contains('invoice-report.xml');
        if CaseIndex = 33 then
        begin
          Document := ParseTestXml(TFile.ReadAllText(TPath.Combine(OutputDirectory, 'invoice-reportInput.xml'), TEncoding.UTF8));
          Node := Document.selectSingleNode('/i:createReportInput/i:documentIdentification/i:documentHash/i:hashValue');
          Passed := Passed and (Node <> nil) and (Node.text = InputHash(TFile.ReadAllBytes(ValidXml)))
            and (Document.selectSingleNode('/i:createReportInput/i:validationResultsXmlSchema') <> nil)
            and (Length(TDirectory.GetFiles(OutputDirectory)) = 3);
          Document := ParseTestXml(TFile.ReadAllText(ExpectedReport, TEncoding.UTF8));
          Passed := Passed and (Document.selectSingleNode('/r:report/r:assessment/r:accept') <> nil)
            and TFile.ReadAllText(TPath.Combine(OutputDirectory, 'invoice-report.html'), TEncoding.UTF8).Contains('[Seller name]');
        end;
        if CaseIndex = 34 then
        begin
          Document := ParseTestXml(TFile.ReadAllText(TPath.Combine(OutputDirectory, 'first-reportInput.xml'), TEncoding.UTF8));
          Node := Document.selectSingleNode('/i:createReportInput/i:processingError/i:error');
          Passed := Passed and (Node <> nil) and string(Node.text).Contains('runtime-contract') and Diagnostic.Contains('Schematron-Prüfung')
            and not FileExists(TPath.Combine(OutputDirectory, 'first-report.html'));
        end;
        if CaseIndex >= 36 then
        begin
          Document := ParseTestXml(TFile.ReadAllText(ExpectedReport, TEncoding.UTF8));
          Passed := Passed and (Document.selectSingleNode('/r:report/r:assessment/r:accept') <> nil)
            and (Length(TDirectory.GetFiles(OutputDirectory)) = 1);
        end;
        if CaseIndex in [15, 16, 20] then
        begin
          Document := ParseTestXml(TFile.ReadAllText(ExpectedReport, TEncoding.UTF8));
          Node := Document.selectSingleNode('/r:report/r:scenarioMatched/s:scenario/s:name');
          Passed := Passed and (Node <> nil) and (Node.text = 'EN16931 XRechnung (UBL Invoice)')
            and (Document.selectSingleNode('/r:report/r:assessment/r:accept') <> nil)
            and (Length(TDirectory.GetFiles(OutputDirectory)) = 1);
          if CaseIndex = 20 then Passed := Passed and (ProcessResult.ErrorText = '') and ProcessResult.OutputText.Contains('<?xml version="1.0"')
            and (ParseTestXml(ProcessResult.OutputText).documentElement.namespaceURI = 'http://www.xoev.de/de/validator/varl/1');
        end;
        if (ExpectedExit <> 0) and not (CaseIndex in [17, 26]) then Passed := Passed and (Diagnostic <> '');
      except
        on Error: Exception do
        begin
          if CaseEvidence.GetValue('exit_code') = nil then
            CaseEvidence.AddPair('exit_code', TJSONNumber.Create(-1));
          Diagnostic := Error.ClassName + ': ' + Error.Message;
        end;
      end;
      CaseEvidence.AddPair('passed', TJSONBool.Create(Passed));
      CaseEvidence.AddPair('diagnostic', Diagnostic);
      if Passed then Inc(PassedCount);
      WriteLn(CaseName, ': ', BoolToStr(Passed, True));
    end;
    Evidence.AddPair('passed', TJSONNumber.Create(PassedCount));
    Evidence.AddPair('total', TJSONNumber.Create(Cases.Count));
    TFile.WriteAllText(TPath.Combine(EvidenceDirectory, 'result.json'), Evidence.ToJSON, TEncoding.UTF8);
    if PassedCount <> Cases.Count then ExitCode := 1;
  finally
    FreeAndNil(Evidence);
  end;
end;

begin
  SetTextCodePage(Output, 65001);
  SetTextCodePage(ErrOutput, 65001);
  try
    OleCheck(CoInitializeEx(nil, COINIT_APARTMENTTHREADED));
    try
      RunTests;
    finally
      CoUninitialize;
    end;
  except
    on Error: Exception do
    begin
      WriteLn(ErrOutput, Error.ClassName, ': ', Error.Message);
      ExitCode := 254;
    end;
  end;
end.
