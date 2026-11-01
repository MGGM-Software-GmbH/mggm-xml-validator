program ParallelEngineTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.SyncObjs, System.Diagnostics,
  System.Hash, System.NetEncoding, System.Win.ComObj, Winapi.Windows, Winapi.MSXML, Winapi.PsAPI,
  MGKosit;

const
  WorkerCount = 2;
  RoundCount = 8;

type
  TValidationWorker = class(TThread)
  private
    FIndex: Integer;
  protected
    procedure Execute; override;
  public
    Failure, InvalidFingerprint: string;
    Results: TJSONArray;
    StartedAt, FinishedAt: array[0..RoundCount - 1] of Int64;
    Statistics: TMGKositStatistics;
    NativeThreadId: DWORD;
    constructor Create(Index: Integer);
    destructor Destroy; override;
  end;

var
  LibraryFile, ValidationRoot, ValidFile, InvalidFile, EvidenceFile, ValidHash, InvalidHash: string;
  Ready: array[0..WorkerCount - 1, 0..RoundCount - 1] of TEvent;
  Gates: array[0..RoundCount - 1] of TEvent;

// Verletzte fachliche oder technische Kriterien führen zu einem fehlgeschlagenen Worker.
procedure Require(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

// Der Hash entsteht unabhängig vom Validator aus den tatsächlichen Eingabebytes.
function InputHash(const FileName: string): string;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    Result := TNetEncoding.Base64.EncodeBytesToString(THashSHA2.GetHashBytes(Stream));
  finally
    FreeAndNil(Stream);
  end;
end;

// COM-Objekte bleiben im Worker; nur der ausgelesene Text verlässt diese Funktion.
function ReportHash(const Xml: string): string;
var
  Document: IXMLDOMDocument3;
  Node: IXMLDOMNode;
begin
  Document := CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
  Document.async := False;
  Document.validateOnParse := False;
  Document.resolveExternals := False;
  Document.setProperty('ProhibitDTD', True);
  Document.setProperty('SelectionLanguage', 'XPath');
  Document.setProperty('SelectionNamespaces', 'xmlns:in="http://www.xoev.de/de/validator/framework/1/createreportinput"');
  Require(Boolean(Document.loadXML(Xml)), 'Bericht ist kein gültiges XML');
  Node := Document.selectSingleNode('/in:createReportInput/in:documentIdentification/in:documentHash/in:hashValue');
  Require(Node <> nil, 'Dokumenthash fehlt im Bericht');
  Result := Node.text;
end;

// Die Daten werden vor Threadstart angelegt und anschließend nur vom Worker geändert.
constructor TValidationWorker.Create(Index: Integer);
begin
  inherited Create(True);
  FIndex := Index;
  Results := TJSONArray.Create;
end;

// Das Hauptprogramm wartet vor Freigabe auf das Ende der tatsächlichen Worker-Ausführung.
destructor TValidationWorker.Destroy;
begin
  FreeAndNil(Results);
  inherited Destroy;
end;

// Jeder Thread erzeugt und zerstört seinen eigenen Validator einschließlich Isolate und COM.
procedure TValidationWorker.Execute;
var
  Validator: TMGKositValidator;
  Validation: TMGKositValidationResult;
  Finding: TMGKositFinding;
  RoundIndex: Integer;
  InputFile, ExpectedHash, ActualHash, Reference, Fingerprint: string;
  ExpectedStatus: Char;
  Item: TJSONObject;
begin
  NativeThreadId := GetCurrentThreadId;
  try
    Validator := TMGKositValidator.Create(LibraryFile);
    try
      Validator.AddScenario(TPath.Combine(ValidationRoot, 'validator-configuration-zugferd\scenarios.xml'));
      Validator.AddScenario(TPath.Combine(ValidationRoot, 'validator-configuration-zugferd\scenarios_zugferd1.xml'));
      Validator.AddScenario(TPath.Combine(ValidationRoot, 'validator-configuration-xrechnung\3.0.2\scenarios.xml'));
      for RoundIndex := 0 to RoundCount - 1 do
      begin
        // Gegensätzliche Dokumente decken auch eine unzulässige threadübergreifende Quelle auf.
        if Odd(RoundIndex + FIndex) then
        begin
          InputFile := InvalidFile;
          ExpectedHash := InvalidHash;
          ExpectedStatus := 'E';
        end
        else
        begin
          InputFile := ValidFile;
          ExpectedHash := ValidHash;
          ExpectedStatus := 'V';
        end;
        Reference := Format('Worker-%d-Runde-%d.xml', [FIndex, RoundIndex]);
        Ready[FIndex, RoundIndex].SetEvent;
        Require(Gates[RoundIndex].WaitFor(15000) = wrSignaled, 'Startbarriere wurde nicht freigegeben');
        StartedAt[RoundIndex] := TStopwatch.GetTimeStamp;
        Validation := Validator.ValidateFile(InputFile, Reference);
        FinishedAt[RoundIndex] := TStopwatch.GetTimeStamp;
        Require(not Validation.ProcessingError, Validation.ErrorMessage);
        Require(KositStatus(Validation) = ExpectedStatus, 'Falscher fachlicher Status');
        Require(Validation.DocumentReference = Reference, 'Fremde Dokumentreferenz');
        ActualHash := ReportHash(Validation.ReportInputXml);
        Require(ActualHash = ExpectedHash, 'Veralteter oder fremder Dokumenthash');
        Require((Validation.ReportXml <> '') and (Validation.ReportHtml <> ''), 'Bericht fehlt');
        Fingerprint := '';
        for Finding in Validation.Findings do
          Fingerprint := Fingerprint + Finding.Level + #9 + Finding.Code + #9 + Finding.Text + #9 + Finding.Location + #9 + Finding.ValidationStep + #10;
        if ExpectedStatus = 'V' then
          Require((Validation.Errors = 0) and (Validation.Warnings = 0) and (Length(Validation.Findings) = 0), 'Befunde der vorigen ungültigen Eingabe geblieben')
        else
        begin
          Require((Validation.Errors > 0) and (Fingerprint <> ''), 'Ungültige Eingabe ohne Fehlerbefunde');
          if InvalidFingerprint = '' then
            InvalidFingerprint := Fingerprint
          else
            Require(InvalidFingerprint = Fingerprint, 'Fehlerbefunde ändern sich zwischen identischen Eingaben');
        end;
        Item := TJSONObject.Create;
        Item.AddPair('round', TJSONNumber.Create(RoundIndex));
        Item.AddPair('status', string(ExpectedStatus));
        Item.AddPair('input_hash', ActualHash);
        Item.AddPair('errors', TJSONNumber.Create(Validation.Errors));
        Item.AddPair('started_at_ticks', TJSONNumber.Create(StartedAt[RoundIndex]));
        Item.AddPair('finished_at_ticks', TJSONNumber.Create(FinishedAt[RoundIndex]));
        Item.AddPair('duration_ticks', TJSONNumber.Create(FinishedAt[RoundIndex] - StartedAt[RoundIndex]));
        Item.AddPair('duration_ms', TJSONNumber.Create((FinishedAt[RoundIndex] - StartedAt[RoundIndex]) * 1000.0 / TStopwatch.Frequency));
        Results.AddElement(Item);
      end;
      Statistics := Validator.Statistics;
    finally
      FreeAndNil(Validator);
    end;
  except
    on Error: Exception do
      Failure := Error.ClassName + ': ' + Error.Message;
  end;
  // Ein fehlgeschlagener Worker darf den anderen Worker nicht an der Barriere festhalten.
  for RoundIndex := 0 to RoundCount - 1 do
    Ready[FIndex, RoundIndex].SetEvent;
end;

// Das gemeinsame Gate startet jeden Aufruf erst, wenn beide eigenen Instanzen vorhanden sind.
procedure Run;
var
  Workers: array[0..WorkerCount - 1] of TValidationWorker;
  WorkerIndex, RoundIndex, PassedCalls, OverlapCount: Integer;
  StartTick, Deadline: UInt64;
  LaterStart, EarlierEnd: Int64;
  Evidence, WorkerResult, RoundResult: TJSONObject;
  WorkerResults, RoundResults: TJSONArray;
  Memory: PROCESS_MEMORY_COUNTERS;
  Passed: Boolean;
begin
  Require(ParamCount = 5, 'Aufruf: ParallelEngineTests LibraryFile ValidationRoot ValidXml InvalidXml EvidenceJson');
  LibraryFile := ExpandFileName(ParamStr(1));
  ValidationRoot := ExpandFileName(ParamStr(2));
  ValidFile := ExpandFileName(ParamStr(3));
  InvalidFile := ExpandFileName(ParamStr(4));
  EvidenceFile := ExpandFileName(ParamStr(5));
  ValidHash := InputHash(ValidFile);
  InvalidHash := InputHash(InvalidFile);
  Require(ValidHash <> InvalidHash, 'Gegenproben benötigen unterschiedliche Eingaben');
  for RoundIndex := 0 to RoundCount - 1 do
  begin
    Gates[RoundIndex] := TEvent.Create(nil, True, False, '');
    for WorkerIndex := 0 to WorkerCount - 1 do
      Ready[WorkerIndex, RoundIndex] := TEvent.Create(nil, True, False, '');
  end;
  for WorkerIndex := 0 to WorkerCount - 1 do
    Workers[WorkerIndex] := TValidationWorker.Create(WorkerIndex);
  Evidence := TJSONObject.Create;
  try
    StartTick := GetTickCount64;
    Deadline := StartTick + 15000;
    for WorkerIndex := 0 to WorkerCount - 1 do
      Workers[WorkerIndex].Start;
    try
      for RoundIndex := 0 to RoundCount - 1 do
      begin
        for WorkerIndex := 0 to WorkerCount - 1 do
        begin
          Require(GetTickCount64 < Deadline, 'Gesamtzeitlimit der Barriere überschritten');
          Require(Ready[WorkerIndex, RoundIndex].WaitFor(Deadline - GetTickCount64) = wrSignaled, 'Worker erreicht Barriere nicht');
        end;
        Gates[RoundIndex].SetEvent;
      end;
    finally
      for RoundIndex := 0 to RoundCount - 1 do
        Gates[RoundIndex].SetEvent;
      for WorkerIndex := 0 to WorkerCount - 1 do
        Workers[WorkerIndex].WaitFor;
    end;
    PassedCalls := 0;
    Passed := True;
    WorkerResults := TJSONArray.Create;
    Evidence.AddPair('workers', WorkerResults);
    for WorkerIndex := 0 to WorkerCount - 1 do
    begin
      Inc(PassedCalls, Workers[WorkerIndex].Results.Count);
      Passed := Passed and (Workers[WorkerIndex].Failure = '') and (Workers[WorkerIndex].Results.Count = RoundCount);
      WorkerResult := TJSONObject.Create;
      WorkerResult.AddPair('thread_id', TJSONNumber.Create(Workers[WorkerIndex].NativeThreadId));
      WorkerResult.AddPair('failure', Workers[WorkerIndex].Failure);
      WorkerResult.AddPair('calls', Workers[WorkerIndex].Results.Clone as TJSONArray);
      WorkerResult.AddPair('source_parse_count', TJSONNumber.Create(Workers[WorkerIndex].Statistics.SourceParseCount));
      WorkerResult.AddPair('stylesheet_compilation_count', TJSONNumber.Create(Workers[WorkerIndex].Statistics.StylesheetCompilationCount));
      WorkerResults.AddElement(WorkerResult);
    end;
    OverlapCount := 0;
    Evidence.AddPair('timestamp_frequency_hz', TJSONNumber.Create(TStopwatch.Frequency));
    RoundResults := TJSONArray.Create;
    Evidence.AddPair('round_intervals', RoundResults);
    for RoundIndex := 0 to RoundCount - 1 do
    begin
      LaterStart := Workers[0].StartedAt[RoundIndex];
      if Workers[1].StartedAt[RoundIndex] > LaterStart then LaterStart := Workers[1].StartedAt[RoundIndex];
      EarlierEnd := Workers[0].FinishedAt[RoundIndex];
      if Workers[1].FinishedAt[RoundIndex] < EarlierEnd then EarlierEnd := Workers[1].FinishedAt[RoundIndex];
      if (LaterStart > 0) and (LaterStart < EarlierEnd) then Inc(OverlapCount);
      RoundResult := TJSONObject.Create;
      RoundResult.AddPair('round', TJSONNumber.Create(RoundIndex));
      RoundResult.AddPair('later_start_ticks', TJSONNumber.Create(LaterStart));
      RoundResult.AddPair('earlier_end_ticks', TJSONNumber.Create(EarlierEnd));
      RoundResult.AddPair('overlapping', TJSONBool.Create((LaterStart > 0) and (LaterStart < EarlierEnd)));
      RoundResults.AddElement(RoundResult);
    end;
    Passed := Passed and (OverlapCount = RoundCount) and (Workers[0].InvalidFingerprint = Workers[1].InvalidFingerprint);
    Passed := Passed and (Workers[0].NativeThreadId <> Workers[1].NativeThreadId);
    Evidence.AddPair('passed', TJSONBool.Create(Passed));
    Evidence.AddPair('passed_calls', TJSONNumber.Create(PassedCalls));
    Evidence.AddPair('overlapping_rounds', TJSONNumber.Create(OverlapCount));
    Evidence.AddPair('duration_ms', TJSONNumber.Create(Int64(GetTickCount64 - StartTick)));
    FillChar(Memory, SizeOf(Memory), 0);
    Memory.cb := SizeOf(Memory);
    if GetProcessMemoryInfo(GetCurrentProcess, @Memory, SizeOf(Memory)) then
      Evidence.AddPair('peak_working_set_bytes', TJSONNumber.Create(Int64(Memory.PeakWorkingSetSize)));
    ForceDirectories(ExtractFileDir(EvidenceFile));
    TFile.WriteAllText(EvidenceFile, Evidence.ToJSON, TEncoding.UTF8);
    WriteLn('Passed calls: ', PassedCalls, '/16; overlapping rounds: ', OverlapCount, '/8; passed: ', BoolToStr(Passed, True));
    if Passed then ExitCode := 0;
  finally
    FreeAndNil(Evidence);
    for WorkerIndex := 0 to WorkerCount - 1 do
      FreeAndNil(Workers[WorkerIndex]);
    for RoundIndex := 0 to RoundCount - 1 do
    begin
      FreeAndNil(Gates[RoundIndex]);
      for WorkerIndex := 0 to WorkerCount - 1 do
        FreeAndNil(Ready[WorkerIndex, RoundIndex]);
    end;
  end;
end;

begin
  SetTextCodePage(Output, CP_UTF8);
  ExitCode := 1;
  try
    Run;
  except
    on Error: Exception do WriteLn(Error.ClassName, ': ', Error.Message);
  end;
end.
