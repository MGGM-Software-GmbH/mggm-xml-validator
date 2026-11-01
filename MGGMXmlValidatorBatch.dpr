program MGGMXmlValidatorBatch;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
  System.Diagnostics,
  Winapi.Windows,
  Winapi.PsAPI,
  MGKosit;

const
  ScenarioNames: array[0..2] of string = (
    'validator-configuration-zugferd\scenarios.xml',
    'validator-configuration-zugferd\scenarios_zugferd1.xml',
    'validator-configuration-xrechnung\3.0.2\scenarios.xml');

// Ausschließlich neue Dateien anlegen, damit auch konkurrierende Ausgaben nicht überschrieben werden.
procedure WriteNewUtf8File(const FileName, Text: string);
var
  FileHandle: THandle;
  FileStream: THandleStream;
  TextBytes, Preamble: TBytes;
begin
  TextBytes := TEncoding.UTF8.GetBytes(Text);
  Preamble := TEncoding.UTF8.GetPreamble;
  FileHandle := CreateFile(PChar(FileName), GENERIC_WRITE, 0, nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
  if FileHandle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    FileStream := THandleStream.Create(FileHandle);
    try
      if Length(Preamble) > 0 then
        FileStream.WriteBuffer(Preamble[0], Length(Preamble));
      if Length(TextBytes) > 0 then
        FileStream.WriteBuffer(TextBytes[0], Length(TextBytes));
    finally
      FreeAndNil(FileStream);
    end;
  finally
    CloseHandle(FileHandle);
  end;
end;

// Nur direkte XML-Eingaben berücksichtigen; Sortierung und Kollisionserkennung gelten ohne Beachtung der Großschreibung.
procedure CollectInputs(const InputDirectory: string; const Inputs: TStringList);
var
  FileName: string;
begin
  Inputs.CaseSensitive := False;
  Inputs.Sorted := True;
  Inputs.Duplicates := dupError;
  for FileName in TDirectory.GetFiles(InputDirectory) do
    if SameText(ExtractFileExt(FileName), '.xml') then
      Inputs.Add(FileName);
  if Inputs.Count = 0 then
    raise EArgumentException.Create('Keine direkten XML-Dateien im Eingabeverzeichnis: ' + InputDirectory);
end;

// Die Klassifikation stammt ausschließlich aus dem Produktionsvalidator, einschließlich seiner Befundorte.
function ValidationJson(const Validation: TMGKositValidationResult; const InputFile, XmlReport, HtmlReport: string): TJSONObject;
var
  Acceptance: string;
  Finding: TMGKositFinding;
  FindingJson: TJSONObject;
  Findings: TJSONArray;
begin
  case Validation.Acceptance of
    kaAccept: Acceptance := 'ACCEPTABLE';
    kaReject: Acceptance := 'REJECT';
  else
    Acceptance := 'UNDEFINED';
  end;
  Result := TJSONObject.Create;
  try
    Result.AddPair('input', InputFile);
    Result.AddPair('reference', Validation.DocumentReference);
    Result.AddPair('scenario', Validation.ScenarioName);
    Result.AddPair('status', string(KositStatus(Validation)));
    Result.AddPair('acceptance', Acceptance);
    Result.AddPair('processing_error', TJSONBool.Create(Validation.ProcessingError));
    Result.AddPair('schema_valid', TJSONBool.Create(Validation.SchemaValid));
    Result.AddPair('error', Validation.ErrorMessage);
    Result.AddPair('errors', TJSONNumber.Create(Validation.Errors));
    Result.AddPair('warnings', TJSONNumber.Create(Validation.Warnings));
    Result.AddPair('report_xml', XmlReport);
    Result.AddPair('report_html', HtmlReport);
    Findings := TJSONArray.Create;
    Result.AddPair('findings', Findings);
    for Finding in Validation.Findings do
    begin
      FindingJson := TJSONObject.Create;
      Findings.AddElement(FindingJson);
      FindingJson.AddPair('level', Finding.Level);
      FindingJson.AddPair('code', Finding.Code);
      FindingJson.AddPair('text', Finding.Text);
      FindingJson.AddPair('location', Finding.Location);
      FindingJson.AddPair('validation_step', Finding.ValidationStep);
    end;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

type
  // Jeder Worker besitzt COM, Graal-Isolate und Validator ausschließlich in seinem Ausführungsthread.
  TBatchWorker = class(TThread)
  private
    FLibraryFile, FValidationRoot, FOutputDirectory: string;
    FInputs: TArray<string>;
    FResults: TArray<TJSONObject>;
    FWorkerIndex, FWorkerCount: Integer;
  protected
    procedure Execute; override;
  public
    ErrorText: string;
    Statistics: TMGKositStatistics;
    InitializationMs, ConfigurationMs, ValidationMs, ReportWriteMs, CleanupMs: Double;
    LoopStartedTicks, LoopFinishedTicks: Int64;
    RejectedCount, ProcessedCount: Integer;
    constructor Create(const LibraryFile, ValidationRoot, OutputDirectory: string; const Inputs: TArray<string>; const Results: TArray<TJSONObject>;
      const WorkerIndex, WorkerCount: Integer);
  end;

// Die Ergebnisplätze sind nach Eingabeindex getrennt; gemeinsame JSON-Arrays werden erst nach WaitFor aufgebaut.
constructor TBatchWorker.Create(const LibraryFile, ValidationRoot, OutputDirectory: string; const Inputs: TArray<string>; const Results: TArray<TJSONObject>;
  const WorkerIndex, WorkerCount: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLibraryFile := LibraryFile;
  FValidationRoot := ValidationRoot;
  FOutputDirectory := OutputDirectory;
  FInputs := Inputs;
  FResults := Results;
  FWorkerIndex := WorkerIndex;
  FWorkerCount := WorkerCount;
end;

// Auch Initialisierungs- und Freigabefehler gelangen mit Workerzuordnung zum Hauptthread.
procedure TBatchWorker.Execute;
var
  Validator: TMGKositValidator;
  Validation: TMGKositValidationResult;
  BeforeStatistics: TMGKositStatistics;
  PhaseWatch: TStopwatch;
  InputIndex: Integer;
  InputFile, ScenarioName, BaseName, XmlReport, HtmlReport, WrittenXml, WrittenHtml: string;
  FileResult: TJSONObject;
  FileValidationMs, FileReportWriteMs: Double;
  MemoryCounters: TProcessMemoryCounters;
begin
  try
    PhaseWatch := TStopwatch.StartNew;
    Validator := TMGKositValidator.Create(FLibraryFile);
    InitializationMs := PhaseWatch.Elapsed.TotalMilliseconds;
    try
      PhaseWatch := TStopwatch.StartNew;
      for ScenarioName in ScenarioNames do
        Validator.AddScenario(TPath.Combine(FValidationRoot, ScenarioName));
      ConfigurationMs := PhaseWatch.Elapsed.TotalMilliseconds;
      LoopStartedTicks := TStopwatch.GetTimeStamp;
      try
        InputIndex := FWorkerIndex;
        while InputIndex < Length(FInputs) do
        begin
          InputFile := FInputs[InputIndex];
          BeforeStatistics := Validator.Statistics;
          PhaseWatch := TStopwatch.StartNew;
          Validation := Validator.ValidateFile(InputFile, ExtractFileName(InputFile));
          FileValidationMs := PhaseWatch.Elapsed.TotalMilliseconds;
          ValidationMs := ValidationMs + FileValidationMs;
          BaseName := ChangeFileExt(ExtractFileName(InputFile), '');
          XmlReport := TPath.Combine(FOutputDirectory, BaseName + '-report.xml');
          HtmlReport := TPath.Combine(FOutputDirectory, BaseName + '-report.html');
          WrittenXml := '';
          WrittenHtml := '';
          PhaseWatch := TStopwatch.StartNew;
          if Validation.ReportXml <> '' then
          begin
            WriteNewUtf8File(XmlReport, Validation.ReportXml);
            WrittenXml := XmlReport;
          end;
          if Validation.ReportHtml <> '' then
          begin
            WriteNewUtf8File(HtmlReport, Validation.ReportHtml);
            WrittenHtml := HtmlReport;
          end;
          FileReportWriteMs := PhaseWatch.Elapsed.TotalMilliseconds;
          ReportWriteMs := ReportWriteMs + FileReportWriteMs;
          // Einzelzeiten zeigen, ob sich die Prüfdauer innerhalb eines langen Prozesses verändert.
          FileResult := ValidationJson(Validation, InputFile, WrittenXml, WrittenHtml);
          FResults[InputIndex] := FileResult;
          FileResult.AddPair('validate_ms', TJSONNumber.Create(FileValidationMs));
          FileResult.AddPair('report_write_ms', TJSONNumber.Create(FileReportWriteMs));
          FileResult.AddPair('worker_index', TJSONNumber.Create(FWorkerIndex + 1));
          FileResult.AddPair('worker_thread_id', TJSONNumber.Create(Int64(ThreadID)));
          Statistics := Validator.Statistics;
          FileResult.AddPair('schema_ms', TJSONNumber.Create(Statistics.SchemaValidationMs - BeforeStatistics.SchemaValidationMs));
          FileResult.AddPair('xpath_ms', TJSONNumber.Create(Statistics.XPathMs - BeforeStatistics.XPathMs));
          FileResult.AddPair('transform_ms', TJSONNumber.Create(Statistics.TransformationMs - BeforeStatistics.TransformationMs));
          FileResult.AddPair('source_parse_ms', TJSONNumber.Create(Statistics.DocumentParsingMs - BeforeStatistics.DocumentParsingMs));
          FileResult.AddPair('svrl_projection_ms', TJSONNumber.Create(Statistics.SvrlProjectionMs - BeforeStatistics.SvrlProjectionMs));
          FileResult.AddPair('dom_ms', TJSONNumber.Create(Statistics.DomMs - BeforeStatistics.DomMs));
          FileResult.AddPair('working_directory_ms', TJSONNumber.Create(Statistics.WorkingDirectoryMs - BeforeStatistics.WorkingDirectoryMs));
          FileResult.AddPair('temporary_cleanup_ms', TJSONNumber.Create(Statistics.TemporaryCleanupMs - BeforeStatistics.TemporaryCleanupMs));
          // Die Speicherreihe ergänzt die Einzelzeiten bei der Prüfung langer Prozesslaufzeiten.
          ZeroMemory(@MemoryCounters, SizeOf(MemoryCounters));
          MemoryCounters.cb := SizeOf(MemoryCounters);
          if not GetProcessMemoryInfo(GetCurrentProcess, @MemoryCounters, SizeOf(MemoryCounters)) then
            RaiseLastOSError;
          FileResult.AddPair('working_set_bytes', TJSONNumber.Create(Int64(MemoryCounters.WorkingSetSize)));
          FileResult.AddPair('peak_working_set_bytes', TJSONNumber.Create(Int64(MemoryCounters.PeakWorkingSetSize)));
          if Validation.ProcessingError or (Validation.Acceptance <> kaAccept) then
            Inc(RejectedCount);
          Inc(ProcessedCount);
          Inc(InputIndex, FWorkerCount);
        end;
      finally
        LoopFinishedTicks := TStopwatch.GetTimeStamp;
      end;
      Statistics := Validator.Statistics;
    finally
      PhaseWatch := TStopwatch.StartNew;
      try
        FreeAndNil(Validator);
      finally
        CleanupMs := PhaseWatch.Elapsed.TotalMilliseconds;
      end;
    end;
  except
    on Error: Exception do
      ErrorText := Error.ClassName + ': ' + Error.Message;
  end;
end;

// Zähler und CPU-nahe Phasenzeiten werden über alle unabhängigen Worker summiert.
procedure AddStatistics(var Total: TMGKositStatistics; const Value: TMGKositStatistics);
begin
  Total.SchemaCompilationCount := Total.SchemaCompilationCount + Value.SchemaCompilationCount;
  Total.StylesheetCompilationCount := Total.StylesheetCompilationCount + Value.StylesheetCompilationCount;
  Total.XPathProcessorCount := Total.XPathProcessorCount + Value.XPathProcessorCount;
  Total.SourceParseCount := Total.SourceParseCount + Value.SourceParseCount;
  Total.SchemaCompilationMs := Total.SchemaCompilationMs + Value.SchemaCompilationMs;
  Total.SchemaValidationMs := Total.SchemaValidationMs + Value.SchemaValidationMs;
  Total.XPathMs := Total.XPathMs + Value.XPathMs;
  Total.TransformationMs := Total.TransformationMs + Value.TransformationMs;
  Total.DocumentParsingMs := Total.DocumentParsingMs + Value.DocumentParsingMs;
  Total.SvrlProjectionMs := Total.SvrlProjectionMs + Value.SvrlProjectionMs;
  Total.DomMs := Total.DomMs + Value.DomMs;
  Total.WorkingDirectoryMs := Total.WorkingDirectoryMs + Value.WorkingDirectoryMs;
  Total.TemporaryCleanupMs := Total.TemporaryCleanupMs + Value.TemporaryCleanupMs;
end;

// Gleiche Statistikfelder gelten für die Summe und für jeden einzelnen Worker.
function EngineStatisticsJson(const Statistics: TMGKositStatistics): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('schema_compilations', TJSONNumber.Create(Statistics.SchemaCompilationCount));
  Result.AddPair('stylesheet_compilations', TJSONNumber.Create(Statistics.StylesheetCompilationCount));
  Result.AddPair('xpath_processors', TJSONNumber.Create(Statistics.XPathProcessorCount));
  Result.AddPair('source_parses', TJSONNumber.Create(Statistics.SourceParseCount));
  Result.AddPair('schema_compilation_ms', TJSONNumber.Create(Statistics.SchemaCompilationMs));
  Result.AddPair('schema_validation_ms', TJSONNumber.Create(Statistics.SchemaValidationMs));
  Result.AddPair('xpath_ms', TJSONNumber.Create(Statistics.XPathMs));
  Result.AddPair('transform_ms', TJSONNumber.Create(Statistics.TransformationMs));
  Result.AddPair('source_parse_ms', TJSONNumber.Create(Statistics.DocumentParsingMs));
  Result.AddPair('svrl_projection_ms', TJSONNumber.Create(Statistics.SvrlProjectionMs));
  Result.AddPair('dom_ms', TJSONNumber.Create(Statistics.DomMs));
  Result.AddPair('working_directory_ms', TJSONNumber.Create(Statistics.WorkingDirectoryMs));
  Result.AddPair('temporary_cleanup_ms', TJSONNumber.Create(Statistics.TemporaryCleanupMs));
end;

// Die Hauptinstanz verbindet ausschließlich beendete Worker und erhält die sortierte Eingabereihenfolge.
function RunBatch: Integer;
var
  LibraryFile, ValidationRoot, InputDirectory, OutputDirectory, ScenarioName, ScenarioFile, WorkerErrors: string;
  Inputs: TStringList;
  InputFiles: TArray<string>;
  FileResults: TArray<TJSONObject>;
  Workers: TArray<TBatchWorker>;
  Worker: TBatchWorker;
  WorkerCount, InputIndex, WorkerIndex, StartedWorkerCount: Integer;
  Summary, Timings, WorkerJson: TJSONObject;
  Files, WorkerStatistics: TJSONArray;
  Statistics: TMGKositStatistics;
  TotalWatch: TStopwatch;
  FirstLoopTicks, LastLoopTicks: Int64;
  InitializationMs, ConfigurationMs, LoopMs, ValidationMs, ReportWriteMs, CleanupMs: Double;
begin
  Result := 0;
  if (ParamCount = 1) and SameText(ParamStr(1), '--help') then
  begin
    WriteLn('MGGMXmlValidatorBatch DLL ValidationRoot InputDirectory OutputDirectory [WorkerCount]');
    WriteLn('WorkerCount: 1 bis 64, Standard 1; höchstens ein Worker je XML-Datei, jeweils mit eigener Validatorinstanz.');
    WriteLn('Schreibt XML-, HTML-Berichte und summary.json in sortierter Dateireihenfolge. OutputDirectory muss neu sein.');
    WriteLn('initialization/configuration/validate_file/report_writes/cleanup sind Worker-Summen; validation_loop und total sind Wandzeiten.');
    WriteLn('Exitcode: Anzahl abgelehnter/fehlerhafter Dateien, technische Fehler: 254.');
    Exit;
  end;
  TotalWatch := TStopwatch.StartNew;
  if (ParamCount <> 4) and (ParamCount <> 5) then
    raise EArgumentException.Create('Aufruf: MGGMXmlValidatorBatch DLL ValidationRoot InputDirectory OutputDirectory [WorkerCount]');
  WorkerCount := 1;
  if ParamCount = 5 then
    if not TryStrToInt(ParamStr(5), WorkerCount) or (WorkerCount < 1) or (WorkerCount > 64) then
      raise EArgumentException.Create('WorkerCount muss eine ganze Zahl zwischen 1 und 64 sein.');
  LibraryFile := ExpandFileName(ParamStr(1));
  ValidationRoot := ExpandFileName(ParamStr(2));
  InputDirectory := ExpandFileName(ParamStr(3));
  OutputDirectory := ExpandFileName(ParamStr(4));
  if not FileExists(LibraryFile) then
    raise EFileNotFoundException.Create('Saxon-DLL fehlt: ' + LibraryFile);
  if not DirectoryExists(InputDirectory) then
    raise EDirectoryNotFoundException.Create('Eingabeverzeichnis fehlt: ' + InputDirectory);
  if FileExists(OutputDirectory) or DirectoryExists(OutputDirectory) then
    raise EArgumentException.Create('Ausgabeziel existiert bereits: ' + OutputDirectory);
  for ScenarioName in ScenarioNames do
  begin
    ScenarioFile := TPath.Combine(ValidationRoot, ScenarioName);
    if not FileExists(ScenarioFile) then
      raise EFileNotFoundException.Create('Szenariokonfiguration fehlt: ' + ScenarioFile);
  end;
  Inputs := TStringList.Create;
  try
    CollectInputs(InputDirectory, Inputs);
    if WorkerCount > Inputs.Count then
      WorkerCount := Inputs.Count;
    SetLength(InputFiles, Inputs.Count);
    SetLength(FileResults, Inputs.Count);
    SetLength(Workers, WorkerCount);
    for InputIndex := 0 to Inputs.Count - 1 do
      InputFiles[InputIndex] := Inputs[InputIndex];
    if not CreateDir(OutputDirectory) then
      RaiseLastOSError;
    Summary := TJSONObject.Create;
    try
      StartedWorkerCount := 0;
      try
        for WorkerIndex := 0 to WorkerCount - 1 do
        begin
          Workers[WorkerIndex] := TBatchWorker.Create(LibraryFile, ValidationRoot, OutputDirectory, InputFiles, FileResults, WorkerIndex, WorkerCount);
          Workers[WorkerIndex].Start;
          Inc(StartedWorkerCount);
        end;
        for Worker in Workers do
          Worker.WaitFor;
        WorkerErrors := '';
        for WorkerIndex := 0 to WorkerCount - 1 do
          if Workers[WorkerIndex].ErrorText <> '' then
          begin
            if WorkerErrors <> '' then
              WorkerErrors := WorkerErrors + sLineBreak;
            WorkerErrors := WorkerErrors + Format('Worker %d: %s', [WorkerIndex + 1, Workers[WorkerIndex].ErrorText]);
          end;
        if WorkerErrors <> '' then
          raise Exception.Create(WorkerErrors);
        Summary.AddPair('input_directory', InputDirectory);
        Summary.AddPair('output_directory', OutputDirectory);
        Summary.AddPair('file_count', TJSONNumber.Create(Inputs.Count));
        Summary.AddPair('worker_count', TJSONNumber.Create(WorkerCount));
        Files := TJSONArray.Create;
        Summary.AddPair('files', Files);
        for InputIndex := 0 to High(FileResults) do
        begin
          if FileResults[InputIndex] = nil then
            raise Exception.CreateFmt('Workerergebnis fehlt für Eingabe %d', [InputIndex]);
          Files.AddElement(FileResults[InputIndex]);
          FileResults[InputIndex] := nil;
        end;
        Statistics := Default(TMGKositStatistics);
        InitializationMs := 0;
        ConfigurationMs := 0;
        ValidationMs := 0;
        ReportWriteMs := 0;
        CleanupMs := 0;
        FirstLoopTicks := High(Int64);
        LastLoopTicks := 0;
        WorkerStatistics := TJSONArray.Create;
        Summary.AddPair('worker_statistics', WorkerStatistics);
        for WorkerIndex := 0 to WorkerCount - 1 do
        begin
          Worker := Workers[WorkerIndex];
          Inc(Result, Worker.RejectedCount);
          AddStatistics(Statistics, Worker.Statistics);
          InitializationMs := InitializationMs + Worker.InitializationMs;
          ConfigurationMs := ConfigurationMs + Worker.ConfigurationMs;
          ValidationMs := ValidationMs + Worker.ValidationMs;
          ReportWriteMs := ReportWriteMs + Worker.ReportWriteMs;
          CleanupMs := CleanupMs + Worker.CleanupMs;
          if Worker.LoopStartedTicks < FirstLoopTicks then
            FirstLoopTicks := Worker.LoopStartedTicks;
          if Worker.LoopFinishedTicks > LastLoopTicks then
            LastLoopTicks := Worker.LoopFinishedTicks;
          WorkerJson := EngineStatisticsJson(Worker.Statistics);
          WorkerStatistics.AddElement(WorkerJson);
          WorkerJson.AddPair('worker_index', TJSONNumber.Create(WorkerIndex + 1));
          WorkerJson.AddPair('thread_id', TJSONNumber.Create(Int64(Worker.ThreadID)));
          WorkerJson.AddPair('processed_file_count', TJSONNumber.Create(Worker.ProcessedCount));
          WorkerJson.AddPair('initialization_ms', TJSONNumber.Create(Worker.InitializationMs));
          WorkerJson.AddPair('configuration_ms', TJSONNumber.Create(Worker.ConfigurationMs));
          WorkerJson.AddPair('validate_file_ms', TJSONNumber.Create(Worker.ValidationMs));
          WorkerJson.AddPair('report_writes_ms', TJSONNumber.Create(Worker.ReportWriteMs));
          WorkerJson.AddPair('cleanup_ms', TJSONNumber.Create(Worker.CleanupMs));
          WorkerJson.AddPair('validation_loop_ms', TJSONNumber.Create((Worker.LoopFinishedTicks - Worker.LoopStartedTicks) * 1000.0 / TStopwatch.Frequency));
        end;
        LoopMs := (LastLoopTicks - FirstLoopTicks) * 1000.0 / TStopwatch.Frequency;
        Summary.AddPair('engine_statistics', EngineStatisticsJson(Statistics));
        Timings := TJSONObject.Create;
        Summary.AddPair('timings_ms', Timings);
        Timings.AddPair('initialization', TJSONNumber.Create(InitializationMs));
        Timings.AddPair('configuration', TJSONNumber.Create(ConfigurationMs));
        Timings.AddPair('validation_loop', TJSONNumber.Create(LoopMs));
        Timings.AddPair('validate_file', TJSONNumber.Create(ValidationMs));
        Timings.AddPair('report_writes', TJSONNumber.Create(ReportWriteMs));
        Timings.AddPair('cleanup', TJSONNumber.Create(CleanupMs));
        Timings.AddPair('total', TJSONNumber.Create(TotalWatch.Elapsed.TotalMilliseconds));
        Summary.AddPair('rejected_or_failed', TJSONNumber.Create(Result));
        // Die Wandzeit endet nach dem Validatorabbau; die Prozessmessung umfasst zusätzlich das Summary-Schreiben.
        WriteNewUtf8File(TPath.Combine(OutputDirectory, 'summary.json'), Summary.ToJSON);
        WriteLn('Dateien: ', Inputs.Count, '; Worker: ', WorkerCount, '; abgelehnt/fehlerhaft: ', Result,
          '; Gesamtzeit inkl. XML/HTML: ', TotalWatch.Elapsed.TotalMilliseconds:0:3, ' ms');
      finally
        // Auch bei einem Hauptthreadfehler müssen alle gestarteten Worker vor der Ergebnisfreigabe enden.
        for WorkerIndex := 0 to High(Workers) do
          if Workers[WorkerIndex] <> nil then
          begin
            if WorkerIndex < StartedWorkerCount then
              Workers[WorkerIndex].WaitFor;
            FreeAndNil(Workers[WorkerIndex]);
          end;
        for InputIndex := 0 to High(FileResults) do
          FreeAndNil(FileResults[InputIndex]);
      end;
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
    ExitCode := RunBatch;
  except
    on Error: Exception do
    begin
      WriteLn(ErrOutput, Error.ClassName, ': ', Error.Message);
      ExitCode := 254;
    end;
  end;
end.
