program MGGMXmlValidator;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  uKositCli in 'uKositCli.pas';

begin
  SetTextCodePage(Output, 65001);
  SetTextCodePage(ErrOutput, 65001);
  try
    ExitCode := RunValidatorCli;
  except
    on Error: Exception do
    begin
      WriteLn(ErrOutput, Error.ClassName, ': ', Error.Message);
      ExitCode := 254;
    end;
  end;
end.
