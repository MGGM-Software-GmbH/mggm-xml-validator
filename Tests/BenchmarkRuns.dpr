program BenchmarkRuns;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Diagnostics, System.DateUtils, Winapi.Windows;

const
  ScenarioNames: array[0..2] of string = (
    'validator-configuration-zugferd\scenarios.xml',
    'validator-configuration-zugferd\scenarios_zugferd1.xml',
    'validator-configuration-xrechnung\3.0.2\scenarios.xml');

// Windows-CRT-Quoting erhält auch Leerzeichen und abschließende Backslashes ohne Shellauswertung.
function QuoteArgument(const Value: string): string;
var
  Character: Char;
  SlashCount: Integer;
begin
  Result := '"';
  SlashCount := 0;
  for Character in Value do
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
  Result := Result + StringOfChar('\', SlashCount * 2) + '"';
end;

// CPU-Zeiten stammen aus dem beendeten Kindprozess und enthalten keine Wartezeit des Messprogramms.
function FileTimeMilliseconds(const Value: TFileTime): Double;
begin
  Result := ((UInt64(Value.dwHighDateTime) shl 32) or Value.dwLowDateTime) / 10000.0;
end;

// Jede Messung verwendet neue Logs; bei Zeitüberschreitung wird der eigene Kindprozess beendet.
function ExecuteMeasured(const Executable, WorkingDirectory, LogDirectory: string; const Arguments: TArray<string>): TJSONObject;
var
  Security: TSecurityAttributes;
  Startup: TStartupInfo;
  Process: TProcessInformation;
  InputHandle, InputWrite, OutputHandle, ErrorHandle: THandle;
  CommandLine, Argument: string;
  Watch: TStopwatch;
  WaitStatus, ChildExit: DWORD;
  CreatedAt, ExitedAt, KernelTime, UserTime: TFileTime;
  Started, Finished: Boolean;
  ArgumentJson: TJSONArray;
begin
  if not CreateDir(LogDirectory) then
    RaiseLastOSError;
  FillChar(Security, SizeOf(Security), 0);
  Security.nLength := SizeOf(Security);
  Security.bInheritHandle := True;
  FillChar(Process, SizeOf(Process), 0);
  Started := False;
  Finished := False;
  InputHandle := INVALID_HANDLE_VALUE;
  InputWrite := INVALID_HANDLE_VALUE;
  OutputHandle := INVALID_HANDLE_VALUE;
  ErrorHandle := INVALID_HANDLE_VALUE;
  try
    // KoSIT fragt System.in.available ab; eine leere Pipe unterstützt dies auch unter Windows.
    if not CreatePipe(InputHandle, InputWrite, @Security, 0) then RaiseLastOSError;
    if not SetHandleInformation(InputWrite, HANDLE_FLAG_INHERIT, 0) then RaiseLastOSError;
    OutputHandle := CreateFile(PChar(TPath.Combine(LogDirectory, 'stdout.log')), GENERIC_WRITE, FILE_SHARE_READ, @Security, CREATE_NEW, 0, 0);
    if OutputHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
    ErrorHandle := CreateFile(PChar(TPath.Combine(LogDirectory, 'stderr.log')), GENERIC_WRITE, FILE_SHARE_READ, @Security, CREATE_NEW, 0, 0);
    if ErrorHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
    CommandLine := QuoteArgument(Executable);
    for Argument in Arguments do
      CommandLine := CommandLine + ' ' + QuoteArgument(Argument);
    if Length(CommandLine) >= 32767 then
      raise Exception.Create('Windows-Kommandozeile überschreitet 32766 Zeichen');
    UniqueString(CommandLine);
    FillChar(Startup, SizeOf(Startup), 0);
    Startup.cb := SizeOf(Startup);
    Startup.dwFlags := STARTF_USESTDHANDLES;
    Startup.hStdInput := InputHandle;
    Startup.hStdOutput := OutputHandle;
    Startup.hStdError := ErrorHandle;
    Watch := TStopwatch.StartNew;
    if not CreateProcess(PChar(Executable), PChar(CommandLine), nil, nil, True, CREATE_NO_WINDOW, nil, PChar(WorkingDirectory), Startup, Process) then
      RaiseLastOSError;
    Started := True;
    CloseHandle(InputWrite);
    InputWrite := INVALID_HANDLE_VALUE;
    WaitStatus := WaitForSingleObject(Process.hProcess, 600000);
    if WaitStatus <> WAIT_OBJECT_0 then
      raise Exception.CreateFmt('Kindprozess nicht innerhalb von 600 Sekunden beendet: %s (Wait %d)', [Executable, WaitStatus]);
    Watch.Stop;
    Finished := True;
    if not GetExitCodeProcess(Process.hProcess, ChildExit) then RaiseLastOSError;
    if not GetProcessTimes(Process.hProcess, CreatedAt, ExitedAt, KernelTime, UserTime) then RaiseLastOSError;
    Result := TJSONObject.Create;
    Result.AddPair('executable', Executable);
    Result.AddPair('working_directory', WorkingDirectory);
    Result.AddPair('command_line', CommandLine);
    ArgumentJson := TJSONArray.Create;
    Result.AddPair('arguments', ArgumentJson);
    for Argument in Arguments do ArgumentJson.Add(Argument);
    Result.AddPair('exit_code', TJSONNumber.Create(ChildExit));
    Result.AddPair('wall_ms', TJSONNumber.Create(Watch.Elapsed.TotalMilliseconds));
    Result.AddPair('cpu_user_ms', TJSONNumber.Create(FileTimeMilliseconds(UserTime)));
    Result.AddPair('cpu_kernel_ms', TJSONNumber.Create(FileTimeMilliseconds(KernelTime)));
    TFile.WriteAllText(TPath.Combine(LogDirectory, 'process.json'), Result.ToJSON, TEncoding.UTF8);
  finally
    if Started then
    begin
      if not Finished then
      begin
        TerminateProcess(Process.hProcess, 253);
        WaitForSingleObject(Process.hProcess, 10000);
      end;
      CloseHandle(Process.hThread);
      CloseHandle(Process.hProcess);
    end;
    if InputHandle <> INVALID_HANDLE_VALUE then CloseHandle(InputHandle);
    if InputWrite <> INVALID_HANDLE_VALUE then CloseHandle(InputWrite);
    if OutputHandle <> INVALID_HANDLE_VALUE then CloseHandle(OutputHandle);
    if ErrorHandle <> INVALID_HANDLE_VALUE then CloseHandle(ErrorHandle);
  end;
end;

// Identische Szenarien und XML-/HTML-Ausgaben sind Voraussetzung für den Vergleich der Batchvarianten.
function RunBenchmark: Integer;
var
  Mode, JavaExe, JarFile, CliExe, BatchExe, LibraryFile, ValidationRoot, InputDirectory, OutputDirectory: string;
  Executable, ReportsDirectory, LogDirectory, ScenarioName, FileName, StartedAt: string;
  Inputs: TStringList;
  Arguments, BaseArguments: TArray<string>;
  Summary, ProcessResult: TJSONObject;
  Processes: TJSONArray;
  TotalWatch: TStopwatch;
  WallMs, CpuUserMs, CpuKernelMs: Double;
  ProcessIndex, ProcessCount, FirstIndex, SelectedCount: Integer;
  ChildExit: Int64;
  PerFile, IsJava: Boolean;
begin
  Result := 0;
  if (ParamCount = 1) and SameText(ParamStr(1), '--help') then
  begin
    WriteLn('BenchmarkRuns Mode JavaExe Jar CliExe BatchExe DLL ValidationRoot InputDirectory OutputDirectory [FirstIndex Count]');
    WriteLn('Mode: java-batch, java-batch-debug, delphi-cli, delphi-unit, delphi-unit-parallel, java-per-file, delphi-per-file');
    WriteLn('delphi-unit-parallel verwendet vier Worker in einem Prozess, begrenzt auf die Anzahl der XML-Dateien.');
    WriteLn('Neue Ausgabeziele, direkte XML-Dateien, gleicher Regelbestand und XML-/HTML-Berichte.');
    WriteLn('FirstIndex ist nullbasiert; Teilmengen sind nur bei Einzelprozessen erlaubt und ändern das Eingabeverzeichnis nicht.');
    Exit;
  end;
  if (ParamCount <> 9) and (ParamCount <> 11) then
    raise EArgumentException.Create('Aufruf siehe BenchmarkRuns --help');
  Mode := ParamStr(1);
  if (Mode <> 'java-batch') and (Mode <> 'java-batch-debug') and (Mode <> 'delphi-cli') and (Mode <> 'delphi-unit') and
    (Mode <> 'delphi-unit-parallel') and (Mode <> 'java-per-file') and (Mode <> 'delphi-per-file') then
    raise EArgumentException.Create('Unbekannter Modus: ' + Mode);
  JavaExe := ExpandFileName(ParamStr(2));
  JarFile := ExpandFileName(ParamStr(3));
  CliExe := ExpandFileName(ParamStr(4));
  BatchExe := ExpandFileName(ParamStr(5));
  LibraryFile := ExpandFileName(ParamStr(6));
  ValidationRoot := ExpandFileName(ParamStr(7));
  InputDirectory := ExpandFileName(ParamStr(8));
  OutputDirectory := ExpandFileName(ParamStr(9));
  IsJava := Mode.StartsWith('java-');
  PerFile := Mode.EndsWith('-per-file');
  if (ParamCount = 11) and not PerFile then
    raise EArgumentException.Create('Teilmengen sind nur bei Einzelprozessen erlaubt');
  if IsJava then Executable := JavaExe
  else if (Mode = 'delphi-unit') or (Mode = 'delphi-unit-parallel') then Executable := BatchExe
  else Executable := CliExe;
  if not FileExists(Executable) then raise EFileNotFoundException.Create('EXE fehlt: ' + Executable);
  if IsJava and not FileExists(JarFile) then raise EFileNotFoundException.Create('JAR fehlt: ' + JarFile);
  if not IsJava and not FileExists(LibraryFile) then raise EFileNotFoundException.Create('DLL fehlt: ' + LibraryFile);
  if not DirectoryExists(InputDirectory) then raise EDirectoryNotFoundException.Create('Eingabe fehlt: ' + InputDirectory);
  if DirectoryExists(OutputDirectory) or FileExists(OutputDirectory) then
    raise EArgumentException.Create('Ausgabeziel muss neu sein: ' + OutputDirectory);
  for ScenarioName in ScenarioNames do
    if not FileExists(TPath.Combine(ValidationRoot, ScenarioName)) then
      raise EFileNotFoundException.Create('Szenariokonfiguration fehlt: ' + ScenarioName);
  Inputs := TStringList.Create;
  try
    Inputs.CaseSensitive := False;
    Inputs.Sorted := True;
    Inputs.Duplicates := dupError;
    for FileName in TDirectory.GetFiles(InputDirectory) do
      if SameText(ExtractFileExt(FileName), '.xml') then Inputs.Add(ExtractFileName(FileName));
    if Inputs.Count = 0 then raise EArgumentException.Create('Keine direkten XML-Dateien gefunden');
    FirstIndex := 0;
    SelectedCount := Inputs.Count;
    if ParamCount = 11 then
    begin
      FirstIndex := StrToInt(ParamStr(10));
      SelectedCount := StrToInt(ParamStr(11));
      if (FirstIndex < 0) or (SelectedCount < 1) or (FirstIndex >= Inputs.Count) or (SelectedCount > Inputs.Count - FirstIndex) then
        raise EArgumentException.Create('Ungültiger Bereich der XML-Eingaben');
    end;
    if not CreateDir(OutputDirectory) then RaiseLastOSError;
    ReportsDirectory := TPath.Combine(OutputDirectory, 'reports');
    if (Mode <> 'delphi-unit') and (Mode <> 'delphi-unit-parallel') then
      if not CreateDir(ReportsDirectory) then RaiseLastOSError;
    BaseArguments := [];
    if (Mode = 'delphi-unit') or (Mode = 'delphi-unit-parallel') then
    begin
      BaseArguments := [LibraryFile, ValidationRoot, InputDirectory, ReportsDirectory];
      if Mode = 'delphi-unit-parallel' then
        BaseArguments := BaseArguments + ['4'];
    end
    else
    begin
      if IsJava then
        BaseArguments := ['-Xmx1G', '-Dfile.encoding=UTF-8', '-jar', JarFile];
      // Die Kontrollvariante hält die Debug-Option auch im Java-Batch konstant.
      if (Mode = 'java-per-file') or (Mode = 'java-batch-debug') then BaseArguments := BaseArguments + ['-X'];
      for ScenarioName in ScenarioNames do
        BaseArguments := BaseArguments + ['-s', TPath.Combine(ValidationRoot, ScenarioName)];
      BaseArguments := BaseArguments + ['--html', '-o', ReportsDirectory];
      if not IsJava then BaseArguments := BaseArguments + ['--saxon-library', LibraryFile];
    end;
    Summary := TJSONObject.Create;
    try
      Summary.AddPair('mode', Mode);
      Summary.AddPair('input_directory', InputDirectory);
      Summary.AddPair('file_count', TJSONNumber.Create(SelectedCount));
      Summary.AddPair('input_file_count', TJSONNumber.Create(Inputs.Count));
      Summary.AddPair('first_index', TJSONNumber.Create(FirstIndex));
      StartedAt := DateToISO8601(Now, False);
      Summary.AddPair('started_at', StartedAt);
      Processes := TJSONArray.Create;
      Summary.AddPair('processes', Processes);
      ProcessCount := 1;
      if PerFile then ProcessCount := SelectedCount;
      WallMs := 0;
      CpuUserMs := 0;
      CpuKernelMs := 0;
      TotalWatch := TStopwatch.StartNew;
      for ProcessIndex := 0 to ProcessCount - 1 do
      begin
        Arguments := Copy(BaseArguments);
        if PerFile then Arguments := Arguments + [Inputs[FirstIndex + ProcessIndex]]
        else if (Mode <> 'delphi-unit') and (Mode <> 'delphi-unit-parallel') then
          for FileName in Inputs do Arguments := Arguments + [FileName];
        LogDirectory := TPath.Combine(OutputDirectory, Format('process-%.4d', [ProcessIndex + 1]));
        ProcessResult := ExecuteMeasured(Executable, InputDirectory, LogDirectory, Arguments);
        Processes.AddElement(ProcessResult);
        WallMs := WallMs + ProcessResult.GetValue<Double>('wall_ms');
        CpuUserMs := CpuUserMs + ProcessResult.GetValue<Double>('cpu_user_ms');
        CpuKernelMs := CpuKernelMs + ProcessResult.GetValue<Double>('cpu_kernel_ms');
        ChildExit := ProcessResult.GetValue<Int64>('exit_code');
        if (ChildExit < 0) or (ChildExit > Inputs.Count) then
          raise Exception.CreateFmt('Technischer Kindprozessfehler: Exitcode %d, Logs: %s', [ChildExit, LogDirectory]);
        WriteLn(Mode, ' ', ProcessIndex + 1, '/', ProcessCount, ': ', ProcessResult.GetValue<Double>('wall_ms'):0:3, ' ms; Exit ', ChildExit);
        Flush(Output);
      end;
      TotalWatch.Stop;
      Summary.AddPair('process_count', TJSONNumber.Create(ProcessCount));
      Summary.AddPair('process_wall_ms', TJSONNumber.Create(WallMs));
      Summary.AddPair('cpu_user_ms', TJSONNumber.Create(CpuUserMs));
      Summary.AddPair('cpu_kernel_ms', TJSONNumber.Create(CpuKernelMs));
      Summary.AddPair('total_wall_ms', TJSONNumber.Create(TotalWatch.Elapsed.TotalMilliseconds));
      Summary.AddPair('finished_at', DateToISO8601(Now, False));
      TFile.WriteAllText(TPath.Combine(OutputDirectory, 'measurement.json'), Summary.ToJSON, TEncoding.UTF8);
    finally
      FreeAndNil(Summary);
    end;
  finally
    FreeAndNil(Inputs);
  end;
end;

begin
  SetTextCodePage(Output, 65001);
  SetTextCodePage(ErrOutput, 65001);
  try
    ExitCode := RunBenchmark;
  except
    on Error: Exception do
    begin
      WriteLn(ErrOutput, Error.ClassName, ': ', Error.Message);
      ExitCode := 254;
    end;
  end;
end.
