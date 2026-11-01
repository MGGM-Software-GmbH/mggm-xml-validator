unit MGKositStreamAdapter;

interface

uses
  System.Classes;

function ValidateWithKOSITNative(XmlStream: TMemoryStream; HTMLResult: TMemoryStream;
  var ErrOutput: string; const ValidationBasePath, SaxonLibraryFile: string; const Referenz: string = ''): Char;

implementation

uses
  System.SysUtils, MGKosit;

{ ---------------------------------------------------------------------------
  ValidateWithKOSITNative - Prüft Rechnungsstreams ohne externen Prozess mit
  den drei explizit ausgewählten lokalen Regelkonfigurationen.
  Dateipfade und Berichtserstellung gehören dem gemeinsamen Validator-Kern.
  --------------------------------------------------------------------------- }
function ValidateWithKOSITNative(XmlStream: TMemoryStream; HTMLResult: TMemoryStream;
  var ErrOutput: string; const ValidationBasePath, SaxonLibraryFile: string; const Referenz: string): Char;
var
  Validator: TMGKositValidator;
  Validation: TMGKositValidationResult;
  Finding: TMGKositFinding;
  BasePath: string;
  HtmlBytes: TBytes;
  SavedPosition: Int64;
begin
  Result := 'F';
  ErrOutput := '';
  if HTMLResult <> nil then
    HTMLResult.Clear;
  if (XmlStream = nil) or (XmlStream.Size = 0) then
  begin
    ErrOutput := 'XML-Stream ist leer oder nil';
    Exit;
  end;
  BasePath := IncludeTrailingPathDelimiter(ExpandFileName(ValidationBasePath));
  SavedPosition := XmlStream.Position;
  try
    try
      Validator := TMGKositValidator.Create(SaxonLibraryFile);
      try
        Validator.AddScenario(BasePath + 'validator-configuration-zugferd' + PathDelim + 'scenarios.xml');
        Validator.AddScenario(BasePath + 'validator-configuration-zugferd' + PathDelim + 'scenarios_zugferd1.xml');
        Validator.AddScenario(BasePath + 'validator-configuration-xrechnung' + PathDelim + '3.0.2' + PathDelim + 'scenarios.xml');
        XmlStream.Position := 0;
        Validation := Validator.ValidateStream(XmlStream, Referenz);
        Result := KositStatus(Validation);
        ErrOutput := Validation.ErrorMessage;
        for Finding in Validation.Findings do
          if SameText(Finding.Level, 'warning') or SameText(Finding.Level, 'error') or SameText(Finding.Level, 'fatal') then
          begin
            if ErrOutput <> '' then
              ErrOutput := ErrOutput + sLineBreak;
            ErrOutput := ErrOutput + Finding.Level + ' ' + Finding.Code + ': ' + Finding.Text;
          end;
        if (HTMLResult <> nil) and (Validation.ReportHtml <> '') then
        begin
          HtmlBytes := TEncoding.UTF8.GetBytes(Validation.ReportHtml);
          if Length(HtmlBytes) > 0 then
            HTMLResult.WriteBuffer(HtmlBytes, Length(HtmlBytes));
          HTMLResult.Position := 0;
        end;
      finally
        FreeAndNil(Validator);
      end;
    except
      on Error: Exception do
      begin
        Result := 'F';
        ErrOutput := Error.ClassName + ': ' + Error.Message;
        if HTMLResult <> nil then
          HTMLResult.Clear;
      end;
    end;
  finally
    XmlStream.Position := SavedPosition;
  end;
end;

end.
