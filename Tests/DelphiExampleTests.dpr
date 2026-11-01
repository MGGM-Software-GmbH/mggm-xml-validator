program DelphiExampleTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, Winapi.Windows,
  MGKosit;

type
  TProcessResult = record
    ExitCode: DWORD;
    OutputText, ErrorText: string;
  end;

// Windows-CRT-Quoting erhält auch leere Argumente und abschließende Backslashes.
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

// Pro Kindprozess entstehen neue Nachweisdateien; das Arbeitsverzeichnis ist ausdrücklich getrennt.
function ExecuteProcess(const Executable, WorkingDirectory, EvidenceDirectory: string; const Arguments: TArray<string>;
  const RawCommandLine: string = ''): TProcessResult;
var
  Security: TSecurityAttributes;
  Startup: TStartupInfo;
  Process: TProcessInformation;
  OutputHandle, ErrorHandle, InputHandle: THandle;
  CommandLine, Argument, OutputFile, ErrorFile: string;
  ProcessStarted, ProcessFinished: Boolean;
  WaitStatus: DWORD;
begin
  OutputHandle := INVALID_HANDLE_VALUE;
  ErrorHandle := INVALID_HANDLE_VALUE;
  InputHandle := INVALID_HANDLE_VALUE;
  ProcessStarted := False;
  ProcessFinished := False;
  FillChar(Security, SizeOf(Security), 0);
  Security.nLength := SizeOf(Security);
  Security.bInheritHandle := True;
  FillChar(Process, SizeOf(Process), 0);
  OutputFile := TPath.Combine(EvidenceDirectory, 'stdout.txt');
  ErrorFile := TPath.Combine(EvidenceDirectory, 'stderr.txt');
  try
    InputHandle := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, @Security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if InputHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
    OutputHandle := CreateFile(PChar(OutputFile), GENERIC_WRITE, FILE_SHARE_READ, @Security, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
    if OutputHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
    ErrorHandle := CreateFile(PChar(ErrorFile), GENERIC_WRITE, FILE_SHARE_READ, @Security, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
    if ErrorHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
    FillChar(Startup, SizeOf(Startup), 0);
    Startup.cb := SizeOf(Startup);
    Startup.dwFlags := STARTF_USESTDHANDLES;
    Startup.hStdInput := InputHandle;
    Startup.hStdOutput := OutputHandle;
    Startup.hStdError := ErrorHandle;
    if RawCommandLine <> '' then
      CommandLine := RawCommandLine
    else
    begin
      CommandLine := QuoteArgument(Executable);
      for Argument in Arguments do
        CommandLine := CommandLine + ' ' + QuoteArgument(Argument);
    end;
    UniqueString(CommandLine);
    if not CreateProcess(PChar(Executable), PChar(CommandLine), nil, nil, True, CREATE_NO_WINDOW, nil, PChar(WorkingDirectory), Startup, Process) then
      RaiseLastOSError;
    ProcessStarted := True;
    WaitStatus := WaitForSingleObject(Process.hProcess, 120000);
    if WaitStatus <> WAIT_OBJECT_0 then
      raise Exception.CreateFmt('Kindprozess nicht beendet, Wait-Status %d', [WaitStatus]);
    ProcessFinished := True;
    if not GetExitCodeProcess(Process.hProcess, Result.ExitCode) then RaiseLastOSError;
  finally
    if InputHandle <> INVALID_HANDLE_VALUE then CloseHandle(InputHandle);
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

// cmd.exe stammt aus dem Windows-Systemverzeichnis und nicht aus PATH oder COMSPEC.
function TrustedCommandProcessor: string;
var
  DirectoryBuffer: array[0..MAX_PATH] of Char;
  DirectoryLength: UINT;
begin
  DirectoryLength := GetSystemDirectory(DirectoryBuffer, Length(DirectoryBuffer));
  if DirectoryLength = 0 then RaiseLastOSError;
  if DirectoryLength >= UINT(Length(DirectoryBuffer)) then
    raise Exception.Create('Windows-Systemverzeichnis überschreitet den Testpuffer');
  Result := TPath.Combine(string(DirectoryBuffer), 'cmd.exe');
  if not FileExists(Result) then
    raise Exception.Create('Windows-Kommandointerpreter fehlt: ' + Result);
end;

// CMD verarbeitet innere Anführungszeichen selbst; CRT-Backslash-Escaping wäre hier falsch.
function CommandArgument(const Value: string): string;
begin
  if Value.Contains('"') or Value.Contains('%') or Value.Contains('!') or Value.Contains(#13) or Value.Contains(#10) then
    raise Exception.Create('Testpfad enthält für CMD nicht unterstützte Zeichen: ' + Value);
  Result := '"' + Value + '"';
end;

// Die äußere Quote-Ebene gehört zu /s /c, die inneren Quotes schützen die drei kontrollierten Pfade.
function BatchCommandLine(const CommandProcessor, CommandFile, InputFile, OutputDirectory: string): string;
begin
  Result := CommandArgument(CommandProcessor) + ' /d /s /c "' + CommandArgument(CommandFile) + ' ' + CommandArgument(InputFile) + ' ' + CommandArgument(OutputDirectory) + '"';
end;

// Der isolierte Aufruf prüft die öffentliche Unit ohne Regeln oder Rechnung als zusätzliche Voraussetzung.
function ProbeLibrary: Integer;
var
  Validator: TMGKositValidator;
begin
  try
    if ParamStr(1) = '--probe-default' then
      Validator := TMGKositValidator.Create
    else
      Validator := TMGKositValidator.Create(ParamStr(2));
    try
      WriteLn('API-OK');
      Result := 0;
    finally
      FreeAndNil(Validator);
    end;
  except
    on Error: Exception do
    begin
      WriteLn(ErrOutput, Error.ClassName, ': ', Error.Message);
      Result := 3;
    end;
  end;
end;

// Ein eigener Nachweisordner enthält die Anwendung mit und ohne DLL sowie getrennte Prozessausgaben.
procedure RunTests;
var
  ExampleFile, LibraryFile, ValidationDirectory, ValidXml, InvalidXml, EvidenceDirectory: string;
  ApplicationDirectory, MissingLibraryDirectory, CaseDirectory, OutputDirectory, WorkingDirectory: string;
  ExampleExecutable, ProbeExecutable, TargetExecutable, CaseName, ExpectedError, Diagnostic: string;
  InvalidXmlFile, MalformedXmlFile, SentinelFile, XmlReport, HtmlReport, ReportLine: string;
  CommandProcessor, PackagedCommandFile, MissingLibraryCommandFile, RawCommandLine: string;
  Arguments: TArray<string>;
  Evidence, CaseEvidence: TJSONObject;
  Cases: TJSONArray;
  ProcessResult: TProcessResult;
  CaseIndex, PassedCount, ExpectedExit: Integer;
  Passed, ExpectReports: Boolean;
begin
  if ParamCount <> 6 then
    raise Exception.Create('Aufruf: DelphiExampleTests ExampleExe DLL ValidationDirectory ValidXml InvalidBusinessXml EvidenceDirectory');
  ExampleFile := ExpandFileName(ParamStr(1));
  LibraryFile := ExpandFileName(ParamStr(2));
  ValidationDirectory := ExpandFileName(ParamStr(3));
  ValidXml := ExpandFileName(ParamStr(4));
  InvalidXml := ExpandFileName(ParamStr(5));
  EvidenceDirectory := ExpandFileName(ParamStr(6));
  if not FileExists(ExampleFile) or not FileExists(LibraryFile) or not FileExists(ValidXml) or not FileExists(InvalidXml) then
    raise Exception.Create('Beispiel, DLL oder XML-Testdatei fehlt');
  if not DirectoryExists(ValidationDirectory) then
    raise Exception.Create('Regelverzeichnis fehlt: ' + ValidationDirectory);
  PackagedCommandFile := TPath.Combine(ExtractFileDir(ExampleFile), 'validate.cmd');
  if not FileExists(PackagedCommandFile) then
    raise Exception.Create('Paketiertes CMD-Beispiel fehlt: ' + PackagedCommandFile);
  CommandProcessor := TrustedCommandProcessor;
  if FileExists(EvidenceDirectory) or DirectoryExists(EvidenceDirectory) then
    raise Exception.Create('Nachweisverzeichnis muss neu sein: ' + EvidenceDirectory);
  ApplicationDirectory := TPath.Combine(EvidenceDirectory, 'Anwendung mit Leerzeichen');
  MissingLibraryDirectory := TPath.Combine(EvidenceDirectory, 'Anwendung ohne DLL');
  ForceDirectories(ApplicationDirectory);
  ForceDirectories(MissingLibraryDirectory);
  ExampleExecutable := TPath.Combine(ApplicationDirectory, 'ValidateXmlExample.exe');
  ProbeExecutable := TPath.Combine(ApplicationDirectory, 'DelphiExampleTests.exe');
  TFile.Copy(ExampleFile, ExampleExecutable);
  TFile.Copy(ExpandFileName(ParamStr(0)), ProbeExecutable);
  TFile.Copy(LibraryFile, TPath.Combine(ApplicationDirectory, 'saxonc-core-he.dll'));
  TFile.Copy(ExampleFile, TPath.Combine(MissingLibraryDirectory, 'ValidateXmlExample.exe'));
  TFile.Copy(ExpandFileName(ParamStr(0)), TPath.Combine(MissingLibraryDirectory, 'DelphiExampleTests.exe'));
  MissingLibraryCommandFile := TPath.Combine(MissingLibraryDirectory, 'validate.cmd');
  TFile.Copy(PackagedCommandFile, MissingLibraryCommandFile);
  InvalidXmlFile := TPath.Combine(ApplicationDirectory, 'fachlich ungültig.xml');
  TFile.Copy(InvalidXml, InvalidXmlFile);
  MalformedXmlFile := TPath.Combine(ApplicationDirectory, 'syntaktisch ungültig.xml');
  TFile.WriteAllText(MalformedXmlFile, '<Invoice>', TEncoding.UTF8);
  Evidence := TJSONObject.Create;
  try
    Cases := TJSONArray.Create;
    Evidence.AddPair('cases', Cases);
    PassedCount := 0;
    for CaseIndex := 0 to 16 do
    begin
      case CaseIndex of
        0: CaseName := 'api-default-foreign-cwd';
        1: CaseName := 'api-explicit-absolute';
        2: CaseName := 'api-relative-rejected';
        3: CaseName := 'api-default-missing-no-cwd-search';
        4: CaseName := 'example-valid-stream';
        5: CaseName := 'example-invalid-business-stream';
        6: CaseName := 'example-missing-input';
        7: CaseName := 'example-missing-library';
        8: CaseName := 'example-missing-default-rules';
        9: CaseName := 'example-existing-output';
        10: CaseName := 'example-default-output';
        11: CaseName := 'example-malformed-xml';
        12: CaseName := 'example-help';
        13: CaseName := 'cmd-valid-default-rules-foreign-cwd';
        14: CaseName := 'cmd-invalid-default-rules-foreign-cwd';
        15: CaseName := 'cmd-missing-library-no-cwd-search';
      else
        CaseName := 'cmd-default-output-foreign-cwd';
      end;
      CaseDirectory := TPath.Combine(EvidenceDirectory, CaseName);
      ForceDirectories(CaseDirectory);
      OutputDirectory := TPath.Combine(CaseDirectory, 'Berichte mit Leerzeichen');
      WorkingDirectory := CaseDirectory;
      TargetExecutable := ExampleExecutable;
      Arguments := TArray<string>.Create(ValidXml, OutputDirectory, ValidationDirectory);
      RawCommandLine := '';
      ExpectedExit := 0;
      ExpectedError := '';
      ExpectReports := CaseIndex in [4, 5, 13, 14];
      case CaseIndex of
        0: begin TargetExecutable := ProbeExecutable; Arguments := TArray<string>.Create('--probe-default'); end;
        1: begin TargetExecutable := ProbeExecutable; Arguments := TArray<string>.Create('--probe-library', LibraryFile); end;
        2: begin
          TargetExecutable := ProbeExecutable;
          WorkingDirectory := ExtractFileDir(LibraryFile);
          Arguments := TArray<string>.Create('--probe-library', 'saxonc-core-he.dll');
          ExpectedExit := 3;
          ExpectedError := 'absolut';
        end;
        3: begin
          TargetExecutable := TPath.Combine(MissingLibraryDirectory, 'DelphiExampleTests.exe');
          WorkingDirectory := ExtractFileDir(LibraryFile);
          Arguments := TArray<string>.Create('--probe-default');
          ExpectedExit := 3;
          ExpectedError := TPath.Combine(MissingLibraryDirectory, 'saxonc-core-he.dll');
        end;
        5: begin Arguments := TArray<string>.Create(InvalidXmlFile, OutputDirectory, ValidationDirectory); ExpectedExit := 1; end;
        6: begin
          Arguments := TArray<string>.Create(TPath.Combine(CaseDirectory, 'missing.xml'), OutputDirectory, ValidationDirectory);
          ExpectedExit := 2;
          ExpectedError := 'XML-Eingabedatei fehlt';
        end;
        7: begin
          TargetExecutable := TPath.Combine(MissingLibraryDirectory, 'ValidateXmlExample.exe');
          WorkingDirectory := ExtractFileDir(LibraryFile);
          ExpectedExit := 3;
          ExpectedError := TPath.Combine(MissingLibraryDirectory, 'saxonc-core-he.dll');
        end;
        8: begin
          Arguments := TArray<string>.Create(ValidXml, OutputDirectory);
          ExpectedExit := 4;
          ExpectedError := TPath.Combine(ApplicationDirectory, 'Validation');
        end;
        9: begin
          ForceDirectories(OutputDirectory);
          SentinelFile := TPath.Combine(OutputDirectory, 'report.xml');
          TFile.WriteAllText(SentinelFile, 'unverändert', TEncoding.UTF8);
          ExpectedExit := 5;
          ExpectedError := 'Ausgabeverzeichnis muss neu sein';
        end;
        10: begin
          TargetExecutable := ExampleFile;
          Arguments := TArray<string>.Create(ValidXml);
        end;
        11: begin
          Arguments := TArray<string>.Create(MalformedXmlFile, OutputDirectory, ValidationDirectory);
          ExpectedExit := 6;
        end;
        12: Arguments := TArray<string>.Create('--help');
        13, 14: begin
          TargetExecutable := CommandProcessor;
          Arguments := nil;
          if CaseIndex = 13 then
            RawCommandLine := BatchCommandLine(CommandProcessor, PackagedCommandFile, ValidXml, OutputDirectory)
          else
          begin
            RawCommandLine := BatchCommandLine(CommandProcessor, PackagedCommandFile, InvalidXmlFile, OutputDirectory);
            ExpectedExit := 1;
          end;
        end;
        15: begin
          TargetExecutable := CommandProcessor;
          Arguments := nil;
          WorkingDirectory := ExtractFileDir(LibraryFile);
          RawCommandLine := BatchCommandLine(CommandProcessor, MissingLibraryCommandFile, ValidXml, OutputDirectory);
          ExpectedExit := 3;
          ExpectedError := TPath.Combine(MissingLibraryDirectory, 'saxonc-core-he.dll');
        end;
        16: begin
          TargetExecutable := CommandProcessor;
          Arguments := nil;
          RawCommandLine := BatchCommandLine(CommandProcessor, PackagedCommandFile, ValidXml, '');
        end;
      end;
      CaseEvidence := TJSONObject.Create;
      Cases.AddElement(CaseEvidence);
      CaseEvidence.AddPair('name', CaseName);
      CaseEvidence.AddPair('expected_exit_code', TJSONNumber.Create(ExpectedExit));
      Passed := False;
      Diagnostic := '';
      try
        ProcessResult := ExecuteProcess(TargetExecutable, WorkingDirectory, CaseDirectory, Arguments, RawCommandLine);
        CaseEvidence.AddPair('exit_code', TJSONNumber.Create(Int64(ProcessResult.ExitCode)));
        Diagnostic := ProcessResult.ErrorText;
        Passed := ProcessResult.ExitCode = DWORD(ExpectedExit);
        if ExpectedError <> '' then Passed := Passed and ProcessResult.ErrorText.Contains(ExpectedError);
        if CaseIndex in [0, 1] then Passed := Passed and ProcessResult.OutputText.Contains('API-OK');
        if CaseIndex in [4, 10, 13, 16] then
          Passed := Passed and (ProcessResult.OutputText.Contains('Status: V') or ProcessResult.OutputText.Contains('Status: W'));
        if CaseIndex in [5, 14] then Passed := Passed and ProcessResult.OutputText.Contains('Status: E');
        if CaseIndex = 15 then
          Passed := Passed and not DirectoryExists(OutputDirectory) and not ProcessResult.OutputText.Contains('Status:');
        if CaseIndex = 9 then Passed := Passed and (TFile.ReadAllText(SentinelFile, TEncoding.UTF8) = 'unverändert');
        if CaseIndex in [10, 16] then
        begin
          XmlReport := '';
          HtmlReport := '';
          // Nur der vom aktuellen Kindprozess gemeldete Bericht zählt als Nachweis.
          for ReportLine in ProcessResult.OutputText.Split([#13, #10]) do
            if ReportLine.StartsWith('XML-Bericht: ') then
              XmlReport := Copy(ReportLine, Length('XML-Bericht: ') + 1, MaxInt);
          if XmlReport <> '' then HtmlReport := ChangeFileExt(XmlReport, '.html');
          Passed := Passed and FileExists(XmlReport) and FileExists(HtmlReport);
          Passed := Passed and XmlReport.StartsWith(IncludeTrailingPathDelimiter(TPath.Combine(ExtractFileDir(ExampleFile), 'Reports')), True);
          Passed := Passed and ProcessResult.OutputText.Contains('XML-Bericht: ' + XmlReport);
        end;
        if ExpectReports then
        begin
          XmlReport := TPath.Combine(OutputDirectory, 'report.xml');
          HtmlReport := TPath.Combine(OutputDirectory, 'report.html');
          Passed := Passed and FileExists(XmlReport) and FileExists(HtmlReport);
          if FileExists(XmlReport) then Passed := Passed and (TFile.ReadAllText(XmlReport, TEncoding.UTF8) <> '');
          if FileExists(HtmlReport) then Passed := Passed and TFile.ReadAllText(HtmlReport, TEncoding.UTF8).Contains('<html');
        end;
        if CaseIndex = 11 then Passed := Passed and ProcessResult.OutputText.Contains('Status: F') and ProcessResult.OutputText.Contains('XML-WELLFORMEDNESS');
        if CaseIndex = 12 then Passed := Passed and ProcessResult.OutputText.Contains('ValidateXmlExample');
      except
        on Error: Exception do
        begin
          if CaseEvidence.GetValue('exit_code') = nil then CaseEvidence.AddPair('exit_code', TJSONNumber.Create(-1));
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
  if (ParamStr(1) = '--probe-default') or (ParamStr(1) = '--probe-library') then
    ExitCode := ProbeLibrary
  else
    try
      RunTests;
    except
      on Error: Exception do
      begin
        WriteLn(ErrOutput, Error.ClassName, ': ', Error.Message);
        ExitCode := 254;
      end;
    end;
end.
