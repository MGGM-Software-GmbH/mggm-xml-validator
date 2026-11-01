unit MGKosit;

interface

uses
  MGKositTypes, MGKositValidator;

type
  // Eine öffentliche Unit genügt dem Aufrufer; die Implementierung bleibt nach Aufgaben getrennt.
  TMGKositAcceptance = MGKositTypes.TMGKositAcceptance;
  TMGKositFinding = MGKositTypes.TMGKositFinding;
  TMGKositValidationResult = MGKositTypes.TMGKositValidationResult;
  TMGKositStatistics = MGKositTypes.TMGKositStatistics;
  TMGKositValidator = MGKositValidator.TMGKositValidator;

const
  kaUndefined = MGKositTypes.kaUndefined;
  kaAccept = MGKositTypes.kaAccept;
  kaReject = MGKositTypes.kaReject;

function KositStatus(const Validation: TMGKositValidationResult): Char;

implementation

// Der Statusvertrag bleibt auch beim Zugriff über die Fassade derselbe.
function KositStatus(const Validation: TMGKositValidationResult): Char;
begin
  Result := MGKositTypes.KositStatus(Validation);
end;

end.
