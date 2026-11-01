program NativeReuseTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Diagnostics, Winapi.Windows,
  MGKositNative;

var
  Native: TMGKositNative;
  Evidence: TJSONObject;
  Cases: TJSONArray;
  EvidenceFile, Root, SourceFile, ParameterFile, StylesheetFile, BadStylesheetFile, OutputFile: string;
  Passed, Failed: Integer;

// Jede Verletzung des beobachtbaren Vertrags muss den Testlauf fehlschlagen lassen.
procedure Require(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

// Testdaten liegen in einem eigenen, im Nachweis erhaltenen Verzeichnis.
procedure WriteSource(const FileName, Value: string);
begin
  TFile.WriteAllText(FileName, '<root xmlns="urn:first" value="' + Value + '"/>', TEncoding.UTF8);
end;

// Ein erwarteter Native-Fehler darf weder verschluckt noch als Erfolg gezählt werden.
procedure ExpectFailure(const Action: TProc);
var
  Rejected: Boolean;
begin
  Rejected := False;
  try
    Action();
  except
    on Error: EMGKositNative do
    begin
      Require(Error.Message <> '', 'Fehlende Fehlerdiagnose');
      Rejected := True;
    end;
  end;
  Require(Rejected, 'Erwarteter Native-Fehler blieb aus');
end;

// Unabhängige Gegenproben laufen auch nach einem fehlgeschlagenen Fall weiter.
procedure RunCase(const Name: string; const Action: TProc);
var
  Item: TJSONObject;
  Diagnostic: string;
  Success: Boolean;
  Watch: TStopwatch;
begin
  Watch := TStopwatch.StartNew;
  Success := False;
  Diagnostic := '';
  try
    Action();
    Success := True;
    Inc(Passed);
  except
    on Error: Exception do
    begin
      Diagnostic := Error.ClassName + ': ' + Error.Message;
      Inc(Failed);
    end;
  end;
  Native.EndDocument;
  Item := TJSONObject.Create;
  Item.AddPair('name', Name);
  Item.AddPair('passed', TJSONBool.Create(Success));
  Item.AddPair('diagnostic', Diagnostic);
  Item.AddPair('duration_ms', TJSONNumber.Create(Watch.ElapsedMilliseconds));
  Cases.AddElement(Item);
  WriteLn(Name, ': ', BoolToStr(Success, True), ' ', Diagnostic);
end;

// Tatsächliche serialisierte Ausgabe belegt, dass Quelle und Parameter frisch sind.
procedure CheckTransform(const Expected, InputDocument: string);
begin
  Native.Transform(SourceFile, StylesheetFile, OutputFile, InputDocument);
  Require(TFile.ReadAllText(OutputFile, TEncoding.UTF8) = Expected, 'Falsche XSLT-Ausgabe: ' + TFile.ReadAllText(OutputFile, TEncoding.UTF8));
end;

// Wiederholung mit alternierenden Inhalten prüft auch den Zustand zwischen Aufrufen.
procedure ExecuteCases;
begin
  RunCase('64 alternierende Dokumente, ein Stylesheet und ein XPath-Kontext',
    procedure
    var
      Cycle: Integer;
      Value: string;
    begin
      for Cycle := 1 to 64 do
      begin
        if Odd(Cycle) then Value := 'yes' else Value := 'no';
        WriteSource(SourceFile, Value);
        Native.BeginDocument(SourceFile);
        try
          Require(Native.EvaluateBoolean(SourceFile, '/*/@value = "yes"', []) = Odd(Cycle), 'Veralteter XPath-Kontext');
          CheckTransform(Value + '|' + Value, SourceFile);
        finally
          Native.EndDocument;
        end;
      end;
      Require(Native.StylesheetCompilationCount = 1, 'Stylesheet mehrfach kompiliert');
      Require(Native.XPathProcessorCount = 1, 'XPath-Prozessor mehrfach erzeugt');
      Require(Native.SourceParseCount = 64, 'Aktive Quelle mehrfach geparst');
    end);
  RunCase('Temporärquelle mit gleichem Pfad wird frisch geparst',
    procedure
    begin
      WriteSource(ParameterFile, 'active');
      Native.BeginDocument(ParameterFile);
      WriteSource(SourceFile, 'first');
      CheckTransform('first|active', ParameterFile);
      WriteSource(SourceFile, 'second');
      CheckTransform('second|active', ParameterFile);
      Require(Native.EvaluateBoolean(SourceFile, '/*/@value = "second"', []), 'Temporärquelle veraltet');
    end);
  RunCase('Namespace-Kontexte sind getrennt',
    procedure
    begin
      WriteSource(SourceFile, 'yes');
      Native.BeginDocument(SourceFile);
      Require(Native.EvaluateBoolean(SourceFile, 'exists(/test:root)', ['test', 'urn:first']), 'Erster Namespace fehlt');
      Require(not Native.EvaluateBoolean(SourceFile, 'exists(/test:root)', ['test', 'urn:second']), 'Namespace-Kontext vermischt');
      Require(Native.EvaluateBoolean(SourceFile, 'exists(/test:root)', ['test', 'urn:first']), 'Erster Namespace überschrieben');
      Require(Native.XPathProcessorCount = 3, 'Namespace-Prozessoren nicht wiederverwendet');
    end);
  RunCase('Dokumentparameter wechseln und entfallen',
    procedure
    begin
      WriteSource(SourceFile, 'source');
      Native.BeginDocument(SourceFile);
      WriteSource(ParameterFile, 'one');
      CheckTransform('source|one', ParameterFile);
      WriteSource(ParameterFile, 'two');
      CheckTransform('source|two', ParameterFile);
      CheckTransform('source|', '');
    end);
  RunCase('XML-Fehler und anschließende Wiederverwendung',
    procedure
    begin
      TFile.WriteAllText(SourceFile, '<broken>', TEncoding.UTF8);
      ExpectFailure(procedure begin Native.BeginDocument(SourceFile); end);
      WriteSource(SourceFile, 'recovered');
      Native.BeginDocument(SourceFile);
      CheckTransform('recovered|', '');
    end);
  RunCase('XPath-Fehler und anschließende Wiederverwendung',
    procedure
    begin
      WriteSource(SourceFile, 'recovered');
      Native.BeginDocument(SourceFile);
      ExpectFailure(procedure begin Native.EvaluateBoolean(SourceFile, '//*[', []); end);
      Require(Native.EvaluateBoolean(SourceFile, '/*/@value = "recovered"', []), 'XPath nach Fehler defekt');
    end);
  RunCase('Stylesheet-Compilerfehler und anschließende Wiederverwendung',
    procedure
    begin
      ExpectFailure(procedure begin Native.Transform(SourceFile, BadStylesheetFile, OutputFile); end);
      CheckTransform('recovered|', '');
      Require(Native.StylesheetCompilationCount = 1, 'Fehlerhaftes Stylesheet gecached');
    end);
  RunCase('XSLT-Laufzeitfehler und anschließende Wiederverwendung',
    procedure
    begin
      WriteSource(SourceFile, 'fail');
      ExpectFailure(procedure begin Native.Transform(SourceFile, StylesheetFile, OutputFile); end);
      WriteSource(SourceFile, 'after-error');
      CheckTransform('after-error|', '');
    end);
  RunCase('Bestehende API ohne Dokumentkontext',
    procedure
    var
      ParseCount: Integer;
    begin
      ParseCount := Native.SourceParseCount;
      WriteSource(SourceFile, 'yes');
      Require(Native.EvaluateBoolean(SourceFile, '/*/@value = "yes"', []), 'Frische Quelle fehlt');
      WriteSource(SourceFile, 'no');
      Require(not Native.EvaluateBoolean(SourceFile, '/*/@value = "yes"', []), 'Quelle wurde unerlaubt gecached');
      CheckTransform('no|', '');
      Require(Native.SourceParseCount = ParseCount + 3, 'Falsche Parseranzahl ohne Dokumentkontext');
    end);
  RunCase('Verschachtelter Dokumentbeginn wird abgelehnt',
    procedure
    begin
      Native.BeginDocument(SourceFile);
      ExpectFailure(procedure begin Native.BeginDocument(ParameterFile); end);
      CheckTransform('no|', '');
      Native.EndDocument;
      Native.EndDocument;
    end);
  RunCase('Konfigurationsänderung invalidiert kompilierte Kontexte',
    procedure
    var
      CompilationCount, ProcessorCount: Integer;
    begin
      Native.BeginDocument(SourceFile);
      ExpectFailure(procedure begin Native.Configure('http://saxon.sf.net/feature/allowedProtocols', 'file'); end);
      Native.EndDocument;
      CompilationCount := Native.StylesheetCompilationCount;
      ProcessorCount := Native.XPathProcessorCount;
      Native.Configure('http://saxon.sf.net/feature/allowedProtocols', 'file');
      CheckTransform('no|', '');
      Require(Native.EvaluateBoolean(SourceFile, '/*/@value = "no"', []), 'XPath nach Konfiguration defekt');
      Require(Native.StylesheetCompilationCount = CompilationCount + 1, 'Alter Stylesheet-Kontext erhalten');
      Require(Native.XPathProcessorCount = ProcessorCount + 1, 'Alter XPath-Kontext erhalten');
    end);
  RunCase('Stylesheet-Serialisierung ISO-8859-1 bleibt bytegenau',
    procedure
    var
      EncodingStylesheet: string;
      Bytes: TBytes;
    begin
      EncodingStylesheet := TPath.Combine(Root, 'latin1.xsl');
      TFile.WriteAllText(EncodingStylesheet,
        '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="3.0">' +
        '<xsl:output method="text" encoding="ISO-8859-1"/><xsl:template match="/">ä</xsl:template></xsl:stylesheet>', TEncoding.UTF8);
      Native.Transform(SourceFile, EncodingStylesheet, OutputFile);
      Bytes := TFile.ReadAllBytes(OutputFile);
      Require((Length(Bytes) = 1) and (Bytes[0] = $E4), 'ISO-8859-1-Ausgabe verändert: ' + IntToStr(Length(Bytes)) + ' Bytes');
    end);
  RunCase('Stylesheet-Serialisierung UTF-16 erhält Nullbytes und BOM',
    procedure
    var
      EncodingStylesheet: string;
      Bytes: TBytes;
    begin
      EncodingStylesheet := TPath.Combine(Root, 'utf16.xsl');
      TFile.WriteAllText(EncodingStylesheet,
        '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="3.0">' +
        '<xsl:output method="text" encoding="UTF-16"/><xsl:template match="/">Aä</xsl:template></xsl:stylesheet>', TEncoding.UTF8);
      Native.Transform(SourceFile, EncodingStylesheet, OutputFile);
      Bytes := TFile.ReadAllBytes(OutputFile);
      Require(Length(Bytes) = 6, 'UTF-16-Ausgabelänge verändert: ' + IntToStr(Length(Bytes)));
      Require((Bytes[0] = $FE) and (Bytes[1] = $FF) and (Bytes[2] = 0) and (Bytes[3] = $41) and (Bytes[4] = 0) and (Bytes[5] = $E4), 'UTF-16-Ausgabe verändert');
    end);
  RunCase('HTML-Serialisierung und relative result-document-Ziele',
    procedure
    var
      HtmlStylesheet, NestedOutput, Html: string;
    begin
      HtmlStylesheet := TPath.Combine(Root, 'html.xsl');
      NestedOutput := TPath.Combine(Root, 'Ausgabe mit Leerzeichen ä');
      ForceDirectories(NestedOutput);
      TFile.WriteAllText(HtmlStylesheet,
        '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="3.0">' +
        '<xsl:output method="html" encoding="UTF-8"/><xsl:template match="/">' +
        '<xsl:result-document href="secondary.txt" method="text">ä</xsl:result-document>' +
        '<html><body><br/><script>if (1 &lt; 2) {}</script></body></html></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
      // Saxon sperrt result-document zusammen mit externen Funktionen im Sicherheitsprofil.
      // Nur diese vertrauenswürdige Fixture benötigt die ausdrücklich lokale Testfreigabe.
      Native.Configure('http://saxon.sf.net/feature/allow-external-functions', 'true');
      try
        Native.Transform(SourceFile, HtmlStylesheet, TPath.Combine(NestedOutput, 'primary.html'));
      finally
        Native.Configure('http://saxon.sf.net/feature/allow-external-functions', 'false');
      end;
      Html := TFile.ReadAllText(TPath.Combine(NestedOutput, 'primary.html'), TEncoding.UTF8);
      Require(Pos('<br>', Html) > 0, 'HTML-Leerelement nicht serialisiert');
      Require(Pos('if (1 < 2)', Html) > 0, 'HTML-Script wurde XML-escaped');
      Require(TFile.ReadAllText(TPath.Combine(NestedOutput, 'secondary.txt'), TEncoding.UTF8) = 'ä', 'Relativer result-document-Ausgabeort falsch');
    end);
  RunCase('Leere Serialisierung überschreibt eine vorhandene Ausgabe',
    procedure
    var
      EmptyStylesheet: string;
    begin
      EmptyStylesheet := TPath.Combine(Root, 'empty.xsl');
      TFile.WriteAllText(EmptyStylesheet,
        '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="3.0">' +
        '<xsl:output method="text"/><xsl:template match="/"/></xsl:stylesheet>', TEncoding.UTF8);
      TFile.WriteAllText(OutputFile, 'vorhandener Inhalt', TEncoding.UTF8);
      Native.Transform(SourceFile, EmptyStylesheet, OutputFile);
      Require(Length(TFile.ReadAllBytes(OutputFile)) = 0, 'Veraltete Ausgabe blieb erhalten');
    end);
  RunCase('512 wechselnde Speicher-Basis-URIs verwenden zwei Namespace-Kontexte',
    procedure
    var
      Cycle, ProcessorCount, ParseCount: Integer;
      NamespaceUri, BaseUri: string;
      XmlBytes: TBytes;
      Metrics: TJSONObject;
    begin
      ProcessorCount := Native.XPathProcessorCount;
      ParseCount := Native.SourceParseCount;
      Metrics := TJSONObject.Create;
      Evidence.AddPair('memory_xpath_cache', Metrics);
      Metrics.AddPair('documents', TJSONNumber.Create(512));
      Metrics.AddPair('namespace_sets', TJSONNumber.Create(2));
      Metrics.AddPair('processors_before', TJSONNumber.Create(ProcessorCount));
      for Cycle := 1 to 512 do
      begin
        if Odd(Cycle) then NamespaceUri := 'urn:memory-cache:first' else NamespaceUri := 'urn:memory-cache:second';
        XmlBytes := TEncoding.UTF8.GetBytes('<root xmlns="' + NamespaceUri + '" value="memory"/>');
        BaseUri := 'mggm-kosit:/native-cache/document-' + IntToStr(Cycle) + '.xml';
        Native.BeginDocumentBytes(XmlBytes, BaseUri);
        try
          Require(Native.EvaluateBooleanBytes(XmlBytes, BaseUri, 'exists(/cache:root) and /*/@value = "memory"', ['cache', NamespaceUri]),
            'Namespace oder Quelle beim Basis-URI-Wechsel veraltet');
        finally
          Native.EndDocument;
        end;
      end;
      Metrics.AddPair('processors_after', TJSONNumber.Create(Native.XPathProcessorCount));
      Metrics.AddPair('source_parses', TJSONNumber.Create(Native.SourceParseCount - ParseCount));
      Require(Native.XPathProcessorCount = ProcessorCount + 2, 'Pro Dokument-Basis-URI wurde ein zusätzlicher XPath-Prozessor erzeugt');
      Require(Native.SourceParseCount = ParseCount + 512, 'Aktive Speicherdokumente wurden mehrfach geparst');
    end);
  RunCase('XPath-Basis-URI und relative Dokumente wechseln mit Fehlerwiederherstellung',
    procedure
    var
      Cycle, ProcessorCount: Integer;
      FirstDirectory, SecondDirectory, DirectoryName, ExpectedValue, BaseUri: string;
      XmlBytes: TBytes;
      Metrics: TJSONObject;
    begin
      FirstDirectory := TPath.Combine(Root, 'memory-relative-first');
      SecondDirectory := TPath.Combine(Root, 'memory-relative-second');
      ForceDirectories(FirstDirectory);
      ForceDirectories(SecondDirectory);
      TFile.WriteAllText(TPath.Combine(FirstDirectory, 'relative.xml'), '<relative>first</relative>', TEncoding.UTF8);
      TFile.WriteAllText(TPath.Combine(SecondDirectory, 'relative.xml'), '<relative>second</relative>', TEncoding.UTF8);
      ProcessorCount := Native.XPathProcessorCount;
      Metrics := TJSONObject.Create;
      Evidence.AddPair('memory_relative_xpath', Metrics);
      Metrics.AddPair('alternations', TJSONNumber.Create(32));
      Metrics.AddPair('processors_before', TJSONNumber.Create(ProcessorCount));
      for Cycle := 1 to 32 do
      begin
        if Odd(Cycle) then
        begin
          DirectoryName := FirstDirectory;
          ExpectedValue := 'first';
        end
        else
        begin
          DirectoryName := SecondDirectory;
          ExpectedValue := 'second';
        end;
        BaseUri := TPath.Combine(DirectoryName, 'input.xml');
        XmlBytes := TEncoding.UTF8.GetBytes('<root expected="' + ExpectedValue + '"/>');
        Native.BeginDocumentBytes(XmlBytes, BaseUri);
        try
          Require(Native.EvaluateBooleanBytes(XmlBytes, BaseUri,
            'ends-with(base-uri(/), concat("/memory-relative-", string(/*/@expected), "/input.xml"))', ['relative', 'urn:memory-relative']),
            'Der XDM-Basis-URI verweist nicht auf die aktuelle Originalquelle');
          Require(Native.EvaluateBooleanBytes(XmlBytes, BaseUri,
            'ends-with(static-base-uri(), concat("/memory-relative-", string(/*/@expected), "/"))', ['relative', 'urn:memory-relative']),
            'Die statische XPath-Basis löst nicht im aktuellen Quellverzeichnis auf');
          Require(Native.EvaluateBooleanBytes(XmlBytes, BaseUri, 'string(doc("relative.xml")/*) = string(/*/@expected)', ['relative', 'urn:memory-relative']),
            'Das relative XPath-Dokument stammt aus dem falschen Fixtureordner');
        finally
          Native.EndDocument;
        end;
      end;
      XmlBytes := TEncoding.UTF8.GetBytes('<root expected="first"/>');
      BaseUri := TPath.Combine(Root, 'missing-memory-relative\input.xml');
      Native.BeginDocumentBytes(XmlBytes, BaseUri);
      try
        ExpectFailure(procedure
          begin
            Native.EvaluateBooleanBytes(XmlBytes, BaseUri, 'string(doc("relative.xml")/*) = string(/*/@expected)', ['relative', 'urn:memory-relative']);
          end);
      finally
        Native.EndDocument;
      end;
      BaseUri := TPath.Combine(FirstDirectory, 'input.xml');
      Native.BeginDocumentBytes(XmlBytes, BaseUri);
      try
        Require(Native.EvaluateBooleanBytes(XmlBytes, BaseUri, 'ends-with(static-base-uri(), "/memory-relative-first/")', ['relative', 'urn:memory-relative']),
          'Die statische XPath-Basis erholt sich nach fehlender relativer Ressource nicht');
        Require(Native.EvaluateBooleanBytes(XmlBytes, BaseUri, 'string(doc("relative.xml")/*) = string(/*/@expected)', ['relative', 'urn:memory-relative']),
          'Relative XPath-Ressourcen sind nach einem Fehler nicht mehr auswertbar');
      finally
        Native.EndDocument;
      end;
      Metrics.AddPair('processors_after', TJSONNumber.Create(Native.XPathProcessorCount));
      Require(Native.XPathProcessorCount = ProcessorCount + 1, 'Basis-URI-Wechsel oder Fehler erzeugen zusätzliche XPath-Prozessoren');
    end);
  RunCase('Speichertransformation lehnt Nebenresultate ohne Dateiausgabe ab und bleibt verwendbar',
    procedure
    var
      MemoryDirectory, BaseUri, OutputBaseUri, Diagnostic: string;
      XmlBytes, ResultBytes: TBytes;
      Rejected: Boolean;
    begin
      MemoryDirectory := TPath.Combine(Root, 'memory-secondary-output');
      ForceDirectories(MemoryDirectory);
      BaseUri := TPath.Combine(MemoryDirectory, 'input.xml');
      OutputBaseUri := TPath.Combine(MemoryDirectory, 'primary.html');
      XmlBytes := TEncoding.UTF8.GetBytes('<root xmlns="urn:first" value="memory-after-secondary"/>');
      // Dasselbe vertrauenswürdige Stylesheet hat oben den expliziten Datei-Ausgabepfad bereits nachgewiesen.
      Native.Configure('http://saxon.sf.net/feature/allow-external-functions', 'true');
      try
        Native.BeginDocumentBytes(XmlBytes, BaseUri);
        try
          Rejected := False;
          Diagnostic := '';
          try
            Native.TransformBytes(XmlBytes, BaseUri, TPath.Combine(Root, 'html.xsl'), OutputBaseUri);
          except
            on Error: EMGKositNative do
            begin
              Diagnostic := Error.Message;
              Rejected := True;
            end;
          end;
          Evidence.AddPair('memory_secondary_output_error', Diagnostic);
          Require(Length(TDirectory.GetFiles(MemoryDirectory)) = 0, 'Die Speichertransformation hat eine Haupt- oder Nebenresultatdatei angelegt');
          Require(Rejected and (Diagnostic <> ''), 'Ein xsl:result-document wurde in der Speichertransformation nicht ausdrücklich abgelehnt');
          ResultBytes := Native.TransformBytes(XmlBytes, BaseUri, StylesheetFile, OutputBaseUri, XmlBytes, BaseUri);
          Require(TEncoding.UTF8.GetString(ResultBytes) = 'memory-after-secondary|memory-after-secondary',
            'Die Speichertransformation ist nach Nebenresultatfehler defekt');
          Require(Length(TDirectory.GetFiles(MemoryDirectory)) = 0, 'Die anschließende Speichertransformation hat unerwartet eine Datei angelegt');
        finally
          Native.EndDocument;
        end;
      finally
        Native.Configure('http://saxon.sf.net/feature/allow-external-functions', 'false');
      end;
    end);
  RunCase('Speicher- und Datei-Serializer erhalten Nicht-BMP-Unicode bytegenau',
    procedure
    const
      ExpectedText = '😀𐍈ä€';
    var
      UnicodeSourceFile, UnicodeStylesheetFile, UnicodeOutputFile, BaseUri: string;
      XmlBytes, ExpectedBytes, MemoryBytes, FileBytes: TBytes;
      Metrics: TJSONObject;
    begin
      UnicodeSourceFile := TPath.Combine(Root, 'unicode-source.xml');
      UnicodeStylesheetFile := TPath.Combine(Root, 'unicode-text.xsl');
      UnicodeOutputFile := TPath.Combine(Root, 'unicode-result.txt');
      BaseUri := 'mggm-kosit:/unicode/input.xml';
      XmlBytes := TEncoding.UTF8.GetBytes('<root>' + ExpectedText + '</root>');
      // Explizite UTF-8-Bytes verhindern einen gleichartigen Verlust auf beiden Seiten eines Stringvergleichs.
      ExpectedBytes := TBytes.Create($F0, $9F, $98, $80, $F0, $90, $8D, $88, $C3, $A4, $E2, $82, $AC);
      TFile.WriteAllBytes(UnicodeSourceFile, XmlBytes);
      TFile.WriteAllText(UnicodeStylesheetFile,
        '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="3.0">' +
        '<xsl:output method="text" encoding="UTF-8" byte-order-mark="no"/>' +
        '<xsl:template match="/"><xsl:value-of select="/*"/></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
      Native.BeginDocumentBytes(XmlBytes, BaseUri);
      try
        MemoryBytes := Native.TransformBytes(XmlBytes, BaseUri, UnicodeStylesheetFile, 'mggm-kosit:/unicode/result.txt');
      finally
        Native.EndDocument;
      end;
      Require(Length(MemoryBytes) = Length(ExpectedBytes), 'Der Speicher-Serializer verändert die UTF-8-Länge der Nicht-BMP-Zeichen');
      Require(CompareMem(@MemoryBytes[0], @ExpectedBytes[0], Length(ExpectedBytes)), 'Der Speicher-Serializer verändert Surrogatpaare oder Vierbyte-UTF-8');
      Require(TEncoding.UTF8.GetString(MemoryBytes) = ExpectedText, 'Nicht-BMP-Unicode ist nach dem Speicher-Roundtrip verändert');
      Native.Transform(UnicodeSourceFile, UnicodeStylesheetFile, UnicodeOutputFile);
      FileBytes := TFile.ReadAllBytes(UnicodeOutputFile);
      Require(Length(FileBytes) = Length(ExpectedBytes), 'Die Datei-Gegenprobe verändert die UTF-8-Länge der Nicht-BMP-Zeichen');
      Require(CompareMem(@FileBytes[0], @ExpectedBytes[0], Length(ExpectedBytes)), 'Die Datei-Gegenprobe verändert Nicht-BMP-Unicode');
      Require(CompareMem(@MemoryBytes[0], @FileBytes[0], Length(ExpectedBytes)), 'Speicher- und Datei-Serializer liefern unterschiedliche UTF-8-Bytes');
      Metrics := TJSONObject.Create;
      Evidence.AddPair('memory_unicode_roundtrip', Metrics);
      Metrics.AddPair('expected_text', ExpectedText);
      Metrics.AddPair('expected_utf8_hex', 'F09F9880F0908D88C3A4E282AC');
      Metrics.AddPair('memory_output_bytes', TJSONNumber.Create(Length(MemoryBytes)));
      Metrics.AddPair('file_output_bytes', TJSONNumber.Create(Length(FileBytes)));
      Metrics.AddPair('same_source_bytes', TJSONBool.Create(True));
    end);
  RunCase('Leere Byte-Eingaben dürfen keinen aktiven Dateikontext übernehmen',
    procedure
    var
      MixedSourceFile, MixedBaseUri: string;
      XmlBytes, ActiveBytes, ResultBytes: TBytes;
      XPathRejected, TransformRejected: Boolean;
    begin
      MixedSourceFile := TPath.Combine(Root, 'mixed-context-source.xml');
      MixedBaseUri := 'mggm-kosit:/mixed-context/input.xml';
      XmlBytes := TEncoding.UTF8.GetBytes('<root xmlns="urn:first" value="mixed-context"/>');
      TFile.WriteAllBytes(MixedSourceFile, XmlBytes);
      Native.BeginDocument(MixedSourceFile);
      try
        XPathRejected := False;
        try
          Native.EvaluateBooleanBytes(nil, '', 'exists(/*)', []);
        except
          on Error: EMGKositNative do
          begin
            Require(Error.Message <> '', 'Leere Byte-XPath-Eingabe ohne Fehlerdiagnose');
            XPathRejected := True;
          end;
        end;
        Require(Native.EvaluateBoolean(MixedSourceFile, '/*/@value = "mixed-context"', []), 'Die Datei-API ist nach leerer Byte-XPath-Eingabe defekt');
        TransformRejected := False;
        try
          Native.TransformBytes(nil, '', StylesheetFile, 'mggm-kosit:/mixed-context/result.txt');
        except
          on Error: EMGKositNative do
          begin
            Require(Error.Message <> '', 'Leere Byte-XSLT-Eingabe ohne Fehlerdiagnose');
            TransformRejected := True;
          end;
        end;
        Evidence.AddPair('mixed_context_empty_xpath_rejected', TJSONBool.Create(XPathRejected));
        Evidence.AddPair('mixed_context_empty_transform_rejected', TJSONBool.Create(TransformRejected));
        Require(Native.EvaluateBoolean(MixedSourceFile, '/*/@value = "mixed-context"', []), 'Die Datei-API ist nach leerer Byte-XSLT-Eingabe defekt');
        Require(Native.EvaluateBooleanBytes(XmlBytes, MixedBaseUri, '/*/@value = "mixed-context"', []), 'Gültige Byte-Eingabe nach Fehler nicht auswertbar');
        ResultBytes := Native.TransformBytes(XmlBytes, MixedBaseUri, StylesheetFile, 'mggm-kosit:/mixed-context/result.txt');
        Require(TEncoding.UTF8.GetString(ResultBytes) = 'mixed-context|', 'Gültige Byte-Transformation nach Fehler verändert');
        Require(XPathRejected, 'Leere Byte-XPath-Eingabe hat den aktiven Dateikontext übernommen');
        Require(TransformRejected, 'Leere Byte-XSLT-Eingabe hat den aktiven Dateikontext übernommen');
      finally
        Native.EndDocument;
      end;
      // Auch ein aktiver Bytekontext darf die explizite Dateiquelle nicht ersetzen.
      ActiveBytes := TEncoding.UTF8.GetBytes('<root xmlns="urn:first" value="active-bytes"/>');
      Native.BeginDocumentBytes(ActiveBytes, MixedBaseUri);
      try
        Require(Native.EvaluateBoolean(MixedSourceFile, '/*/@value = "mixed-context"', []), 'Die Datei-API kann im aktiven Bytekontext nicht lesen');
        Require(Native.EvaluateBooleanBytes(ActiveBytes, MixedBaseUri, '/*/@value = "active-bytes"', []), 'Der aktive Bytekontext ging beim Datei-Aufruf verloren');
      finally
        Native.EndDocument;
      end;
    end);
end;

begin
  SetTextCodePage(Output, CP_UTF8);
  ExitCode := 1;
  try
    if ParamCount <> 2 then
      raise Exception.Create('Aufruf: NativeReuseTests <Saxon-DLL> <Nachweisdatei>');
    EvidenceFile := ExpandFileName(ParamStr(2));
    Root := TPath.Combine(ExtractFileDir(EvidenceFile), 'native-reuse-fixtures-' + TPath.GetRandomFileName);
    ForceDirectories(Root);
    SourceFile := TPath.Combine(Root, 'source.xml');
    ParameterFile := TPath.Combine(Root, 'parameter.xml');
    StylesheetFile := TPath.Combine(Root, 'transform.xsl');
    BadStylesheetFile := TPath.Combine(Root, 'bad.xsl');
    OutputFile := TPath.Combine(Root, 'result.txt');
    TFile.WriteAllText(StylesheetFile,
      '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="3.0">' +
      '<xsl:output method="text"/><xsl:param name="input-document" select="()"/>' +
      '<xsl:template match="/"><xsl:if test="/*/@value = ''fail''"><xsl:message terminate="yes">Testfehler</xsl:message></xsl:if>' +
      '<xsl:value-of select="concat(/*/@value, ''|'', $input-document/*/@value)"/></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
    TFile.WriteAllText(BadStylesheetFile,
      '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="3.0">' +
      '<xsl:template match="/"><xsl:value-of select="//*["/></xsl:template></xsl:stylesheet>', TEncoding.UTF8);
    Native := TMGKositNative.Create(ExpandFileName(ParamStr(1)));
    Evidence := TJSONObject.Create;
    try
      Cases := TJSONArray.Create;
      Evidence.AddPair('tests', Cases);
      ExecuteCases;
      Evidence.AddPair('passed', TJSONNumber.Create(Passed));
      Evidence.AddPair('failed', TJSONNumber.Create(Failed));
      Evidence.AddPair('stylesheet_compilation_count', TJSONNumber.Create(Native.StylesheetCompilationCount));
      Evidence.AddPair('xpath_processor_count', TJSONNumber.Create(Native.XPathProcessorCount));
      Evidence.AddPair('source_parse_count', TJSONNumber.Create(Native.SourceParseCount));
      Evidence.AddPair('fixtures', Root);
      Native.Close;
      TFile.WriteAllText(EvidenceFile, Evidence.ToJSON, TEncoding.UTF8);
      if Failed = 0 then ExitCode := 0;
    finally
      FreeAndNil(Evidence);
      FreeAndNil(Native);
    end;
  except
    on Error: Exception do WriteLn(Error.ClassName, ': ', Error.Message);
  end;
end.
