@echo off
setlocal
if "%~1"=="" goto usage
if not "%~3"=="" goto usage
if not exist "%~dp0saxonc-core-he.dll" (
  >&2 echo Saxon-DLL fehlt: "%~dp0saxonc-core-he.dll"
  exit /b 3
)
rem Delphi überspringt leere Argumente; ohne Ausgabeziel gelten beide EXE-Standardpfade.
if "%~2"=="" goto defaultoutput
"%~dp0ValidateXmlExample.exe" "%~f1" "%~2" "%~dp0Validation"
exit /b %errorlevel%
:defaultoutput
"%~dp0ValidateXmlExample.exe" "%~f1"
exit /b %errorlevel%
:usage
>&2 echo Aufruf: validate.cmd InputXml [OutputDirectory]
exit /b 2
