program EngineTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.StrUtils, System.RegularExpressions,
  Winapi.Windows, Winapi.MSXML, MGKositEngine, MGKositNative;

type
  // Jeder Fall schreibt sein tatsächliches Ergebnis einschließlich der Engine-Diagnose.
  TEngineTestSuite = class
  private
    FEngine: TMGKositEngine;
    FFixtures, FValidationRoot, FEvidenceFile, FInvoiceFile, FOutputFile: string;
    FEvidence: TJSONObject;
    FCases: TJSONArray;
    FPassed, FFailed: Integer;
    FDiagnostic: string;
    function Fixture(const FileName: string): string;
    procedure Require(const Condition: Boolean; const MessageText: string);
    procedure RunCase(const Name: string; const Action: TProc);
    procedure RequireNativeFailure(const Action: TProc; const DiagnosticTokens: array of string);
    procedure RequireEngineFailure(const Action: TProc; const Tokens: array of string);
    procedure CheckSchema(const InstanceFile: string; const SchemaFiles: TArray<string>; const ExpectedValid: Boolean);
    procedure CheckForeignThread;
    procedure CheckSchemaReuse;
    procedure CheckLongPaths;
    procedure CheckSchemaRedefinition;
    procedure CheckResolverContracts;
    procedure CheckByteStylesheetContracts;
    procedure ExecuteCases;
  public
    constructor Create(const EvidenceFile, FixtureRoot: string);
    destructor Destroy; override;
    function Execute(const LibraryFile, ValidationRoot, InvoiceFile: string): Integer;
  end;

// Die Fixture-Struktur liegt neben dem Projekt und eine Ebene über dem normalen Testausgabeverzeichnis.
// Ein ausdrücklicher Pfad hält compilerabhängige Ausgabeordner von der Testdatenablage unabhängig.
constructor TEngineTestSuite.Create(const EvidenceFile, FixtureRoot: string);
begin
  inherited Create;
  FEvidenceFile := ExpandFileName(EvidenceFile);
  if FixtureRoot <> '' then
    FFixtures := ExpandFileName(FixtureRoot)
  else
    FFixtures := ExpandFileName(TPath.Combine(ExtractFilePath(ParamStr(0)), '..\Fixtures'));
  FOutputFile := TPath.Combine(ExtractFileDir(FEvidenceFile), 'EngineTests-transform.xml');
  FEvidence := TJSONObject.Create;
  FCases := TJSONArray.Create;
  FEvidence.AddPair('tests', FCases);
end;

// Die Engine wird im erzeugenden Thread freigegeben; JSON besitzt das Ergebnisarray.
destructor TEngineTestSuite.Destroy;
begin
  try
    FreeAndNil(FEngine);
  finally
    FreeAndNil(FEvidence);
    inherited Destroy;
  end;
end;

// Fixture-Pfade sind ausschließlich lokale Bestandteile der versionierten Testsuite.
function TEngineTestSuite.Fixture(const FileName: string): string;
begin
  Result := TPath.Combine(FFixtures, FileName);
end;

// Ein verletztes Prüfkriterium wird als fehlgeschlagener Testfall protokolliert.
procedure TEngineTestSuite.Require(const Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

// Ein Fehler in einem Fall darf die unabhängigen Gegenproben nicht unterdrücken.
procedure TEngineTestSuite.RunCase(const Name: string; const Action: TProc);
var
  CaseEvidence: TJSONObject;
  Passed: Boolean;
begin
  FDiagnostic := '';
  Passed := False;
  try
    Action();
    Passed := True;
    Inc(FPassed);
  except
    on Error: Exception do
    begin
      Inc(FFailed);
      FDiagnostic := Error.ClassName + ': ' + Error.Message;
    end;
  end;
  CaseEvidence := TJSONObject.Create;
  CaseEvidence.AddPair('name', Name);
  CaseEvidence.AddPair('passed', TJSONBool.Create(Passed));
  CaseEvidence.AddPair('diagnostic', FDiagnostic);
  FCases.AddElement(CaseEvidence);
  WriteLn(Name, ': ', BoolToStr(Passed, True), ' ', FDiagnostic);
end;

// Nur die erwartete Native-Diagnose zählt; ein Verbindungsfehler ist kein Protokollverbot.
procedure TEngineTestSuite.RequireNativeFailure(const Action: TProc; const DiagnosticTokens: array of string);
var
  ErrorText, Token: string;
  Rejected: Boolean;
begin
  Rejected := False;
  try
    Action();
  except
    on Error: EMGKositNative do
    begin
      Rejected := True;
      ErrorText := Error.Message;
    end;
  end;
  Require(Rejected, 'Der erwartete Native-Fehler wurde nicht ausgelöst.');
  for Token in DiagnosticTokens do
    Require(ContainsText(ErrorText, Token), 'Die Native-Diagnose enthält den erwarteten Begriff "' + Token + '" nicht: ' + ErrorText);
  FDiagnostic := ErrorText;
  // Dieselbe Engine muss nach einem Fehler wieder einen gültigen XPath auswerten können.
  Require(FEngine.EvaluateBoolean(Fixture('base.xml'), '/root = "ok"', nil), 'Gültiger XPath nach Native-Fehler lieferte False.');
end;

// Gültige und ungültige Instanzen prüfen, ob der Cache tatsächlich die Schemaeinschränkung verwendet.
procedure TEngineTestSuite.CheckSchema(const InstanceFile: string; const SchemaFiles: TArray<string>; const ExpectedValid: Boolean);
var
  Diagnostic: string;
  Valid: Boolean;
begin
  Valid := FEngine.ValidateSchemas(InstanceFile, SchemaFiles, Diagnostic);
  Require(Valid = ExpectedValid, Format('XSD-Ergebnis %s statt %s: %s', [BoolToStr(Valid, True), BoolToStr(ExpectedValid, True), Diagnostic]));
  if not ExpectedValid then
    Require(Diagnostic <> '', 'Eine ungültige Instanz benötigt eine Diagnose.');
  FDiagnostic := Diagnostic;
end;

// Der Worker verwendet nur Version; die Owner-Prüfung muss vor dem Native-Aufruf greifen.
procedure TEngineTestSuite.CheckForeignThread;
var
  Worker: TThread;
  WorkerError: string;
  Rejected: Boolean;
begin
  Rejected := False;
  WorkerError := '';
  Worker := TThread.CreateAnonymousThread(
    procedure
    begin
      try
        FEngine.Version;
      except
        on Error: EMGKositEngine do
        begin
          Rejected := True;
          WorkerError := Error.Message;
        end;
        on Error: Exception do
          WorkerError := Error.ClassName + ': ' + Error.Message;
      end;
    end);
  try
    Worker.FreeOnTerminate := False;
    Worker.Start;
    Worker.WaitFor;
    Require(Rejected and ContainsText(WorkerError, 'anderen Thread'), 'Fremdthread wurde nicht durch die Owner-Prüfung abgewiesen: ' + WorkerError);
    Require(FEngine.Version <> '', 'Die Owner-Engine ist nach dem Fremdthread-Test nicht verwendbar.');
    FDiagnostic := WorkerError;
  finally
    FreeAndNil(Worker);
  end;
end;

// Wechselnde Instanzen dürfen den kompilierten Schemacache weder verändern noch umgehen.
procedure TEngineTestSuite.CheckSchemaReuse;
var
  CompilationCount: Integer;
  Rejected: Boolean;
  RepairFile, Diagnostic: string;
begin
  RunCase('schema-cache-valid-invalid-valid-without-recompile',
    procedure
    begin
      CheckSchema(Fixture('local.xml'), [Fixture('local.xsd')], True);
      CompilationCount := FEngine.Statistics.SchemaCompilationCount;
      CheckSchema(Fixture('local-invalid.xml'), [Fixture('local.xsd')], False);
      CheckSchema(Fixture('local.xml'), [Fixture('local.xsd')], True);
      Require(FEngine.Statistics.SchemaCompilationCount = CompilationCount, 'Das unveränderte Schema wurde erneut kompiliert.');
    end);
  RunCase('schema-cache-ordered-multiple-sources-use-distinct-entries',
    procedure
    begin
      // Beide Reihenfolgen starten ohne Cacheeintrag aus den vorherigen Schemafällen.
      FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures]);
      CompilationCount := FEngine.Statistics.SchemaCompilationCount;
      CheckSchema(Fixture('first.xml'), [Fixture('first.xsd'), Fixture('second.xsd')], True);
      CheckSchema(Fixture('second.xml'), [Fixture('first.xsd'), Fixture('second.xsd')], True);
      Require(FEngine.Statistics.SchemaCompilationCount = CompilationCount + 1, 'Die erste Quellenreihenfolge wurde nicht genau einmal kompiliert.');
      CheckSchema(Fixture('first.xml'), [Fixture('second.xsd'), Fixture('first.xsd')], True);
      CheckSchema(Fixture('second.xml'), [Fixture('second.xsd'), Fixture('first.xsd')], True);
      Require(FEngine.Statistics.SchemaCompilationCount = CompilationCount + 2, 'Die umgekehrte Quellenreihenfolge verwendet denselben Cacheeintrag.');
      CheckSchema(Fixture('second-invalid.xml'), [Fixture('first.xsd'), Fixture('second.xsd')], False);
      CheckSchema(Fixture('first.xml'), [Fixture('first.xsd'), Fixture('second.xsd')], True);
      Require(FEngine.Statistics.SchemaCompilationCount = CompilationCount + 2, 'Die erste Quellenreihenfolge wurde beim Wiederverwenden erneut kompiliert.');
    end);
  RunCase('schema-cache-resource-revocation-and-rebuild',
    procedure
    begin
      CompilationCount := FEngine.Statistics.SchemaCompilationCount;
      FEngine.ConfigureResourceRoots([FValidationRoot]);
      try
        Rejected := False;
        try
          FEngine.ValidateSchemas(Fixture('local.xml'), [Fixture('local.xsd')], Diagnostic);
        except
          on Error: EMGKositEngine do
            Rejected := ContainsText(Error.Message, 'außerhalb');
        end;
        Require(Rejected, 'Der Schemacache hat eine entzogene Ressourcenfreigabe weiterverwendet.');
      finally
        FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures]);
      end;
      CheckSchema(Fixture('local.xml'), [Fixture('local.xsd')], True);
      Require(FEngine.Statistics.SchemaCompilationCount = CompilationCount + 1, 'Das freigegebene Schema wurde nicht neu kompiliert.');
    end);
  RunCase('failed-schema-is-not-cached-and-can-be-repaired',
    procedure
    begin
      RepairFile := TPath.Combine(ExtractFileDir(FEvidenceFile), 'EngineTests-repair.xsd');
      FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures, ExtractFileDir(FEvidenceFile)]);
      try
        CompilationCount := FEngine.Statistics.SchemaCompilationCount;
        TFile.WriteAllText(RepairFile, '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:element name="first" type="xs:unknown"/></xs:schema>', TEncoding.UTF8);
        Rejected := False;
        try
          FEngine.ValidateSchemas(Fixture('first.xml'), [RepairFile], Diagnostic);
        except
          on Error: Exception do
            Rejected := True;
        end;
        Require(Rejected, 'Das fehlerhafte Schema wurde nicht als technischer Fehler gemeldet.');
        Require(FEngine.Statistics.SchemaCompilationCount = CompilationCount, 'Das fehlerhafte Schema wurde als Kompilierung gespeichert.');
        TFile.WriteAllText(RepairFile, TFile.ReadAllText(Fixture('first.xsd'), TEncoding.UTF8), TEncoding.UTF8);
        CheckSchema(Fixture('first.xml'), [RepairFile], True);
        Require(FEngine.Statistics.SchemaCompilationCount = CompilationCount + 1, 'Das reparierte Schema wurde nicht kompiliert.');
      finally
        FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures]);
      end;
    end);
end;

// Lokale Langpfade müssen ohne Prozessmanifest und ohne verkürzte Kopie ihre Importe behalten.
procedure TEngineTestSuite.CheckLongPaths;
const
  SchemaHeader = '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"';
  LongNamespace = 'urn:mggm:kosit:test:long';
var
  LongDirectory, OutsideDirectory, MainSchema, EscapingSchema, ValidFile, InvalidFile, Diagnostic: string;
  AdoptedValidFile, AdoptedInvalidFile, RedefineSchema, RedefineValidFile, RedefineInvalidFile: string;
  Document: IXMLDOMDocument3;
  Bytes: TBytes;
  Rejected: Boolean;
begin
  LongDirectory := TPath.Combine(ExtractFileDir(FEvidenceFile), 'long-path-' + StringOfChar('a', 110));
  LongDirectory := TPath.Combine(LongDirectory, 'schema-and-instance-' + StringOfChar('b', 110));
  LongDirectory := TPath.Combine(LongDirectory, 'Regeln mit Leerzeichen');
  OutsideDirectory := LongDirectory + '-outside';
  MainSchema := TPath.Combine(LongDirectory, 'main.xsd');
  EscapingSchema := TPath.Combine(LongDirectory, 'escaping.xsd');
  ValidFile := TPath.Combine(LongDirectory, 'valid.xml');
  InvalidFile := TPath.Combine(LongDirectory, 'invalid.xml');
  AdoptedValidFile := TPath.Combine(LongDirectory, 'adopted-valid.xml');
  AdoptedInvalidFile := TPath.Combine(LongDirectory, 'adopted-invalid.xml');
  RedefineSchema := TPath.Combine(LongDirectory, 'redefine.xsd');
  RedefineValidFile := TPath.Combine(LongDirectory, 'redefine-valid.xml');
  RedefineInvalidFile := TPath.Combine(LongDirectory, 'redefine-invalid.xml');
  RunCase('long-path-fixtures-and-byte-reading',
    procedure
    begin
      Require(Length(MainSchema) > MAX_PATH, 'Die Gegenprobe benötigt einen Pfad mit mehr als 260 Zeichen.');
      Require(ForceDirectories('\\?\' + TPath.Combine(LongDirectory, 'parts')), 'Langpfad-Testverzeichnis kann nicht angelegt werden.');
      Require(ForceDirectories('\\?\' + OutsideDirectory), 'Externes Langpfad-Testverzeichnis kann nicht angelegt werden.');
      TFile.WriteAllText('\\?\' + MainSchema, SchemaHeader + ' xmlns:types="urn:mggm:kosit:test:long:types" targetNamespace="' + LongNamespace + '">' +
        '<xs:import namespace="urn:mggm:kosit:test:long:types" schemaLocation="parts/types.xsd"/>' +
        '<xs:include schemaLocation="parts/elements.xsd"/><xs:include schemaLocation="shared.xsd"/>' +
        '<xs:include schemaLocation="parts/chameleon.xsd"/><xs:element name="code" type="types:Code"/></xs:schema>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + TPath.Combine(LongDirectory, 'parts\types.xsd'), SchemaHeader + ' targetNamespace="urn:mggm:kosit:test:long:types">' +
        '<xs:simpleType name="Code"><xs:restriction base="xs:string"><xs:pattern value="[A-Z]{2}"/></xs:restriction></xs:simpleType></xs:schema>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + TPath.Combine(LongDirectory, 'parts\elements.xsd'), SchemaHeader + ' targetNamespace="' + LongNamespace + '">' +
        '<xs:include schemaLocation="../shared.xsd"/><xs:element name="included" type="xs:integer"/></xs:schema>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + TPath.Combine(LongDirectory, 'shared.xsd'), SchemaHeader + ' targetNamespace="' + LongNamespace + '">' +
        '<xs:simpleType name="Shared"><xs:restriction base="xs:integer"/></xs:simpleType></xs:schema>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + TPath.Combine(LongDirectory, 'parts\chameleon.xsd'), SchemaHeader + '>' +
        '<xs:simpleType name="AdoptedCode"><xs:restriction base="xs:string"><xs:enumeration value="OK"/></xs:restriction></xs:simpleType>' +
        '<xs:element name="adopted" type="AdoptedCode"/></xs:schema>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + ValidFile, '<code xmlns="' + LongNamespace + '">AB</code>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + InvalidFile, '<code xmlns="' + LongNamespace + '">123</code>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + AdoptedValidFile, '<adopted xmlns="' + LongNamespace + '">OK</adopted>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + AdoptedInvalidFile, '<adopted xmlns="' + LongNamespace + '">NO</adopted>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + TPath.Combine(LongDirectory, 'parts\before-redefine.xsd'), SchemaHeader + ' xmlns:local="' + LongNamespace +
        '" targetNamespace="' + LongNamespace + '"><xs:simpleType name="RedefinedCode"><xs:restriction base="xs:string"/></xs:simpleType>' +
        '<xs:element name="redefined" type="local:RedefinedCode"/></xs:schema>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + RedefineSchema, SchemaHeader + ' xmlns:local="' + LongNamespace + '" targetNamespace="' + LongNamespace + '">' +
        '<xs:redefine schemaLocation="parts/before-redefine.xsd"><xs:simpleType name="RedefinedCode"><xs:restriction base="local:RedefinedCode">' +
        '<xs:enumeration value="YES"/></xs:restriction></xs:simpleType></xs:redefine></xs:schema>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + RedefineValidFile, '<redefined xmlns="' + LongNamespace + '">YES</redefined>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + RedefineInvalidFile, '<redefined xmlns="' + LongNamespace + '">NO</redefined>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + TPath.Combine(OutsideDirectory, 'outside.xsd'), SchemaHeader + ' targetNamespace="urn:mggm:kosit:test:outside"/>', TEncoding.UTF8);
      TFile.WriteAllText('\\?\' + EscapingSchema, SchemaHeader + ' targetNamespace="' + LongNamespace + '">' +
        '<xs:import namespace="urn:mggm:kosit:test:outside" schemaLocation="../Regeln mit Leerzeichen-outside/outside.xsd"/></xs:schema>', TEncoding.UTF8);
      Bytes := FEngine.ReadFileBytes(ValidFile);
      Require(Length(Bytes) > 0, 'Der Byte-Lader hat die Langpfad-Instanz nicht eingelesen.');
      FDiagnostic := MainSchema + ' (' + IntToStr(Length(MainSchema)) + ' Zeichen)';
    end);
  FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures, LongDirectory]);
  try
    RunCase('long-path-msxml-document-load',
      procedure
      begin
        Document := FEngine.LoadDocument(ValidFile);
        Require(Document.documentElement.text = 'AB', 'Die Langpfad-XML-Datei wurde nicht unverändert geladen.');
        Document := nil;
      end);
    RunCase('long-path-schema-import-and-include-valid',
      procedure
      begin
        CheckSchema(ValidFile, [MainSchema], True);
      end);
    RunCase('long-path-schema-import-type-enforced',
      procedure
      begin
        CheckSchema(InvalidFile, [MainSchema], False);
      end);
    RunCase('long-path-schema-memory-instance-valid',
      procedure
      begin
        Document := FEngine.LoadDocumentBytes(Bytes, ValidFile);
        Require(FEngine.ValidateDocumentSchemas(Document, [MainSchema], Diagnostic), 'Die Speicherinstanz verletzt das Langpfad-Schema: ' + Diagnostic);
        Document := nil;
      end);
    RunCase('long-path-chameleon-include-valid',
      procedure
      begin
        CheckSchema(AdoptedValidFile, [MainSchema], True);
      end);
    RunCase('long-path-chameleon-include-constraint-enforced',
      procedure
      begin
        CheckSchema(AdoptedInvalidFile, [MainSchema], False);
      end);
    RunCase('long-path-redefine-valid',
      procedure
      begin
        CheckSchema(RedefineValidFile, [RedefineSchema], True);
      end);
    RunCase('long-path-redefine-constraint-enforced',
      procedure
      begin
        CheckSchema(RedefineInvalidFile, [RedefineSchema], False);
      end);
    RunCase('long-path-schema-import-root-escape-rejected',
      procedure
      begin
        Rejected := False;
        try
          FEngine.ValidateSchemas(ValidFile, [EscapingSchema], Diagnostic);
        except
          on Error: EMGKositEngine do Rejected := ContainsText(Error.Message, 'außerhalb');
        end;
        Require(Rejected, 'Ein Langpfad-Import hat die freigegebene Verzeichnisgrenze verlassen.');
      end);
    RunCase('unc-resource-root-rejected',
      procedure
      begin
        Rejected := False;
        try
          FEngine.ConfigureResourceRoots(['\\server\share\rules']);
        except
          on Error: EMGKositEngine do Rejected := ContainsText(Error.Message, 'Netzwerkpfade');
        end;
        Require(Rejected, 'UNC wurde nicht vor einem Netzwerkzugriff als unzulässiger Pfad abgewiesen.');
      end);
  finally
    Document := nil;
    FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures]);
  end;
end;

// Die Neudefinition erhält Namespace-Sichtbarkeit und getrennte XSD-Komponentenarten.
procedure TEngineTestSuite.CheckSchemaRedefinition;
const
  SchemaHeader = '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"';
  TargetNamespace = 'urn:mggm:kosit:test:redefinition';
var
  DirectoryName, BaseSchema, RedefinedSchema, ValidXml, InvalidXml, NamespaceHeader, CaseName: string;
  SchemaFile, ValidFile, InvalidFile: string;
  CaseIndex: Integer;
begin
  DirectoryName := TPath.Combine(ExtractFileDir(FEvidenceFile), 'schema-redefinition');
  ForceDirectories(TPath.Combine(DirectoryName, 'parts'));
  NamespaceHeader := SchemaHeader + ' xmlns:t="' + TargetNamespace + '" targetNamespace="' + TargetNamespace + '" elementFormDefault="qualified">';
  FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures, DirectoryName]);
  try
    for CaseIndex := 0 to 3 do
    begin
      case CaseIndex of
        0: begin
          CaseName := 'redefine-empty-namespace';
          BaseSchema := SchemaHeader + '><xs:simpleType name="Code"><xs:restriction base="xs:string"/></xs:simpleType>' +
            '<xs:element name="value" type="Code"/></xs:schema>';
          RedefinedSchema := SchemaHeader + '><xs:redefine schemaLocation="parts/base-0.xsd">' +
            '<xs:simpleType name="Code"><xs:restriction base="Code"><xs:enumeration value="YES"/></xs:restriction></xs:simpleType>' +
            '</xs:redefine></xs:schema>';
          ValidXml := '<value>YES</value>';
          InvalidXml := '<value>NO</value>';
        end;
        1: begin
          CaseName := 'redefine-local-namespace-binding';
          BaseSchema := NamespaceHeader + '<xs:complexType name="Code"><xs:sequence><xs:element name="before" type="xs:string"/></xs:sequence></xs:complexType>' +
            '<xs:simpleType name="Other"><xs:restriction base="xs:string"><xs:enumeration value="YES"/></xs:restriction></xs:simpleType>' +
            '<xs:element name="value" type="t:Code"/></xs:schema>';
          RedefinedSchema := NamespaceHeader + '<xs:redefine xmlns:p="' + TargetNamespace + '" schemaLocation="parts/base-1.xsd">' +
            '<xs:complexType name="Code"><xs:complexContent><xs:extension base="p:Code"><xs:sequence><xs:element name="after" type="p:Other"/>' +
            '</xs:sequence></xs:extension></xs:complexContent></xs:complexType></xs:redefine></xs:schema>';
          ValidXml := '<value xmlns="' + TargetNamespace + '"><before>ok</before><after>YES</after></value>';
          InvalidXml := '<value xmlns="' + TargetNamespace + '"><before>ok</before><after>NO</after></value>';
        end;
        2: begin
          CaseName := 'redefine-distinct-component-kinds';
          BaseSchema := NamespaceHeader + '<xs:complexType name="Code"><xs:sequence><xs:element name="before" type="xs:string"/></xs:sequence></xs:complexType>' +
            '<xs:element name="Code" type="xs:integer"/><xs:element name="value" type="t:Code"/></xs:schema>';
          RedefinedSchema := NamespaceHeader + '<xs:redefine schemaLocation="parts/base-2.xsd">' +
            '<xs:complexType name="Code"><xs:complexContent><xs:extension base="t:Code"><xs:sequence><xs:element ref="t:Code"/>' +
            '</xs:sequence></xs:extension></xs:complexContent></xs:complexType></xs:redefine></xs:schema>';
          ValidXml := '<value xmlns="' + TargetNamespace + '"><before>ok</before><Code>12</Code></value>';
          InvalidXml := '<value xmlns="' + TargetNamespace + '"><before>ok</before><Code>NaN</Code></value>';
        end;
      else
        CaseName := 'redefine-reference-prefix-shadowing';
        BaseSchema := NamespaceHeader + '<xs:simpleType name="Code"><xs:restriction base="xs:string"/></xs:simpleType>' +
          '<xs:element name="value" type="t:Code"/></xs:schema>';
        RedefinedSchema := NamespaceHeader + '<xs:redefine schemaLocation="parts/base-3.xsd"><xs:simpleType name="Code">' +
          '<xs:restriction xmlns:mgkositPrevious="urn:mggm:kosit:test:other" base="t:Code"><xs:enumeration value="YES"/></xs:restriction>' +
          '</xs:simpleType></xs:redefine></xs:schema>';
        ValidXml := '<value xmlns="' + TargetNamespace + '">YES</value>';
        InvalidXml := '<value xmlns="' + TargetNamespace + '">NO</value>';
      end;
      SchemaFile := TPath.Combine(DirectoryName, 'redefined-' + IntToStr(CaseIndex) + '.xsd');
      ValidFile := TPath.Combine(DirectoryName, 'valid-' + IntToStr(CaseIndex) + '.xml');
      InvalidFile := TPath.Combine(DirectoryName, 'invalid-' + IntToStr(CaseIndex) + '.xml');
      TFile.WriteAllText(TPath.Combine(DirectoryName, 'parts\base-' + IntToStr(CaseIndex) + '.xsd'), BaseSchema, TEncoding.UTF8);
      TFile.WriteAllText(SchemaFile, RedefinedSchema, TEncoding.UTF8);
      TFile.WriteAllText(ValidFile, ValidXml, TEncoding.UTF8);
      TFile.WriteAllText(InvalidFile, InvalidXml, TEncoding.UTF8);
      RunCase(CaseName + '-valid',
        procedure
        begin
          CheckSchema(ValidFile, [SchemaFile], True);
        end);
      RunCase(CaseName + '-constraint-enforced',
        procedure
        begin
          CheckSchema(InvalidFile, [SchemaFile], False);
        end);
    end;
  finally
    FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures]);
  end;
end;

// Die Diagnose muss die konkrete Ursache benennen, danach wird derselbe Prozessor erneut verwendet.
procedure TEngineTestSuite.RequireEngineFailure(const Action: TProc; const Tokens: array of string);
var
  Rejected: Boolean;
  ErrorText, Token: string;
  Document: IXMLDOMDocument3;
begin
  Rejected := False;
  try
    Action();
  except
    on Error: Exception do
    begin
      Rejected := True;
      ErrorText := Error.ClassName + ': ' + Error.Message;
    end;
  end;
  Require(Rejected, 'Die verbotene oder fehlende Ressource wurde akzeptiert.');
  for Token in Tokens do
    Require(ContainsText(ErrorText, Token), 'Die Diagnose enthält "' + Token + '" nicht: ' + ErrorText);
  FEngine.Transform(Fixture('base.xml'), Fixture('identity.xsl'), FOutputFile);
  Document := FEngine.LoadDocument(FOutputFile);
  Require(Document.documentElement.text = 'ok', 'Die lokale Transformation nach dem Fehler liefert falschen Inhalt.');
  FDiagnostic := ErrorText;
end;

// Die Originalvarianten bleiben getrennt: ähnliche Fehlermeldungen ersetzen keine ausgeführte Ressource.
procedure TEngineTestSuite.CheckResolverContracts;
const
  Header = '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="2.0">';
var
  DirectoryName, OutsideDirectory, StylesheetFile, ResultFile, LocalFile, SchemaFile: string;

  // Jeder Angriff erhält ein eigenes Ausgabeziel; eine vorangegangene Ausgabe kann keinen Erfolg vortäuschen.
  procedure CheckStylesheet(const Name, Body: string; const Tokens: array of string);
  var
    DiagnosticTokens: TArray<string>;
    TokenIndex: Integer;
  begin
    SetLength(DiagnosticTokens, Length(Tokens));
    for TokenIndex := 0 to High(Tokens) do
      DiagnosticTokens[TokenIndex] := Tokens[TokenIndex];
    StylesheetFile := TPath.Combine(DirectoryName, Name + '.xsl');
    ResultFile := TPath.Combine(DirectoryName, Name + '-recovered.xml');
    TFile.WriteAllText(StylesheetFile, Header + Body + '</xsl:stylesheet>', TEncoding.UTF8);
    RunCase(Name,
      procedure
      begin
        RequireEngineFailure(
          procedure
          begin
            FEngine.Transform(Fixture('base.xml'), StylesheetFile, TPath.Combine(DirectoryName, Name + '-forbidden.xml'));
          end, DiagnosticTokens);
        Require(not TFile.Exists(TPath.Combine(DirectoryName, 'ref.xml')), 'Das verbotene Nebenresultat ref.xml wurde geschrieben.');
        Require(not TFile.Exists(TPath.Combine(DirectoryName, Name + '-forbidden.xml')), 'Eine abgelehnte Transformation hat eine Ergebnisdatei geschrieben.');
      end);
  end;

begin
  DirectoryName := TPath.Combine(ExtractFileDir(FEvidenceFile), 'resolver-contracts-' + TPath.GetRandomFileName);
  OutsideDirectory := TPath.Combine(ExtractFileDir(FEvidenceFile), 'resolver-outside-' + TPath.GetRandomFileName);
  ForceDirectories(DirectoryName);
  ForceDirectories(OutsideDirectory);
  LocalFile := TPath.Combine(DirectoryName, 'allowed.xml');
  TFile.WriteAllText(LocalFile, '<allowed>local-absolute-content</allowed>', TEncoding.UTF8);
  FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures, DirectoryName]);
  try
    ResultFile := TPath.Combine(DirectoryName, 'recovered.xml');
    RunCase('absolute-local-resource',
      procedure
      begin
        Require(FEngine.EvaluateBoolean(Fixture('base.xml'), 'string(doc("file:///' + StringReplace(LocalFile, '\', '/', [rfReplaceAll]) + '")/*) = "local-absolute-content"', nil),
          'Die absolute lokale Ressource enthält nicht den erwarteten Inhalt.');
      end);
    ForceDirectories(TPath.Combine(DirectoryName, 'parts'));
    TFile.WriteAllText(TPath.Combine(DirectoryName, 'parts\local include ä.xsl'), Header +
      '<xsl:template match="/"><included>local-include-content</included></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
    RunCase('local-stylesheet-include-with-xml-base-and-percent-encoding',
      procedure
      var
        Document: IXMLDOMDocument3;
      begin
        StylesheetFile := TPath.Combine(DirectoryName, 'allowed-include.xsl');
        TFile.WriteAllText(StylesheetFile, Header + '<xsl:include xml:base="parts/" href="local%20include%20%C3%A4.xsl"/></xsl:stylesheet>', TEncoding.UTF8);
        FEngine.Transform(Fixture('base.xml'), StylesheetFile, ResultFile);
        Document := FEngine.LoadDocument(ResultFile);
        Require(Document.documentElement.text = 'local-include-content', 'Der erlaubte lokale Include lieferte falschen Inhalt.');
      end);
    RunCase('absolute-local-stylesheet-include',
      procedure
      var
        Document: IXMLDOMDocument3;
      begin
        StylesheetFile := TPath.Combine(DirectoryName, 'absolute-include.xsl');
        TFile.WriteAllText(StylesheetFile, Header + '<xsl:include href="file:///' +
          StringReplace(TPath.Combine(DirectoryName, 'allowed-include.xsl'), '\', '/', [rfReplaceAll]) + '"/></xsl:stylesheet>', TEncoding.UTF8);
        FEngine.Transform(Fixture('base.xml'), StylesheetFile, ResultFile);
        Document := FEngine.LoadDocument(ResultFile);
        Require(Document.documentElement.text = 'local-include-content', 'Der absolute lokale Include lieferte falschen Inhalt.');
      end);
    RunCase('native-http-unparsed-text-rejected-and-reusable',
      procedure
      begin
        RequireEngineFailure(
          procedure
          begin
            FEngine.EvaluateBoolean(Fixture('base.xml'), 'unparsed-text("http://127.0.0.1:9/forbidden.txt") = "forbidden"', nil);
          end, ['http', 'prohibited']);
      end);
    SchemaFile := TPath.Combine(DirectoryName, 'remote-import.xsd');
    TFile.WriteAllText(SchemaFile, '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">' +
      '<xs:import namespace="urn:forbidden" schemaLocation="http://127.0.0.1:9/forbidden.xsd"/></xs:schema>', TEncoding.UTF8);
    RunCase('remote-schema-import-rejected',
      procedure
      var
        Diagnostic, SecurityDiagnostic: string;
      begin
        RequireEngineFailure(
          procedure
          begin
            FEngine.ValidateSchemas(Fixture('base.xml'), [SchemaFile], Diagnostic);
          end, ['Schema', 'lokalen relativen Import', 'http://127.0.0.1:9/forbidden.xsd']);
        SecurityDiagnostic := FDiagnostic;
        CheckSchema(Fixture('local.xml'), [Fixture('local.xsd')], True);
        FDiagnostic := SecurityDiagnostic;
      end);
    RunCase('schema-multiple-original-byte-errors-are-distinct',
      procedure
      var
        Document: IXMLDOMDocument3;
        Content: TBytes;
        Diagnostics: TArray<string>;
        MultipleSchemaFile: string;
      begin
        MultipleSchemaFile := TPath.Combine(DirectoryName, 'multiple-errors.xsd');
        TFile.WriteAllText(MultipleSchemaFile, '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">' +
          '<xs:element name="root"><xs:complexType><xs:sequence><xs:element name="value" type="xs:integer" maxOccurs="unbounded"/>' +
          '</xs:sequence></xs:complexType></xs:element></xs:schema>', TEncoding.UTF8);
        Content := TEncoding.UTF8.GetBytes('<root>' + #13#10 + '<value>bad</value>' + #13#10 + '<value>wrong</value>' + #13#10 + '</root>');
        Document := FEngine.LoadDocumentBytes(Content, 'urn:mggm:kosit:test:multiple-schema-errors');
        Require(not FEngine.ValidateDocumentSchemaDiagnostics(Document, [MultipleSchemaFile], Diagnostics, Content), 'Mehrfach ungültige Eingabe wurde akzeptiert.');
        Require(Length(Diagnostics) = 2, 'Zwei unabhängige Schemafehler müssen zwei Diagnosen liefern: ' + string.Join(' / ', Diagnostics));
        Require(ContainsText(Diagnostics[0], 'bad') and ContainsText(Diagnostics[0], 'Zeile: 2;') and
          ContainsText(Diagnostics[1], 'wrong') and ContainsText(Diagnostics[1], 'Zeile: 3;'), 'Fehlerinhalt, Reihenfolge oder Originalposition ging verloren.');
        FDiagnostic := string.Join(' / ', Diagnostics);
        Content := TEncoding.UTF8.GetBytes('<root><value>1</value><value>2</value></root>');
        Document := FEngine.LoadDocumentBytes(Content, 'urn:mggm:kosit:test:multiple-schema-errors-recovered');
        Require(FEngine.ValidateDocumentSchemaDiagnostics(Document, [MultipleSchemaFile], Diagnostics, Content), 'Gültige Eingabe nach mehreren Schemafehlern abgelehnt.');
        Require(Length(Diagnostics) = 0, 'Die gültige Eingabe enthält veraltete Schemafehler.');
      end);
    CheckStylesheet('missing-relative-resource-diagnostic', '<xsl:include href="missing-relative.xsl"/>', ['missing-relative.xsl']);
    CheckStylesheet('native-security-evil1-result-document', '<xsl:template match="/"><xsl:result-document href="ref.xml"><evil-content/>' +
      '</xsl:result-document></xsl:template>', ['result-document']);
    CheckStylesheet('native-security-evil2-http-document', '<xsl:template match="/"><evil-content><xsl:value-of select="document(''http://127.0.0.1:9/evil.xml'')"/>' +
      '</evil-content></xsl:template>', ['http', 'prohibited']);
    CheckStylesheet('native-security-evil3-relative-include', '<xsl:include href="www.evil.de/xsl.xsl"/>', ['www.evil.de', 'xsl.xsl']);
    TFile.WriteAllText(TPath.Combine(OutsideDirectory, 'outside.xsl'), Header + '<xsl:template match="/"><evil-content/></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
    CheckStylesheet('native-security-evil4-outside-file-include', '<xsl:include href="file:///' +
      StringReplace(TPath.Combine(OutsideDirectory, 'outside.xsl'), '\', '/', [rfReplaceAll]) + '"/>', ['außerhalb', 'outside.xsl']);
    TFile.WriteAllText(TPath.Combine(DirectoryName, 'nested-escape.xsl'), Header +
      '<xsl:include xml:base="../' + ExtractFileName(OutsideDirectory) + '/" href="outside.xsl"/></xsl:stylesheet>', TEncoding.UTF8);
    CheckStylesheet('transitive-stylesheet-include-with-outside-xml-base', '<xsl:include href="nested-escape.xsl"/>', ['außerhalb', 'outside.xsl']);
    CheckStylesheet('native-security-evil5-relative-unparsed-text', '<xsl:template match="/"><evil-content>' +
      '<xsl:value-of select="unparsed-text(''src/test/resources/evil/ref.txt'')"/></evil-content></xsl:template>', ['ref.txt']);
  finally
    FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures]);
  end;
end;

// Die Speicher-API verwendet denselben lokalen Importgraphen; der Compilecache darf keine erneute Dateiprüfung pro Dokument benötigen.
procedure TEngineTestSuite.CheckByteStylesheetContracts;
const
  Header = '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="2.0">';
var
  DirectoryName, AllowedDirectory, OutsideDirectory, AllowedStylesheet, DirectEscapeStylesheet, TransitiveEscapeStylesheet, RepairStylesheet: string;
  Content: TBytes;

begin
  DirectoryName := TPath.Combine(ExtractFileDir(FEvidenceFile), 'byte-stylesheets-' + TPath.GetRandomFileName);
  AllowedDirectory := TPath.Combine(ExtractFileDir(FEvidenceFile), 'byte-allowed-' + TPath.GetRandomFileName);
  OutsideDirectory := TPath.Combine(ExtractFileDir(FEvidenceFile), 'byte-outside-' + TPath.GetRandomFileName);
  ForceDirectories(TPath.Combine(DirectoryName, 'parts'));
  ForceDirectories(AllowedDirectory);
  ForceDirectories(OutsideDirectory);
  Content := TEncoding.UTF8.GetBytes('<source/>');
  TFile.WriteAllText(TPath.Combine(AllowedDirectory, 'local include ä.xsl'), Header +
    '<xsl:output method="text"/><xsl:template match="/">allowed-content</xsl:template></xsl:stylesheet>', TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(OutsideDirectory, 'outside include ä.xsl'), Header +
    '<xsl:output method="text"/><xsl:template match="/">outside-content</xsl:template></xsl:stylesheet>', TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(DirectoryName, 'parts\allowed.xsl'), Header +
    '<xsl:include xml:base="../../' + ExtractFileName(AllowedDirectory) + '/" href="local%20include%20%C3%A4.xsl"/></xsl:stylesheet>', TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(DirectoryName, 'parts\outside.xsl'), Header +
    '<xsl:include xml:base="../../' + ExtractFileName(OutsideDirectory) + '/" href="outside%20include%20%C3%A4.xsl"/></xsl:stylesheet>', TEncoding.UTF8);
  AllowedStylesheet := TPath.Combine(DirectoryName, 'allowed-main.xsl');
  DirectEscapeStylesheet := TPath.Combine(DirectoryName, 'direct-escape.xsl');
  TransitiveEscapeStylesheet := TPath.Combine(DirectoryName, 'transitive-escape.xsl');
  RepairStylesheet := TPath.Combine(DirectoryName, 'repair.xsl');
  TFile.WriteAllText(AllowedStylesheet, Header + '<xsl:include href="parts/allowed.xsl"/></xsl:stylesheet>', TEncoding.UTF8);
  TFile.WriteAllText(DirectEscapeStylesheet, Header + '<xsl:include href="../' + ExtractFileName(OutsideDirectory) +
    '/outside%20include%20%C3%A4.xsl"/></xsl:stylesheet>', TEncoding.UTF8);
  TFile.WriteAllText(TransitiveEscapeStylesheet, Header + '<xsl:include href="parts/outside.xsl"/></xsl:stylesheet>', TEncoding.UTF8);
  FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures, DirectoryName, AllowedDirectory]);
  try
    RunCase('bytes-local-transitive-include-with-xml-base-and-encoding',
      procedure
      begin
        Require(TEncoding.UTF8.GetString(FEngine.TransformBytes(Content, 'urn:mggm:kosit:test:byte-security', AllowedStylesheet)) = 'allowed-content',
          'Der erlaubte Byte-Include lieferte falschen Inhalt.');
      end);
    RunCase('bytes-direct-stylesheet-root-escape-rejected',
      procedure
      begin
        RequireEngineFailure(
          procedure
          begin
            FEngine.TransformBytes(Content, 'urn:mggm:kosit:test:byte-security', DirectEscapeStylesheet);
          end, ['außerhalb', 'outside include ä.xsl']);
      end);
    RunCase('bytes-transitive-stylesheet-root-escape-with-xml-base-and-encoding-rejected',
      procedure
      begin
        RequireEngineFailure(
          procedure
          begin
            FEngine.TransformBytes(Content, 'urn:mggm:kosit:test:byte-security', TransitiveEscapeStylesheet);
          end, ['außerhalb', 'outside include ä.xsl']);
      end);
    RunCase('bytes-stylesheet-cache-avoids-repeated-preflight-and-compilation',
      procedure
      var
        CompilationCount, Cycle: Integer;
        DomMs: Double;
      begin
        CompilationCount := FEngine.Statistics.StylesheetCompilationCount;
        DomMs := FEngine.Statistics.DomMs;
        for Cycle := 1 to 16 do
          Require(TEncoding.UTF8.GetString(FEngine.TransformBytes(Content, 'urn:mggm:kosit:test:byte-security', AllowedStylesheet)) = 'allowed-content',
            'Wiederholter Byte-Include liefert falschen Inhalt.');
        Require(FEngine.Statistics.StylesheetCompilationCount = CompilationCount, 'Das unveränderte Byte-Stylesheet wurde erneut kompiliert.');
        Require(FEngine.Statistics.DomMs = DomMs, 'Der unveränderte Stylesheetgraph wurde erneut als DOM eingelesen.');
      end);
    RunCase('bytes-stylesheet-cache-resource-revocation-and-recovery',
      procedure
      begin
        FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures, DirectoryName]);
        try
          RequireEngineFailure(
            procedure
            begin
              FEngine.TransformBytes(Content, 'urn:mggm:kosit:test:byte-security', AllowedStylesheet);
            end, ['außerhalb', 'local include ä.xsl']);
        finally
          FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures, DirectoryName, AllowedDirectory]);
        end;
        Require(TEncoding.UTF8.GetString(FEngine.TransformBytes(Content, 'urn:mggm:kosit:test:byte-security', AllowedStylesheet)) = 'allowed-content',
          'Die Byte-Transformation erholt sich nach erneuter Ressourcenfreigabe nicht.');
      end);
    RunCase('bytes-stylesheet-preflight-follows-native-cache-invalidation',
      procedure
      var
        CompilationCount: Integer;
        DomMs: Double;
      begin
        CompilationCount := FEngine.Statistics.StylesheetCompilationCount;
        DomMs := FEngine.Statistics.DomMs;
        FEngine.RegisterMemoryResource('urn:mggm:kosit:test:byte-cache-invalidation', TEncoding.UTF8.GetBytes(Header + '</xsl:stylesheet>'));
        Require(TEncoding.UTF8.GetString(FEngine.TransformBytes(Content, 'urn:mggm:kosit:test:byte-security', AllowedStylesheet)) = 'allowed-content',
          'Die Byte-Transformation liefert nach Cacheinvalidierung falschen Inhalt.');
        Require(FEngine.Statistics.StylesheetCompilationCount = CompilationCount + 1, 'Das Native-Stylesheet wurde nach Cacheinvalidierung nicht neu kompiliert.');
        Require(FEngine.Statistics.DomMs > DomMs, 'Die Sicherheitsprüfung wurde nach Native-Cacheinvalidierung nicht erneuert.');
      end);
    RunCase('bytes-failed-stylesheet-does-not-cache-resource-trust',
      procedure
      begin
        TFile.WriteAllText(RepairStylesheet, Header + '<xsl:include href="parts/allowed.xsl"/>' +
          '<xsl:template match="/"><xsl:value-of select="//*["/></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
        RequireEngineFailure(
          procedure
          begin
            FEngine.TransformBytes(Content, 'urn:mggm:kosit:test:byte-security', RepairStylesheet);
          end, ['Stylesheet']);
        TFile.WriteAllText(RepairStylesheet, Header + '<xsl:include href="parts/outside.xsl"/></xsl:stylesheet>', TEncoding.UTF8);
        RequireEngineFailure(
          procedure
          begin
            FEngine.TransformBytes(Content, 'urn:mggm:kosit:test:byte-security', RepairStylesheet);
          end, ['außerhalb', 'outside include ä.xsl']);
      end);
  finally
    FEngine.ConfigureResourceRoots([FValidationRoot, FFixtures]);
  end;
end;

// Die kleine Integrationsmatrix prüft Sicherheitsgrenzen und die Original-UBL-Schemata.
procedure TEngineTestSuite.ExecuteCases;
var
  PairSchemas: TArray<string>;
  MissingImportRaised: Boolean;
  MissingImportDiagnostic: string;
begin
  RunCase('baseline-native-xpath',
    procedure
    begin
      Require(FEngine.EvaluateBoolean(Fixture('base.xml'), '/root = "ok"', nil), 'Der gültige Basis-XPath liefert False.');
    end);
  if FFailed <> 0 then
    Exit;
  RunCase('native-dtd-rejected-and-reusable',
    procedure
    begin
      RequireNativeFailure(
        procedure
        begin
          FEngine.EvaluateBoolean(Fixture('doctype.xml'), '/root = "ok"', nil);
        end, ['DOCTYPE']);
    end);
  RunCase('native-http-document-rejected-and-reusable',
    procedure
    begin
      RequireNativeFailure(
        procedure
        begin
          FEngine.EvaluateBoolean(Fixture('base.xml'), 'string(doc("http://127.0.0.1:9/mg-kosit-forbidden.xml")/*) = "must-not-load"', nil);
        end, ['http', 'prohibited']);
    end);
  RunCase('native-http-stylesheet-import-rejected-and-reusable',
    procedure
    begin
      RequireNativeFailure(
        procedure
        begin
          FEngine.Transform(Fixture('base.xml'), Fixture('http-import.xsl'), FOutputFile);
        end, ['http', 'prohibited']);
    end);
  RunCase('native-external-java-function-rejected-and-reusable',
    procedure
    begin
      RequireNativeFailure(
        procedure
        begin
          FEngine.EvaluateBoolean(Fixture('base.xml'), 'Q{java:java.lang.System}getProperty("user.home")', nil);
        end, ['java']);
    end);
  RunCase('native-valid-transform-after-failures',
    procedure
    var
      Document: IXMLDOMDocument3;
    begin
      FEngine.Transform(Fixture('base.xml'), Fixture('identity.xsl'), FOutputFile);
      Document := FEngine.LoadDocument(FOutputFile);
      Require(Document.documentElement.text = 'ok', 'Die gültige Transformation enthält nicht den erwarteten Inhalt.');
    end);
  PairSchemas := TArray<string>.Create(Fixture('first.xsd'), Fixture('second.xsd'));
  RunCase('same-namespace-first-entry-retained',
    procedure
    begin
      CheckSchema(Fixture('first.xml'), PairSchemas, True);
    end);
  RunCase('same-namespace-second-entry-retained',
    procedure
    begin
      CheckSchema(Fixture('second.xml'), PairSchemas, True);
    end);
  RunCase('same-namespace-type-constraint-enforced',
    procedure
    begin
      CheckSchema(Fixture('second-invalid.xml'), PairSchemas, False);
    end);
  RunCase('local-import-base-uri-preserved',
    procedure
    begin
      CheckSchema(Fixture('local.xml'), TArray<string>.Create(Fixture('local.xsd')), True);
    end);
  RunCase('local-import-type-constraint-enforced',
    procedure
    begin
      CheckSchema(Fixture('local-invalid.xml'), TArray<string>.Create(Fixture('local.xsd')), False);
    end);
  RunCase('schema-error-location-follows-original-byte-lines',
    procedure
    var
      Content: TBytes;
      Document: IXMLDOMDocument3;
      FirstDiagnostic, ShiftedDiagnostic: string;
      FirstPosition, ShiftedPosition: TMatch;
    begin
      Content := TEncoding.UTF8.GetBytes('<code xmlns="urn:mggm:kosit:test:local">nicht erlaubt</code>');
      Document := FEngine.LoadDocumentBytes(Content, 'urn:mggm:kosit:test:original-position');
      Require(not FEngine.ValidateDocumentSchemas(Document, [Fixture('local.xsd')], FirstDiagnostic, Content), 'Ungültige Originalbytes wurden akzeptiert.');
      Content := TEncoding.UTF8.GetBytes(#13#10#13#10#13#10 + '<code xmlns="urn:mggm:kosit:test:local">nicht erlaubt</code>');
      Document := FEngine.LoadDocumentBytes(Content, 'urn:mggm:kosit:test:shifted-position');
      Require(not FEngine.ValidateDocumentSchemas(Document, [Fixture('local.xsd')], ShiftedDiagnostic, Content), 'Ungültige verschobene Originalbytes wurden akzeptiert.');
      FirstPosition := TRegEx.Match(FirstDiagnostic, 'Zeile: ([0-9]+); Position: ([0-9]+)');
      ShiftedPosition := TRegEx.Match(ShiftedDiagnostic, 'Zeile: ([0-9]+); Position: ([0-9]+)');
      Require(FirstPosition.Success and ShiftedPosition.Success, 'Die Schema-Diagnose enthält keine Parserposition.');
      Require((FirstPosition.Groups[1].Value = '1') and (ShiftedPosition.Groups[1].Value = '4'),
        'Die gemeldete Zeile folgt nicht den Originalbytes: ' + FirstDiagnostic + ' / ' + ShiftedDiagnostic);
      Require((StrToInt(FirstPosition.Groups[2].Value) > 0) and (FirstPosition.Groups[2].Value = ShiftedPosition.Groups[2].Value),
        'Die Parserposition ist nicht positiv oder ändert sich durch vorangestellte Leerzeilen.');
      CheckSchema(Fixture('local.xml'), [Fixture('local.xsd')], True);
      FDiagnostic := FirstDiagnostic + ' / ' + ShiftedDiagnostic;
    end);
  RunCase('missing-schema-import-is-infrastructure-error',
    procedure
    var
      Diagnostic: string;
    begin
      MissingImportRaised := False;
      MissingImportDiagnostic := '';
      try
        FEngine.ValidateSchemas(Fixture('local.xml'), TArray<string>.Create(Fixture('missing-import.xsd')), Diagnostic);
      except
        on Error: Exception do
        begin
          MissingImportRaised := True;
          MissingImportDiagnostic := Error.ClassName + ': ' + Error.Message;
        end;
      end;
      Require(MissingImportRaised, 'Der fehlende Schema-Import wurde nicht als Infrastrukturfehler ausgelöst.');
      Require(ContainsText(MissingImportDiagnostic, 'absent.xsd') and ContainsText(MissingImportDiagnostic, 'fehlt'),
        'Die Diagnose benennt den fehlenden Import nicht: ' + MissingImportDiagnostic);
      FDiagnostic := MissingImportDiagnostic;
      CheckSchema(Fixture('local.xml'), TArray<string>.Create(Fixture('local.xsd')), True);
      FDiagnostic := MissingImportDiagnostic;
    end);
  RunCase('foreign-thread-rejected-owner-reusable',
    procedure
    begin
      CheckForeignThread;
    end);
  RunCase('original-ubl-internal-schema-dtd-accepted',
    procedure
    begin
      CheckSchema(FInvoiceFile,
        TArray<string>.Create(TPath.Combine(FValidationRoot, 'validator-configuration-xrechnung\3.0.2\resources\ubl\2.1\xsd\maindoc\UBL-Invoice-2.1.xsd')), True);
    end);
end;

// Der erste XPath ist die begrenzte Gegenprobe vor den abhängigen Engine- und Schemafällen.
function TEngineTestSuite.Execute(const LibraryFile, ValidationRoot, InvoiceFile: string): Integer;
var
  SetupFailure: TJSONObject;
begin
  Result := 1;
  ForceDirectories(ExtractFileDir(FEvidenceFile));
  try
    FValidationRoot := ExpandFileName(ValidationRoot);
    FInvoiceFile := InvoiceFile;
    if FInvoiceFile = '' then
      FInvoiceFile := TPath.Combine(ExtractFileDir(ExcludeTrailingPathDelimiter(FValidationRoot)),
        'xrechnung-testsuite\src\test\business-cases\standard\01.01a-INVOICE_ubl.xml');
    Require(FileExists(Fixture('base.xml')), 'Die Testfixtures fehlen: ' + FFixtures);
    Require(FileExists(FInvoiceFile), 'Die originale UBL-Testrechnung fehlt: ' + FInvoiceFile);
    FEngine := TMGKositEngine.Create(LibraryFile);
    FEngine.ConfigureResourceRoots(TArray<string>.Create(FValidationRoot, FFixtures));
    FEvidence.AddPair('engine_version', FEngine.Version);
    ExecuteCases;
    CheckResolverContracts;
    CheckByteStylesheetContracts;
    CheckLongPaths;
    CheckSchemaRedefinition;
    CheckSchemaReuse;
    RunCase('checked-native-close',
      procedure
      begin
        FEngine.Close;
      end);
  except
    on Error: Exception do
    begin
      Inc(FFailed);
      SetupFailure := TJSONObject.Create;
      SetupFailure.AddPair('name', 'suite-infrastructure');
      SetupFailure.AddPair('passed', TJSONBool.Create(False));
      SetupFailure.AddPair('diagnostic', Error.ClassName + ': ' + Error.Message);
      FCases.AddElement(SetupFailure);
    end;
  end;
  FEvidence.AddPair('passed', TJSONNumber.Create(FPassed));
  FEvidence.AddPair('failed', TJSONNumber.Create(FFailed));
  FEvidence.AddPair('total', TJSONNumber.Create(FPassed + FFailed));
  FEvidence.AddPair('fixtures', FFixtures);
  FEvidence.AddPair('original_invoice', FInvoiceFile);
  TFile.WriteAllText(FEvidenceFile, FEvidence.ToJSON, TEncoding.UTF8);
  if FFailed = 0 then
    Result := 0;
end;

// Aufruf: EngineTests LibraryFile ValidationRoot EvidenceJson [OriginalUblInvoice [FixtureRoot]].
procedure Run;
var
  Suite: TEngineTestSuite;
  InvoiceFile, FixtureRoot: string;
begin
  if (ParamCount < 3) or (ParamCount > 5) then
    raise Exception.Create('Aufruf: EngineTests LibraryFile ValidationRoot EvidenceJson [OriginalUblInvoice [FixtureRoot]]');
  InvoiceFile := '';
  FixtureRoot := '';
  if ParamCount >= 4 then
    InvoiceFile := ParamStr(4);
  if ParamCount = 5 then
    FixtureRoot := ParamStr(5);
  Suite := TEngineTestSuite.Create(ParamStr(3), FixtureRoot);
  try
    ExitCode := Suite.Execute(ParamStr(1), ParamStr(2), InvoiceFile);
  finally
    FreeAndNil(Suite);
  end;
end;

begin
  SetTextCodePage(Output, 65001);
  SetTextCodePage(ErrOutput, 65001);
  try
    Run;
  except
    on Error: Exception do
    begin
      WriteLn(ErrOutput, Error.ClassName, ': ', Error.Message);
      ExitCode := 1;
    end;
  end;
end.
