program CliTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, Winapi.Windows;

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

// Ein neuer Evidence-Ordner verhindert die Wiederverwendung alter Berichte oder Prozessausgaben.
procedure RunTests;
const
  AssertionsStart = '<assertions xmlns="http://www.xoev.de/de/validator/framework/1/assertions">';
var
  Executable, LibraryFile, ValidationRoot, ValidXml, InvalidXml, EvidenceDirectory, ConfigFile, Repository: string;
  CaseDirectory, OutputDirectory, InputFile, AssertionsFile, ExpectedReport, CollisionFile: string;
  CaseName, Diagnostic: string;
  Evidence, CaseEvidence: TJSONObject;
  Cases: TJSONArray;
  Arguments, BaseArguments: TArray<string>;
  ProcessResult: TProcessResult;
  PipeInput: TBytes;
  CaseIndex, PassedCount: Integer;
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
    for CaseIndex := 0 to 15 do
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
      else
        CaseName := 'default-library-foreign-cwd';
      end;
      CaseDirectory := TPath.Combine(EvidenceDirectory, CaseName);
      OutputDirectory := TPath.Combine(CaseDirectory, 'Ausgaben mit Leerzeichen');
      ForceDirectories(OutputDirectory);
      InputFile := TPath.Combine(CaseDirectory, 'invoice.xml');
      if CaseIndex = 8 then TFile.Copy(InvalidXml, InputFile) else TFile.Copy(ValidXml, InputFile);
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
        if CaseIndex in [6, 7, 8, 12, 15] then Passed := Passed and FileExists(ExpectedReport);
        if CaseIndex = 0 then Passed := Passed and ProcessResult.OutputText.Contains('MGGM XML Validator für Delphi') and ProcessResult.OutputText.Contains('MGGMXmlValidator -s');
        if CaseIndex = 5 then Passed := Passed and (TFile.ReadAllText(CollisionFile, TEncoding.UTF8) = 'unverändert');
        if ExpectedExit <> 0 then Passed := Passed and (Diagnostic <> '');
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
    RunTests;
  except
    on Error: Exception do
    begin
      WriteLn(ErrOutput, Error.ClassName, ': ', Error.Message);
      ExitCode := 254;
    end;
  end;
end.
