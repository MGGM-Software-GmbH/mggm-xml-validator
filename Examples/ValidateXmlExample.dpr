program ValidateXmlExample;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, Winapi.Windows,
  MGKosit;

type
  EExampleError = class(Exception)
  public
    StatusCode: Integer;
    constructor Create(const MessageText: string; const Code: Integer);
  end;

// Getrennte Exitcodes unterscheiden Aufruf, Laufzeit, Regeln und Berichtsausgabe.
constructor EExampleError.Create(const MessageText: string; const Code: Integer);
begin
  inherited Create(MessageText);
  StatusCode := Code;
end;

// Jeder Lauf erhält einen eigenen Ordner; ein vorhandener Zielordner wird abgelehnt.
function NewOutputDirectory(const RequestedDirectory, ApplicationDirectory, InputFile: string): string;
var
  Identifier: TGUID;
  ParentDirectory: string;
begin
  if RequestedDirectory <> '' then
    Result := ExpandFileName(RequestedDirectory)
  else
  begin
    CreateGUID(Identifier);
    Result := TPath.Combine(ApplicationDirectory, 'Reports' + PathDelim + TPath.GetFileNameWithoutExtension(InputFile) + '-' + GUIDToString(Identifier));
  end;
  ParentDirectory := ExtractFileDir(Result);
  if not DirectoryExists(ParentDirectory) and not ForceDirectories(ParentDirectory) then
    raise EExampleError.Create('Übergeordnetes Ausgabeverzeichnis kann nicht angelegt werden: ' + ParentDirectory, 5);
  if not Winapi.Windows.CreateDirectory(PChar(Result), nil) then
    raise EExampleError.Create('Ausgabeverzeichnis muss neu sein und angelegt werden können: ' + Result + ' (' + SysErrorMessage(GetLastError) + ')', 5);
end;

// Die drei lokalen Konfigurationen decken ZUGFeRD einschließlich 1.x und XRechnung ab.
procedure LoadScenarios(const Validator: TMGKositValidator; const ValidationDirectory: string);
var
  ScenarioFiles: TArray<string>;
  ScenarioFile: string;
begin
  ScenarioFiles := TArray<string>.Create(
    TPath.Combine(ValidationDirectory, 'validator-configuration-zugferd' + PathDelim + 'scenarios.xml'),
    TPath.Combine(ValidationDirectory, 'validator-configuration-zugferd' + PathDelim + 'scenarios_zugferd1.xml'),
    TPath.Combine(ValidationDirectory, 'validator-configuration-xrechnung' + PathDelim + '3.0.2' + PathDelim + 'scenarios.xml'));
  for ScenarioFile in ScenarioFiles do
  begin
    if not FileExists(ScenarioFile) then
      raise EExampleError.Create('Regelkonfiguration fehlt: ' + ScenarioFile, 4);
    Validator.AddScenario(ScenarioFile);
  end;
end;

// Nur MGKosit wird als Bibliotheks-Unit benötigt; XML bleibt während der Prüfung im Speicher.
function ValidateXml: Integer;
var
  ApplicationDirectory, InputFile, ValidationDirectory, OutputDirectory, RequestedOutput: string;
  XmlReportFile, HtmlReportFile: string;
  Validator: TMGKositValidator;
  XmlStream: TMemoryStream;
  Validation: TMGKositValidationResult;
  Finding: TMGKositFinding;
  Status: Char;
begin
  if (ParamCount = 1) and ((ParamStr(1) = '--help') or (ParamStr(1) = '-?')) then
  begin
    WriteLn('Aufruf: ValidateXmlExample InputXml [OutputDirectory] [ValidationDirectory]');
    WriteLn('Ohne OutputDirectory entsteht ein neuer Ordner unter Reports neben der Anwendung.');
    WriteLn('ValidationDirectory ist standardmäßig Validation neben der Anwendung.');
    WriteLn('Exitcodes: 0 angenommen, 1 fachlich abgelehnt, 2 Aufruf/Eingabe, 3 Saxon-DLL, 4 Regeln, 5 Ausgabe, 6 Verarbeitung.');
    Exit(0);
  end;
  if (ParamCount < 1) or (ParamCount > 3) then
    raise EExampleError.Create('Aufruf: ValidateXmlExample InputXml [OutputDirectory] [ValidationDirectory]', 2);
  InputFile := ExpandFileName(ParamStr(1));
  if not FileExists(InputFile) then
    raise EExampleError.Create('XML-Eingabedatei fehlt: ' + InputFile, 2);
  ApplicationDirectory := ExtractFilePath(ExpandFileName(ParamStr(0)));
  ValidationDirectory := TPath.Combine(ApplicationDirectory, 'Validation');
  if (ParamCount >= 3) and (ParamStr(3) <> '') then
    ValidationDirectory := ExpandFileName(ParamStr(3));
  RequestedOutput := '';
  if ParamCount >= 2 then
    RequestedOutput := ParamStr(2);
  XmlStream := TMemoryStream.Create;
  try
    try
      XmlStream.LoadFromFile(InputFile);
    except
      on Error: Exception do
        raise EExampleError.Create('XML-Eingabedatei kann nicht gelesen werden: ' + Error.Message, 2);
    end;
    try
      Validator := TMGKositValidator.Create;
    except
      on Error: Exception do
        raise EExampleError.Create('Saxon-DLL kann nicht initialisiert werden: ' + Error.Message, 3);
    end;
    try
      try
        LoadScenarios(Validator, ValidationDirectory);
      except
        on Error: Exception do
          raise EExampleError.Create('Regelkonfiguration kann nicht geladen werden: ' + Error.Message, 4);
      end;
      XmlStream.Position := 0;
      Validation := Validator.ValidateStream(XmlStream, ExtractFileName(InputFile));
      Status := KositStatus(Validation);
      WriteLn('Status: ', Status);
      WriteLn('Szenario: ', Validation.ScenarioName);
      for Finding in Validation.Findings do
      begin
        WriteLn(Finding.Level, ' ', Finding.Code, ': ', Finding.Text);
        if Finding.Location <> '' then
          WriteLn('  Fundstelle: ', Finding.Location);
      end;
      if Validation.ErrorMessage <> '' then
        WriteLn(ErrOutput, Validation.ErrorMessage);
      if (Validation.ReportXml = '') or (Validation.ReportHtml = '') then
        raise EExampleError.Create('Die Verarbeitung hat keinen XML- und HTML-Bericht erzeugt.', 6);
      try
        OutputDirectory := NewOutputDirectory(RequestedOutput, ApplicationDirectory, InputFile);
        XmlReportFile := TPath.Combine(OutputDirectory, 'report.xml');
        HtmlReportFile := TPath.Combine(OutputDirectory, 'report.html');
        TFile.WriteAllText(XmlReportFile, Validation.ReportXml, TEncoding.UTF8);
        TFile.WriteAllText(HtmlReportFile, Validation.ReportHtml, TEncoding.UTF8);
      except
        on Error: EExampleError do
          raise;
        on Error: Exception do
          raise EExampleError.Create('Berichte können nicht gespeichert werden: ' + Error.Message, 5);
      end;
      WriteLn('XML-Bericht: ', XmlReportFile);
      WriteLn('HTML-Bericht: ', HtmlReportFile);
      case Status of
        'V', 'W': Result := 0;
        'E': Result := 1;
      else
        Result := 6;
      end;
    finally
      FreeAndNil(Validator);
    end;
  finally
    FreeAndNil(XmlStream);
  end;
end;

begin
  SetTextCodePage(Output, 65001);
  SetTextCodePage(ErrOutput, 65001);
  try
    ExitCode := ValidateXml;
  except
    on Error: EExampleError do
    begin
      WriteLn(ErrOutput, Error.Message);
      ExitCode := Error.StatusCode;
    end;
    on Error: Exception do
    begin
      WriteLn(ErrOutput, Error.ClassName, ': ', Error.Message);
      ExitCode := 6;
    end;
  end;
end.
