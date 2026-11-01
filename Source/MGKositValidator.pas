unit MGKositValidator;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  Winapi.MSXML,
  MGKositTypes, MGKositEngine;

type
  TMGKositScenarioDefinition = class
  public
    Document: IXMLDOMDocument3;
    Node: IXMLDOMNode;
    RepositoryDirectory: string;
  end;

  TMGKositValidator = class
  private
    FEngine: TMGKositEngine;
    FScenarios: TObjectList<TMGKositScenarioDefinition>;
    FResourceRoots: TArray<string>;
    FNoScenarioReport: string;
    FSvrlProjectionMs: Double;
    function GetScenarioCount: Integer;
    function GetStatistics: TMGKositStatistics;
    function ValidateInternal(const XmlBytes: TBytes; const SourceUri, Reference: string): TMGKositValidationResult;
    procedure RegisterFrameworkResources;
  public
    constructor Create(const SaxonLibraryFile: string = '');
    destructor Destroy; override;
    procedure AddScenario(const ScenarioFile: string; const RepositoryDirectory: string = '');
    function ValidateFile(const XmlFile: string; const Reference: string = ''): TMGKositValidationResult;
    function ValidateStream(Stream: TStream; const Reference: string = ''): TMGKositValidationResult;
    property ScenarioCount: Integer read GetScenarioCount;
    property Statistics: TMGKositStatistics read GetStatistics;
  end;

implementation

uses
  System.IOUtils, System.Hash, System.NetEncoding, System.DateUtils, System.Variants, System.Diagnostics, Winapi.Windows,
  MGKositNative;

const
  UnitName = 'MGKositValidator';
  ScenarioNamespace = 'http://www.xoev.de/de/validator/framework/1/scenarios';
  InputNamespace = 'http://www.xoev.de/de/validator/framework/1/createreportinput';
  SvrlNamespace = 'http://purl.oclc.org/dsdl/svrl';
  ReportNamespace = 'http://www.xoev.de/de/validator/varl/1';
  HtmlNamespace = 'http://www.w3.org/1999/xhtml';
  FrameworkUri = 'mggm-kosit:/framework/';
  StreamDocumentUri = 'mggm-kosit:/input/input.xml';
  HtmlSerializationStylesheet =
    '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:h="http://www.w3.org/1999/xhtml" version="2.0">' +
    '<xsl:output method="xhtml" encoding="UTF-8" omit-xml-declaration="no" indent="no"/>' +
    '<xsl:template match="/"><xsl:copy-of select="(//h:html[@data-report-type=''report''], //h:html)[1]"/></xsl:template></xsl:stylesheet>';

// Die eingebetteten Frameworkdateien stammen unverändert aus dem KoSIT-Validator.
  // Szenariokonfiguration prüfen; Original scenarios.xsd aus src/main/model/xsd/scenarios.xsd im KoSIT-Repository.
  FrameworkScenariosSchemaBase64 =
    'PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiID8+Cjx4czpzY2hlbWEgeG1sbnM6eHM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDEvWE1MU2NoZW1hIiB4' +
    'bWxuczpzPSJodHRwOi8vd3d3LnhvZXYuZGUvZGUvdmFsaWRhdG9yL2ZyYW1ld29yay8xL3NjZW5hcmlvcyIgdGFyZ2V0TmFtZXNwYWNlPSJodHRwOi8vd3d3LnhvZXYu' +
    'ZGUvZGUvdmFsaWRhdG9yL2ZyYW1ld29yay8xL3NjZW5hcmlvcyIgdmVyc2lvbj0iMS4xLjAiIGVsZW1lbnRGb3JtRGVmYXVsdD0icXVhbGlmaWVkIiBhdHRyaWJ1dGVG' +
    'b3JtRGVmYXVsdD0idW5xdWFsaWZpZWQiPgoKICAgIDx4czplbGVtZW50IG5hbWU9InNjZW5hcmlvcyI+CiAgICAgICAgPHhzOmNvbXBsZXhUeXBlPgogICAgICAgICAg' +
    'ICA8eHM6c2VxdWVuY2U+CiAgICAgICAgICAgICAgICA8eHM6ZWxlbWVudCBuYW1lPSJuYW1lIiB0eXBlPSJ4czp0b2tlbiIgLz4KICAgICAgICAgICAgICAgIDx4czpl' +
    'bGVtZW50IG1pbk9jY3Vycz0iMCIgbmFtZT0iYXV0aG9yIiB0eXBlPSJ4czp0b2tlbiIgLz4KICAgICAgICAgICAgICAgIDx4czplbGVtZW50IG5hbWU9ImRhdGUiIHR5' +
    'cGU9InhzOmRhdGUiIC8+CiAgICAgICAgICAgICAgICA8eHM6ZWxlbWVudCBuYW1lPSJkZXNjcmlwdGlvbiIgdHlwZT0iczpEZXNjcmlwdGlvblR5cGUiIC8+CiAgICAg' +
    'ICAgICAgICAgICA8eHM6ZWxlbWVudCByZWY9InM6c2NlbmFyaW8iIG1pbk9jY3Vycz0iMSIgbWF4T2NjdXJzPSJ1bmJvdW5kZWQiIC8+CiAgICAgICAgICAgICAgICA8' +
    'eHM6ZWxlbWVudCBuYW1lPSJub1NjZW5hcmlvUmVwb3J0IiB0eXBlPSJzOk5vU2NlbmFyaW9SZXBvcnRUeXBlIiAvPgogICAgICAgICAgICA8L3hzOnNlcXVlbmNlPgog' +
    'ICAgICAgICAgICA8eHM6YXR0cmlidXRlIG5hbWU9ImZyYW1ld29ya1ZlcnNpb24iIHR5cGU9InhzOnN0cmluZyIgdXNlPSJyZXF1aXJlZCIgLz4KICAgICAgICA8L3hz' +
    'OmNvbXBsZXhUeXBlPgogICAgPC94czplbGVtZW50PgoKICAgIDx4czplbGVtZW50IG5hbWU9InNjZW5hcmlvIiB0eXBlPSJzOlNjZW5hcmlvVHlwZSIgLz4KCiAgICA8' +
    'eHM6Y29tcGxleFR5cGUgbmFtZT0iTm9TY2VuYXJpb1JlcG9ydFR5cGUiPgogICAgICAgIDx4czpzZXF1ZW5jZT4KICAgICAgICAgICAgPHhzOmVsZW1lbnQgcmVmPSJz' +
    'OnJlc291cmNlIiAvPgogICAgICAgIDwveHM6c2VxdWVuY2U+CiAgICA8L3hzOmNvbXBsZXhUeXBlPgoKICAgIDx4czpjb21wbGV4VHlwZSBuYW1lPSJEZXNjcmlwdGlv' +
    'blR5cGUiPgogICAgICAgIDx4czpjaG9pY2UgbWF4T2NjdXJzPSJ1bmJvdW5kZWQiPgogICAgICAgICAgICA8eHM6ZWxlbWVudCBuYW1lPSJwIiB0eXBlPSJ4czpub3Jt' +
    'YWxpemVkU3RyaW5nIiAvPgogICAgICAgICAgICA8eHM6ZWxlbWVudCBuYW1lPSJvbCI+CiAgICAgICAgICAgICAgICA8eHM6Y29tcGxleFR5cGU+CiAgICAgICAgICAg' +
    'ICAgICAgICAgPHhzOnNlcXVlbmNlPgogICAgICAgICAgICAgICAgICAgICAgICA8eHM6ZWxlbWVudCBtYXhPY2N1cnM9InVuYm91bmRlZCIgbmFtZT0ibGkiIHR5cGU9' +
    'InhzOm5vcm1hbGl6ZWRTdHJpbmciIC8+CiAgICAgICAgICAgICAgICAgICAgPC94czpzZXF1ZW5jZT4KICAgICAgICAgICAgICAgIDwveHM6Y29tcGxleFR5cGU+CiAg' +
    'ICAgICAgICAgIDwveHM6ZWxlbWVudD4KICAgICAgICAgICAgPHhzOmVsZW1lbnQgbmFtZT0idWwiPgogICAgICAgICAgICAgICAgPHhzOmNvbXBsZXhUeXBlPgogICAg' +
    'ICAgICAgICAgICAgICAgIDx4czpzZXF1ZW5jZT4KICAgICAgICAgICAgICAgICAgICAgICAgPHhzOmVsZW1lbnQgbWF4T2NjdXJzPSJ1bmJvdW5kZWQiIG5hbWU9Imxp' +
    'IiB0eXBlPSJ4czpub3JtYWxpemVkU3RyaW5nIiAvPgogICAgICAgICAgICAgICAgICAgIDwveHM6c2VxdWVuY2U+CiAgICAgICAgICAgICAgICA8L3hzOmNvbXBsZXhU' +
    'eXBlPgogICAgICAgICAgICA8L3hzOmVsZW1lbnQ+CiAgICAgICAgPC94czpjaG9pY2U+CiAgICA8L3hzOmNvbXBsZXhUeXBlPgoKICAgIDwhLS0gVE9ETzogUHLDvGZl' +
    'biwgb2IgcmVzdHJpY3Rpb24gcGFzc3QgLS0+CiAgICA8eHM6c2ltcGxlVHlwZSBuYW1lPSJFcnJvckxldmVsVHlwZSI+CiAgICAgICAgPHhzOnJlc3RyaWN0aW9uIGJh' +
    'c2U9InhzOnRva2VuIj4KICAgICAgICAgICAgPHhzOmVudW1lcmF0aW9uIHZhbHVlPSJlcnJvciIgLz4KICAgICAgICAgICAgPHhzOmVudW1lcmF0aW9uIHZhbHVlPSJ3' +
    'YXJuaW5nIiAvPgogICAgICAgICAgICA8eHM6ZW51bWVyYXRpb24gdmFsdWU9ImluZm9ybWF0aW9uIiAvPgogICAgICAgIDwveHM6cmVzdHJpY3Rpb24+CiAgICA8L3hz' +
    'OnNpbXBsZVR5cGU+CgogICAgPHhzOnNpbXBsZVR5cGUgbmFtZT0iVG9rZW5zIj4KICAgICAgICA8eHM6bGlzdCBpdGVtVHlwZT0ieHM6dG9rZW4iIC8+CiAgICA8L3hz' +
    'OnNpbXBsZVR5cGU+CiAgICAKICAgIDx4czpzaW1wbGVUeXBlIG5hbWU9Ik5vbkVtcHR5U3RyaW5nIj4KICAgICAgPHhzOnJlc3RyaWN0aW9uIGJhc2U9InhzOnN0cmlu' +
    'ZyI+CiAgICAgICAgPHhzOm1pbkxlbmd0aCB2YWx1ZT0iMSIvPgogICAgICA8L3hzOnJlc3RyaWN0aW9uPiAgCiAgICA8L3hzOnNpbXBsZVR5cGU+CgogICAgPHhzOmNv' +
    'bXBsZXhUeXBlIG5hbWU9IlNjZW5hcmlvVHlwZSI+CiAgICAgICAgPHhzOnNlcXVlbmNlPgogICAgICAgICAgICA8eHM6ZWxlbWVudCBuYW1lPSJuYW1lIiB0eXBlPSJ4' +
    'czp0b2tlbiIgLz4KICAgICAgICAgICAgPHhzOmVsZW1lbnQgbWluT2NjdXJzPSIwIiBuYW1lPSJkZXNjcmlwdGlvbiIgdHlwZT0iczpEZXNjcmlwdGlvblR5cGUiIC8+' +
    'CiAgICAgICAgICAgIDx4czplbGVtZW50IG1pbk9jY3Vycz0iMCIgbWF4T2NjdXJzPSJ1bmJvdW5kZWQiIG5hbWU9Im5hbWVzcGFjZSIgdHlwZT0iczpOYW1lc3BhY2VU' +
    'eXBlIiAvPgogICAgICAgICAgICA8eHM6ZWxlbWVudCBuYW1lPSJtYXRjaCIgdHlwZT0iczpOb25FbXB0eVN0cmluZyIgLz4KICAgICAgICAgICAgPHhzOmVsZW1lbnQg' +
    'bmFtZT0idmFsaWRhdGVXaXRoWG1sU2NoZW1hIiB0eXBlPSJzOlZhbGlkYXRlV2l0aFhtbFNjaGVtYSIgLz4KICAgICAgICAgICAgPHhzOmVsZW1lbnQgbmFtZT0idmFs' +
    'aWRhdGVXaXRoU2NoZW1hdHJvbiIgbWF4T2NjdXJzPSJ1bmJvdW5kZWQiIG1pbk9jY3Vycz0iMCIgdHlwZT0iczpWYWxpZGF0ZVdpdGhTY2hlbWF0cm9uIiAvPgogICAg' +
    'ICAgICAgICA8eHM6ZWxlbWVudCBuYW1lPSJjcmVhdGVSZXBvcnQiIHR5cGU9InM6Q3JlYXRlUmVwb3J0VHlwZSIgbWluT2NjdXJzPSIwIi8+CiAgICAgICAgICAgIDx4' +
    'czplbGVtZW50IG5hbWU9ImFjY2VwdE1hdGNoIiB0eXBlPSJ4czpzdHJpbmciIG1pbk9jY3Vycz0iMCI+CiAgICAgICAgICAgICAgICA8eHM6YW5ub3RhdGlvbj4KICAg' +
    'ICAgICAgICAgICAgICAgICA8eHM6ZG9jdW1lbnRhdGlvbj4KICAgICAgICAgICAgICAgICAgICAgICAgT3B0aW9uYWw6IEFuIFhQQVRIIGV4cHJlc3Npb24gdG8gYmUg' +
    'YXBwbGllZCB0byBhIGdlbmVyYXRlZCB2YWxpZGF0aW9uIHJlcG9ydCBhcyBkZWZpbmVkIGluIHRoZSBjcmVhdGVSZXBvcnQgZWxlbWVudAogICAgICAgICAgICAgICAg' +
    'ICAgIDwveHM6ZG9jdW1lbnRhdGlvbj4KICAgICAgICAgICAgICAgIDwveHM6YW5ub3RhdGlvbj4KICAgICAgICAgICAgPC94czplbGVtZW50PgogICAgICAgIDwveHM6' +
    'c2VxdWVuY2U+CiAgICA8L3hzOmNvbXBsZXhUeXBlPgoKICAgIDx4czplbGVtZW50IG5hbWU9InJlc291cmNlIiB0eXBlPSJzOlJlc291cmNlVHlwZSIgLz4KCiAgICA8' +
    'eHM6Y29tcGxleFR5cGUgbmFtZT0iTmFtZXNwYWNlVHlwZSI+CiAgICAgICAgPHhzOnNpbXBsZUNvbnRlbnQ+CiAgICAgICAgICAgIDx4czpleHRlbnNpb24gYmFzZT0i' +
    'eHM6YW55VVJJIj4KICAgICAgICAgICAgICAgIDx4czphdHRyaWJ1dGUgbmFtZT0icHJlZml4IiB1c2U9InJlcXVpcmVkIiAvPgogICAgICAgICAgICA8L3hzOmV4dGVu' +
    'c2lvbj4KICAgICAgICA8L3hzOnNpbXBsZUNvbnRlbnQ+CiAgICA8L3hzOmNvbXBsZXhUeXBlPgoKICAgIDx4czpjb21wbGV4VHlwZSBuYW1lPSJSZXNvdXJjZVR5cGUi' +
    'PgogICAgICAgIDx4czpzZXF1ZW5jZT4KICAgICAgICAgICAgPHhzOmVsZW1lbnQgbmFtZT0ibmFtZSIgdHlwZT0ieHM6dG9rZW4iIC8+CiAgICAgICAgICAgIDx4czpl' +
    'bGVtZW50IG5hbWU9ImxvY2F0aW9uIiB0eXBlPSJ4czphbnlVUkkiIC8+CiAgICAgICAgPC94czpzZXF1ZW5jZT4KICAgIDwveHM6Y29tcGxleFR5cGU+CgogICAgPHhz' +
    'OmNvbXBsZXhUeXBlIG5hbWU9IlZhbGlkYXRlV2l0aFhtbFNjaGVtYSI+CiAgICAgICAgPHhzOnNlcXVlbmNlPgogICAgICAgICAgICA8eHM6ZWxlbWVudCByZWY9InM6' +
    'cmVzb3VyY2UiIG1heE9jY3Vycz0idW5ib3VuZGVkIiAvPgogICAgICAgIDwveHM6c2VxdWVuY2U+CiAgICA8L3hzOmNvbXBsZXhUeXBlPgoKICAgIDx4czpjb21wbGV4' +
    'VHlwZSBuYW1lPSJWYWxpZGF0ZVdpdGhTY2hlbWF0cm9uIj4KICAgICAgICA8eHM6c2VxdWVuY2U+CiAgICAgICAgICAgIDx4czplbGVtZW50IHJlZj0iczpyZXNvdXJj' +
    'ZSIgLz4KICAgICAgICA8L3hzOnNlcXVlbmNlPgogICAgICAgIDx4czphdHRyaWJ1dGUgbmFtZT0icHN2aSIgdHlwZT0ieHM6Ym9vbGVhbiIgZGVmYXVsdD0iZmFsc2Ui' +
    'IHVzZT0ib3B0aW9uYWwiIC8+CiAgICA8L3hzOmNvbXBsZXhUeXBlPgoKCiAgICA8eHM6Y29tcGxleFR5cGUgbmFtZT0iQ3JlYXRlUmVwb3J0VHlwZSI+CiAgICAgICAg' +
    'PHhzOnNlcXVlbmNlPgogICAgICAgICAgICA8eHM6ZWxlbWVudCByZWY9InM6cmVzb3VyY2UiIC8+CiAgICAgICAgICAgIDx4czplbGVtZW50IG1heE9jY3Vycz0idW5i' +
    'b3VuZGVkIiBtaW5PY2N1cnM9IjAiIG5hbWU9ImN1c3RvbUxldmVsIiB0eXBlPSJzOkN1c3RvbUVycm9yTGV2ZWwiIC8+CiAgICAgICAgPC94czpzZXF1ZW5jZT4KICAg' +
    'IDwveHM6Y29tcGxleFR5cGU+CgogICAgPHhzOmNvbXBsZXhUeXBlIG5hbWU9IkN1c3RvbUVycm9yTGV2ZWwiPgogICAgICAgIDx4czpzaW1wbGVDb250ZW50PgogICAg' +
    'ICAgICAgICA8eHM6ZXh0ZW5zaW9uIGJhc2U9InM6VG9rZW5zIj4KICAgICAgICAgICAgICAgIDx4czphdHRyaWJ1dGUgbmFtZT0ibGV2ZWwiIHR5cGU9InM6RXJyb3JM' +
    'ZXZlbFR5cGUiIHVzZT0icmVxdWlyZWQiIC8+CiAgICAgICAgICAgIDwveHM6ZXh0ZW5zaW9uPgogICAgICAgIDwveHM6c2ltcGxlQ29udGVudD4KICAgIDwveHM6Y29t' +
    'cGxleFR5cGU+CjwveHM6c2NoZW1hPgo8IS0tCiAgfiBDb3B5cmlnaHQgMjAxNy0yMDI2ICBLb29yZGluaWVydW5nc3N0ZWxsZSBmw7xyIElULVN0YW5kYXJkcyAoS29T' +
    'SVQpCiAgfgogIH4gTGljZW5zZWQgdW5kZXIgdGhlIEFwYWNoZSBMaWNlbnNlLCBWZXJzaW9uIDIuMCAodGhlICJMaWNlbnNlIik7CiAgfiB5b3UgbWF5IG5vdCB1c2Ug' +
    'dGhpcyBmaWxlIGV4Y2VwdCBpbiBjb21wbGlhbmNlIHdpdGggdGhlIExpY2Vuc2UuCiAgfiBZb3UgbWF5IG9idGFpbiBhIGNvcHkgb2YgdGhlIExpY2Vuc2UgYXQKICB+' +
    'CiAgfiAgICAgaHR0cDovL3d3dy5hcGFjaGUub3JnL2xpY2Vuc2VzL0xJQ0VOU0UtMi4wCiAgfgogIH4gVW5sZXNzIHJlcXVpcmVkIGJ5IGFwcGxpY2FibGUgbGF3IG9y' +
    'IGFncmVlZCB0byBpbiB3cml0aW5nLCBzb2Z0d2FyZQogIH4gZGlzdHJpYnV0ZWQgdW5kZXIgdGhlIExpY2Vuc2UgaXMgZGlzdHJpYnV0ZWQgb24gYW4gIkFTIElTIiBC' +
    'QVNJUywKICB+IFdJVEhPVVQgV0FSUkFOVElFUyBPUiBDT05ESVRJT05TIE9GIEFOWSBLSU5ELCBlaXRoZXIgZXhwcmVzcyBvciBpbXBsaWVkLgogIH4gU2VlIHRoZSBM' +
    'aWNlbnNlIGZvciB0aGUgc3BlY2lmaWMgbGFuZ3VhZ2UgZ292ZXJuaW5nIHBlcm1pc3Npb25zIGFuZAogIH4gbGltaXRhdGlvbnMgdW5kZXIgdGhlIExpY2Vuc2UuCiAg' +
    'LS0+Cg==';
  // Interne Berichtseingabe prüfen; Original createReportInput.xsd aus src/main/model/xsd/createReportInput.xsd im KoSIT-Repository.
  FrameworkReportInputSchemaBase64 =
    'PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPCEtLQogIH4gQ29weXJpZ2h0IDIwMTctMjAyMiAgS29vcmRpbmllcnVuZ3NzdGVsbGUgZsO8ciBJ' +
    'VC1TdGFuZGFyZHMgKEtvU0lUKQogIH4KICB+IExpY2Vuc2VkIHVuZGVyIHRoZSBBcGFjaGUgTGljZW5zZSwgVmVyc2lvbiAyLjAgKHRoZSAiTGljZW5zZSIpOwogIH4g' +
    'eW91IG1heSBub3QgdXNlIHRoaXMgZmlsZSBleGNlcHQgaW4gY29tcGxpYW5jZSB3aXRoIHRoZSBMaWNlbnNlLgogIH4gWW91IG1heSBvYnRhaW4gYSBjb3B5IG9mIHRo' +
    'ZSBMaWNlbnNlIGF0CiAgfgogIH4gICAgIGh0dHA6Ly93d3cuYXBhY2hlLm9yZy9saWNlbnNlcy9MSUNFTlNFLTIuMAogIH4KICB+IFVubGVzcyByZXF1aXJlZCBieSBh' +
    'cHBsaWNhYmxlIGxhdyBvciBhZ3JlZWQgdG8gaW4gd3JpdGluZywgc29mdHdhcmUKICB+IGRpc3RyaWJ1dGVkIHVuZGVyIHRoZSBMaWNlbnNlIGlzIGRpc3RyaWJ1dGVk' +
    'IG9uIGFuICJBUyBJUyIgQkFTSVMsCiAgfiBXSVRIT1VUIFdBUlJBTlRJRVMgT1IgQ09ORElUSU9OUyBPRiBBTlkgS0lORCwgZWl0aGVyIGV4cHJlc3Mgb3IgaW1wbGll' +
    'ZC4KICB+IFNlZSB0aGUgTGljZW5zZSBmb3IgdGhlIHNwZWNpZmljIGxhbmd1YWdlIGdvdmVybmluZyBwZXJtaXNzaW9ucyBhbmQKICB+IGxpbWl0YXRpb25zIHVuZGVy' +
    'IHRoZSBMaWNlbnNlLgogIC0tPgoKPCEtLSAkSWQkIC0tPgo8eHM6c2NoZW1hIHhtbG5zOnhzPSJodHRwOi8vd3d3LnczLm9yZy8yMDAxL1hNTFNjaGVtYSIgeG1sbnM6' +
    'aW49Imh0dHA6Ly93d3cueG9ldi5kZS9kZS92YWxpZGF0b3IvZnJhbWV3b3JrLzEvY3JlYXRlcmVwb3J0aW5wdXQiCiAgICAgICAgICAgeG1sbnM6cz0iaHR0cDovL3d3' +
    'dy54b2V2LmRlL2RlL3ZhbGlkYXRvci9mcmFtZXdvcmsvMS9zY2VuYXJpb3MiIHhtbG5zOnN2cmw9Imh0dHA6Ly9wdXJsLm9jbGMub3JnL2RzZGwvc3ZybCIKICAgICAg' +
    'ICAgICB0YXJnZXROYW1lc3BhY2U9Imh0dHA6Ly93d3cueG9ldi5kZS9kZS92YWxpZGF0b3IvZnJhbWV3b3JrLzEvY3JlYXRlcmVwb3J0aW5wdXQiIHZlcnNpb249IjEu' +
    'MC4yIgogICAgICAgICAgIGVsZW1lbnRGb3JtRGVmYXVsdD0icXVhbGlmaWVkIiBhdHRyaWJ1dGVGb3JtRGVmYXVsdD0idW5xdWFsaWZpZWQiPgoKICAgIDx4czppbXBv' +
    'cnQgbmFtZXNwYWNlPSJodHRwOi8vd3d3LnhvZXYuZGUvZGUvdmFsaWRhdG9yL2ZyYW1ld29yay8xL3NjZW5hcmlvcyIgc2NoZW1hTG9jYXRpb249InNjZW5hcmlvcy54' +
    'c2QiIC8+CiAgICA8eHM6aW1wb3J0IG5hbWVzcGFjZT0iaHR0cDovL3B1cmwub2NsYy5vcmcvZHNkbC9zdnJsIiBzY2hlbWFMb2NhdGlvbj0ic3ZybC1rb3NpdC54c2Qi' +
    'IC8+CgogICAgPHhzOmVsZW1lbnQgbmFtZT0iY3JlYXRlUmVwb3J0SW5wdXQiPgogICAgICAgIDx4czpjb21wbGV4VHlwZT4KICAgICAgICAgICAgPHhzOnNlcXVlbmNl' +
    'PgogICAgICAgICAgICAgICAgPHhzOmVsZW1lbnQgbmFtZT0iZW5naW5lIiB0eXBlPSJpbjpFbmdpbmVUeXBlIiAvPgogICAgICAgICAgICAgICAgPHhzOmVsZW1lbnQg' +
    'bmFtZT0idGltZXN0YW1wIiB0eXBlPSJ4czpkYXRlVGltZSIgLz4KICAgICAgICAgICAgICAgIDx4czplbGVtZW50IG5hbWU9ImRvY3VtZW50SWRlbnRpZmljYXRpb24i' +
    'IHR5cGU9ImluOkRvY3VtZW50SWRlbnRpZmljYXRpb25UeXBlIiAvPgogICAgICAgICAgICAgICAgPHhzOmVsZW1lbnQgcmVmPSJzOnNjZW5hcmlvIiBtaW5PY2N1cnM9' +
    'IjAiIC8+CiAgICAgICAgICAgICAgICA8eHM6ZWxlbWVudCBuYW1lPSJ2YWxpZGF0aW9uUmVzdWx0c1dlbGxmb3JtZWRuZXNzIiB0eXBlPSJpbjpWYWxpZGF0aW9uUmVz' +
    'dWx0c1dlbGxmb3JtZWRuZXNzIiBtaW5PY2N1cnM9IjAiIC8+CiAgICAgICAgICAgICAgICA8eHM6ZWxlbWVudCBuYW1lPSJ2YWxpZGF0aW9uUmVzdWx0c1htbFNjaGVt' +
    'YSIgdHlwZT0iaW46VmFsaWRhdGlvblJlc3VsdHNYbWxTY2hlbWEiIG1pbk9jY3Vycz0iMCIgLz4KICAgICAgICAgICAgICAgIDx4czplbGVtZW50IG5hbWU9InZhbGlk' +
    'YXRpb25SZXN1bHRzU2NoZW1hdHJvbiIgdHlwZT0iaW46VmFsaWRhdGlvblJlc3VsdHNTY2hlbWF0cm9uIiBtaW5PY2N1cnM9IjAiIG1heE9jY3Vycz0idW5ib3VuZGVk' +
    'IiAvPgogICAgICAgICAgICAgICAgPHhzOmVsZW1lbnQgbmFtZT0icHJvY2Vzc2luZ0Vycm9yIiB0eXBlPSJpbjpQcm9jZXNzaW5nRXJyb3IiIG1pbk9jY3Vycz0iMCIg' +
    'Lz4KICAgICAgICAgICAgPC94czpzZXF1ZW5jZT4KICAgICAgICAgICAgPHhzOmF0dHJpYnV0ZSBuYW1lPSJmcmFtZXdvcmtWZXJzaW9uIiB0eXBlPSJ4czpzdHJpbmci' +
    'IHVzZT0icmVxdWlyZWQiLz4KICAgICAgICA8L3hzOmNvbXBsZXhUeXBlPgogICAgPC94czplbGVtZW50PgoKICAgIDx4czpjb21wbGV4VHlwZSBuYW1lPSJEb2N1bWVu' +
    'dCI+CiAgICAgICAgPHhzOnNlcXVlbmNlPgogICAgICAgICAgICA8eHM6YW55IHByb2Nlc3NDb250ZW50cz0ic2tpcCIgbmFtZXNwYWNlPSIjI2FueSIvPgogICAgICAg' +
    'IDwveHM6c2VxdWVuY2U+CiAgICA8L3hzOmNvbXBsZXhUeXBlPgoKICAgIDx4czpjb21wbGV4VHlwZSBuYW1lPSJWYWxpZGF0aW9uUmVzdWx0c1dlbGxmb3JtZWRuZXNz' +
    'Ij4KICAgICAgICA8eHM6c2VxdWVuY2U+CiAgICAgICAgICAgIDx4czplbGVtZW50IG5hbWU9InhtbFN5bnRheEVycm9yIiB0eXBlPSJpbjpYTUxTeW50YXhFcnJvciIg' +
    'bWluT2NjdXJzPSIwIiBtYXhPY2N1cnM9InVuYm91bmRlZCIvPgogICAgICAgIDwveHM6c2VxdWVuY2U+CiAgICA8L3hzOmNvbXBsZXhUeXBlPgoKICAgIDx4czpjb21w' +
    'bGV4VHlwZSBuYW1lPSJWYWxpZGF0aW9uUmVzdWx0c1htbFNjaGVtYSI+CiAgICAgICAgPHhzOnNlcXVlbmNlPgogICAgICAgICAgICA8eHM6ZWxlbWVudCByZWY9InM6' +
    'cmVzb3VyY2UiIG1heE9jY3Vycz0idW5ib3VuZGVkIi8+CiAgICAgICAgICAgIDx4czplbGVtZW50IG5hbWU9InhtbFN5bnRheEVycm9yIiB0eXBlPSJpbjpYTUxTeW50' +
    'YXhFcnJvciIgbWluT2NjdXJzPSIwIiBtYXhPY2N1cnM9InVuYm91bmRlZCIvPgogICAgICAgIDwveHM6c2VxdWVuY2U+CiAgICA8L3hzOmNvbXBsZXhUeXBlPgoKICAg' +
    'IDx4czphbm5vdGF0aW9uPgogICAgICAgIDx4czpkb2N1bWVudGF0aW9uPkluIGFsaWdubWVudCB3aXRoIAogICAgICAgICAgICBodHRwOi8vZG9jcy5vcmFjbGUuY29t' +
    'L2phdmFzZS84L2RvY3MvYXBpL29yZy94bWwvc2F4L0Vycm9ySGFuZGxlci5odG1sIGFuZCAKICAgICAgICAgICAgaHR0cDovL2RvY3Mub3JhY2xlLmNvbS9qYXZhc2Uv' +
    'OC9kb2NzL2FwaS9vcmcveG1sL3NheC9TQVhQYXJzZUV4Y2VwdGlvbi5odG1sPC94czpkb2N1bWVudGF0aW9uPgogICAgPC94czphbm5vdGF0aW9uPgogICAgPHhzOmNv' +
    'bXBsZXhUeXBlIG5hbWU9IlhNTFN5bnRheEVycm9yIj4KICAgICAgICA8eHM6c2VxdWVuY2U+CiAgICAgICAgICAgIDx4czplbGVtZW50IG5hbWU9Im1lc3NhZ2UiIHR5' +
    'cGU9InhzOm5vcm1hbGl6ZWRTdHJpbmciLz4KICAgICAgICAgICAgPHhzOmVsZW1lbnQgbmFtZT0ic2V2ZXJpdHlDb2RlIiB0eXBlPSJpbjpYTUxTeW50YXhFcnJvclNl' +
    'dmVyaXR5IiAvPgogICAgICAgICAgICA8eHM6ZWxlbWVudCBuYW1lPSJyb3dOdW1iZXIiIHR5cGU9InhzOmludCIgbWluT2NjdXJzPSIwIi8+CiAgICAgICAgICAgIDx4' +
    'czplbGVtZW50IG5hbWU9ImNvbHVtbk51bWJlciIgdHlwZT0ieHM6aW50IiBtaW5PY2N1cnM9IjAiLz4KICAgICAgICA8L3hzOnNlcXVlbmNlPgogICAgPC94czpjb21w' +
    'bGV4VHlwZT4KCiAgICA8eHM6c2ltcGxlVHlwZSBuYW1lPSJYTUxTeW50YXhFcnJvclNldmVyaXR5Ij4KICAgICAgICA8eHM6cmVzdHJpY3Rpb24gYmFzZT0ieHM6dG9r' +
    'ZW4iPgogICAgICAgICAgICA8eHM6ZW51bWVyYXRpb24gdmFsdWU9IlNFVkVSSVRZX1dBUk5JTkciLz4KICAgICAgICAgICAgPHhzOmVudW1lcmF0aW9uIHZhbHVlPSJT' +
    'RVZFUklUWV9FUlJPUiIvPgogICAgICAgICAgICA8eHM6ZW51bWVyYXRpb24gdmFsdWU9IlNFVkVSSVRZX0ZBVEFMX0VSUk9SIi8+CiAgICAgICAgPC94czpyZXN0cmlj' +
    'dGlvbj4KICAgIDwveHM6c2ltcGxlVHlwZT4KCiAgICA8eHM6Y29tcGxleFR5cGUgbmFtZT0iVmFsaWRhdGlvblJlc3VsdHNTY2hlbWF0cm9uIj4KICAgICAgICA8eHM6' +
    'c2VxdWVuY2U+CiAgICAgICAgICAgIDx4czplbGVtZW50IHJlZj0iczpyZXNvdXJjZSIvPgogICAgICAgICAgICA8eHM6ZWxlbWVudCBuYW1lPSJyZXN1bHRzIj4KICAg' +
    'ICAgICAgICAgICAgIDx4czpjb21wbGV4VHlwZT4KICAgICAgICAgICAgICAgICAgICA8eHM6c2VxdWVuY2U+CiAgICAgICAgICAgICAgICAgICAgICAgIDx4czplbGVt' +
    'ZW50IHJlZj0ic3ZybDpzY2hlbWF0cm9uLW91dHB1dCIgLz4KICAgICAgICAgICAgICAgICAgICA8L3hzOnNlcXVlbmNlPgogICAgICAgICAgICAgICAgPC94czpjb21w' +
    'bGV4VHlwZT4KICAgICAgICAgICAgPC94czplbGVtZW50PgogICAgICAgIDwveHM6c2VxdWVuY2U+CiAgICA8L3hzOmNvbXBsZXhUeXBlPgoKICAgIDx4czpjb21wbGV4' +
    'VHlwZSBuYW1lPSJEb2N1bWVudElkZW50aWZpY2F0aW9uVHlwZSI+CiAgICAgICAgPHhzOmFubm90YXRpb24+CiAgICAgICAgICAgIDx4czpkb2N1bWVudGF0aW9uPkRp' +
    'ZW50IGRlciBlaW5kZXV0aWdlbiBJZGVudGlmaWthdGlvbiBkZXMgZ2VwcsO8ZnRlbiBEb2t1bWVudHMgYW5oYW5kIHNlaW5lcyBIYXNod2VydGVzLCBkZXIgZHVyY2gg' +
    'ZWluZSBEb2t1bWVudGVucmVmZXJlbnoKICAgICAgICAgICAgICAgIGVyZ8Okbnp0IHdlcmRlbiBrYW5uLjwveHM6ZG9jdW1lbnRhdGlvbj4KICAgICAgICA8L3hzOmFu' +
    'bm90YXRpb24+CiAgICAgICAgPHhzOnNlcXVlbmNlPgogICAgICAgICAgICA8eHM6ZWxlbWVudCBuYW1lPSJkb2N1bWVudEhhc2giPgogICAgICAgICAgICAgICAgPHhz' +
    'OmFubm90YXRpb24+CiAgICAgICAgICAgICAgICAgICAgPHhzOmRvY3VtZW50YXRpb24+QW5nYWJlbiB6dW0gSGFzaHdlcnQgZGVzIGdlcHLDvGZ0ZW4gRG9rdW1lbnRz' +
    'LjwveHM6ZG9jdW1lbnRhdGlvbj4KICAgICAgICAgICAgICAgIDwveHM6YW5ub3RhdGlvbj4KICAgICAgICAgICAgICAgIDx4czpjb21wbGV4VHlwZT4KICAgICAgICAg' +
    'ICAgICAgICAgICA8eHM6c2VxdWVuY2U+CiAgICAgICAgICAgICAgICAgICAgICAgIDx4czplbGVtZW50IG5hbWU9Imhhc2hBbGdvcml0aG0iIHR5cGU9InhzOm5vcm1h' +
    'bGl6ZWRTdHJpbmciPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPHhzOmFubm90YXRpb24+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPHhzOmRv' +
    'Y3VtZW50YXRpb24+QmVuZW5udW5nIGVpbmVzIEFsZ29yaXRobXVzIHp1ciBCZXJlY2hudW5nIGRlcyBIYXNod2VydHMuPC94czpkb2N1bWVudGF0aW9uPgogICAgICAg' +
    'ICAgICAgICAgICAgICAgICAgICAgPC94czphbm5vdGF0aW9uPgogICAgICAgICAgICAgICAgICAgICAgICA8L3hzOmVsZW1lbnQ+CiAgICAgICAgICAgICAgICAgICAg' +
    'ICAgIDx4czplbGVtZW50IG5hbWU9Imhhc2hWYWx1ZSIgdHlwZT0ieHM6YmFzZTY0QmluYXJ5Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDx4czphbm5vdGF0' +
    'aW9uPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDx4czpkb2N1bWVudGF0aW9uPkRlciBIYXNod2VydCBkZXMgZ2VwcsO8ZnRlbiBEb2t1bWVudHMgYmVp' +
    'IEFud2VuZHVuZyBkZXMgYmV6ZWljaG5ldGVuIEFsZ29yaXRobXVzLjwveHM6ZG9jdW1lbnRhdGlvbj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwveHM6YW5u' +
    'b3RhdGlvbj4KICAgICAgICAgICAgICAgICAgICAgICAgPC94czplbGVtZW50PgogICAgICAgICAgICAgICAgICAgIDwveHM6c2VxdWVuY2U+CiAgICAgICAgICAgICAg' +
    'ICA8L3hzOmNvbXBsZXhUeXBlPgogICAgICAgICAgICA8L3hzOmVsZW1lbnQ+CiAgICAgICAgICAgIDx4czplbGVtZW50IG5hbWU9ImRvY3VtZW50UmVmZXJlbmNlIiB0' +
    'eXBlPSJ4czpub3JtYWxpemVkU3RyaW5nIj4KICAgICAgICAgICAgICAgIDx4czphbm5vdGF0aW9uPgogICAgICAgICAgICAgICAgICAgIDx4czpkb2N1bWVudGF0aW9u' +
    'PkVpbmUgdm9uIGRlciBwcsO8ZmVuZGVuIE9yZ2FuaXNhdGlvbnNlaW5oZWl0IGZlc3RnZWxlZ3RlLCBtw7ZnbGljaHN0IGVpbmRldXRpZ2UgUmVmZXJlbnogZGVzIGdl' +
    'cHLDvGZ0ZW4KICAgICAgICAgICAgICAgICAgICAgICAgRG9rdW1lbnRzLjwveHM6ZG9jdW1lbnRhdGlvbj4KICAgICAgICAgICAgICAgIDwveHM6YW5ub3RhdGlvbj4K' +
    'ICAgICAgICAgICAgPC94czplbGVtZW50PgogICAgICAgIDwveHM6c2VxdWVuY2U+CiAgICA8L3hzOmNvbXBsZXhUeXBlPgoKICAgIDx4czpjb21wbGV4VHlwZSBuYW1l' +
    'PSJFbmdpbmVUeXBlIj4KICAgICAgICA8eHM6c2VxdWVuY2U+CiAgICAgICAgICAgIDx4czplbGVtZW50IG5hbWU9Im5hbWUiIHR5cGU9InhzOm5vcm1hbGl6ZWRTdHJp' +
    'bmciLz4KICAgICAgICAgICAgPHhzOmVsZW1lbnQgbmFtZT0iaW5mbyIgbWluT2NjdXJzPSIwIiBtYXhPY2N1cnM9InVuYm91bmRlZCI+CiAgICAgICAgICAgICAgICA8' +
    'eHM6Y29tcGxleFR5cGU+CiAgICAgICAgICAgICAgICAgICAgPHhzOnNpbXBsZUNvbnRlbnQ+CiAgICAgICAgICAgICAgICAgICAgICAgIDx4czpleHRlbnNpb24gYmFz' +
    'ZT0ieHM6bm9ybWFsaXplZFN0cmluZyI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8eHM6YXR0cmlidXRlIG5hbWU9ImtleSIgdHlwZT0ieHM6Tk1UT0tFTiIg' +
    'dXNlPSJyZXF1aXJlZCIvPgogICAgICAgICAgICAgICAgICAgICAgICA8L3hzOmV4dGVuc2lvbj4KICAgICAgICAgICAgICAgICAgICA8L3hzOnNpbXBsZUNvbnRlbnQ+' +
    'CiAgICAgICAgICAgICAgICA8L3hzOmNvbXBsZXhUeXBlPgogICAgICAgICAgICA8L3hzOmVsZW1lbnQ+CiAgICAgICAgPC94czpzZXF1ZW5jZT4KICAgIDwveHM6Y29t' +
    'cGxleFR5cGU+CgogICAgPHhzOmNvbXBsZXhUeXBlIG5hbWU9IlByb2Nlc3NpbmdFcnJvciI+CiAgICAgICAgPHhzOnNlcXVlbmNlPgogICAgICAgICAgICA8eHM6ZWxl' +
    'bWVudCBuYW1lPSJlcnJvciIgdHlwZT0ieHM6c3RyaW5nIiBtaW5PY2N1cnM9IjEiIG1heE9jY3Vycz0idW5ib3VuZGVkIiAvPgogICAgICAgIDwveHM6c2VxdWVuY2U+' +
    'CiAgICA8L3hzOmNvbXBsZXhUeXBlPgoKICAgIDx4czplbGVtZW50IG5hbWU9ImVycm9yLW1lc3NhZ2UiPgogICAgICAgIDx4czphbm5vdGF0aW9uPgogICAgICAgICAg' +
    'ICA8eHM6ZG9jdW1lbnRhdGlvbj4KICAgICAgICAgICAgICAgIERpZXNlcyBFbGVtZW50IHdpcmQgYWxzICJJbnB1dCItRG9jdW1lbnQgaW0gRmFsbGUgdm9uIFBhcnNp' +
    'bmctRmVobGVybiBhbiBkZW4gUmVwb3J0LUdlbmVyYXRvciDDvGJlcmdlYmVuLgogICAgICAgICAgICA8L3hzOmRvY3VtZW50YXRpb24+CiAgICAgICAgPC94czphbm5v' +
    'dGF0aW9uPgogICAgICAgIDx4czpjb21wbGV4VHlwZT4KICAgICAgICAgICAgPHhzOnNpbXBsZUNvbnRlbnQ+CiAgICAgICAgICAgICAgICA8eHM6ZXh0ZW5zaW9uIGJh' +
    'c2U9InhzOnN0cmluZyIgLz4KICAgICAgICAgICAgPC94czpzaW1wbGVDb250ZW50PgogICAgICAgIDwveHM6Y29tcGxleFR5cGU+CiAgICA8L3hzOmVsZW1lbnQ+Cgo8' +
    'L3hzOnNjaGVtYT4K';
  // Struktur und Inhaltsmodell der Schematron-Ergebnisse festlegen; Original svrl-kosit.xsd aus src/main/model/xsd/svrl-kosit.xsd im KoSIT-Repository.
  FrameworkSvrlSchemaBase64 =
    'PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPCEtLQogIH4gQ29weXJpZ2h0IDIwMTctMjAyMiAgS29vcmRpbmllcnVuZ3NzdGVsbGUgZsO8ciBJ' +
    'VC1TdGFuZGFyZHMgKEtvU0lUKQogIH4KICB+IExpY2Vuc2VkIHVuZGVyIHRoZSBBcGFjaGUgTGljZW5zZSwgVmVyc2lvbiAyLjAgKHRoZSAiTGljZW5zZSIpOwogIH4g' +
    'eW91IG1heSBub3QgdXNlIHRoaXMgZmlsZSBleGNlcHQgaW4gY29tcGxpYW5jZSB3aXRoIHRoZSBMaWNlbnNlLgogIH4gWW91IG1heSBvYnRhaW4gYSBjb3B5IG9mIHRo' +
    'ZSBMaWNlbnNlIGF0CiAgfgogIH4gICAgIGh0dHA6Ly93d3cuYXBhY2hlLm9yZy9saWNlbnNlcy9MSUNFTlNFLTIuMAogIH4KICB+IFVubGVzcyByZXF1aXJlZCBieSBh' +
    'cHBsaWNhYmxlIGxhdyBvciBhZ3JlZWQgdG8gaW4gd3JpdGluZywgc29mdHdhcmUKICB+IGRpc3RyaWJ1dGVkIHVuZGVyIHRoZSBMaWNlbnNlIGlzIGRpc3RyaWJ1dGVk' +
    'IG9uIGFuICJBUyBJUyIgQkFTSVMsCiAgfiBXSVRIT1VUIFdBUlJBTlRJRVMgT1IgQ09ORElUSU9OUyBPRiBBTlkgS0lORCwgZWl0aGVyIGV4cHJlc3Mgb3IgaW1wbGll' +
    'ZC4KICB+IFNlZSB0aGUgTGljZW5zZSBmb3IgdGhlIHNwZWNpZmljIGxhbmd1YWdlIGdvdmVybmluZyBwZXJtaXNzaW9ucyBhbmQKICB+IGxpbWl0YXRpb25zIHVuZGVy' +
    'IHRoZSBMaWNlbnNlLgogIC0tPgoKPHhzOnNjaGVtYSB4bWxuczp4cz0iaHR0cDovL3d3dy53My5vcmcvMjAwMS9YTUxTY2hlbWEiIHhtbG5zOnN2cmw9Imh0dHA6Ly9w' +
    'dXJsLm9jbGMub3JnL2RzZGwvc3ZybCIKICAgICAgICAgICB0YXJnZXROYW1lc3BhY2U9Imh0dHA6Ly9wdXJsLm9jbGMub3JnL2RzZGwvc3ZybCIgdmVyc2lvbj0iMC4x' +
    'IiBlbGVtZW50Rm9ybURlZmF1bHQ9InF1YWxpZmllZCIgYXR0cmlidXRlRm9ybURlZmF1bHQ9InVucXVhbGlmaWVkIj4KICAgIDx4czppbXBvcnQgc2NoZW1hTG9jYXRp' +
    'b249InhtbC54c2QiIG5hbWVzcGFjZT0iaHR0cDovL3d3dy53My5vcmcvWE1MLzE5OTgvbmFtZXNwYWNlIiAvPgogICAgPHhzOmNvbXBsZXhUeXBlIG5hbWU9InJpY2gt' +
    'dGV4dCIgbWl4ZWQ9InRydWUiPgogICAgICAgIDx4czpzZXF1ZW5jZT4KCiAgICAgICAgICAgIDx4czpjaG9pY2UgbWluT2NjdXJzPSIwIiBtYXhPY2N1cnM9InVuYm91' +
    'bmRlZCI+CiAgICAgICAgICAgICAgICA8eHM6Z3JvdXAgcmVmPSJzdnJsOmZvcmVpZ24iIC8+CiAgICAgICAgICAgICAgICA8eHM6ZWxlbWVudCByZWY9InN2cmw6ZGly' +
    'IiAvPgogICAgICAgICAgICAgICAgPHhzOmVsZW1lbnQgcmVmPSJzdnJsOnNwYW4iIC8+CiAgICAgICAgICAgICAgICA8eHM6ZWxlbWVudCByZWY9InN2cmw6ZW1waCIg' +
    'Lz4KICAgICAgICAgICAgPC94czpjaG9pY2U+CiAgICAgICAgPC94czpzZXF1ZW5jZT4KICAgICAgICA8eHM6YXR0cmlidXRlR3JvdXAgcmVmPSJzdnJsOmZvcmVpZ24i' +
    'IC8+CiAgICA8L3hzOmNvbXBsZXhUeXBlPgogICAgPHhzOmF0dHJpYnV0ZUdyb3VwIG5hbWU9ImF0dGxpc3QuYXNzZXJ0LWFuZC1yZXBvcnQiPgogICAgICAgIDx4czph' +
    'dHRyaWJ1dGUgbmFtZT0iZmxhZyIgdHlwZT0ieHM6Tk1UT0tFTiIgdXNlPSJvcHRpb25hbCIgLz4KICAgICAgICA8eHM6YXR0cmlidXRlIG5hbWU9ImlkIiB0eXBlPSJ4' +
    'czpOTVRPS0VOIiB1c2U9InJlcXVpcmVkIiAvPgogICAgICAgIDx4czphdHRyaWJ1dGUgbmFtZT0ibG9jYXRpb24iIHVzZT0icmVxdWlyZWQiIC8+CiAgICAgICAgPHhz' +
    'OmF0dHJpYnV0ZSBuYW1lPSJyb2xlIiB0eXBlPSJ4czpzdHJpbmciIHVzZT0ib3B0aW9uYWwiLz4KICAgICAgICA8eHM6YXR0cmlidXRlIG5hbWU9InRlc3QiIHVzZT0i' +
    'cmVxdWlyZWQiIC8+CiAgICA8L3hzOmF0dHJpYnV0ZUdyb3VwPgogICAgPHhzOmF0dHJpYnV0ZUdyb3VwIG5hbWU9ImZvcmVpZ24iPgogICAgICAgIDx4czphdHRyaWJ1' +
    'dGVHcm91cCByZWY9InN2cmw6Zm9yZWlnbi1hdHRyaWJ1dGVzIiAvPgogICAgPC94czphdHRyaWJ1dGVHcm91cD4KICAgIDx4czpncm91cCBuYW1lPSJmb3JlaWduIj4K' +
    'ICAgICAgICA8eHM6c2VxdWVuY2U+CiAgICAgICAgICAgIDx4czpncm91cCByZWY9InN2cmw6Zm9yZWlnbi1lbGVtZW50IiBtaW5PY2N1cnM9IjAiIC8+CiAgICAgICAg' +
    'PC94czpzZXF1ZW5jZT4KICAgIDwveHM6Z3JvdXA+CiAgICA8eHM6YXR0cmlidXRlR3JvdXAgbmFtZT0iZm9yZWlnbi1hdHRyaWJ1dGVzIj4KICAgICAgICA8eHM6YW55' +
    'QXR0cmlidXRlIC8+CiAgICA8L3hzOmF0dHJpYnV0ZUdyb3VwPgogICAgPHhzOmdyb3VwIG5hbWU9ImZvcmVpZ24tZWxlbWVudCI+CiAgICAgICAgPHhzOmNob2ljZT4K' +
    'ICAgICAgICAgICAgPHhzOmFueSBuYW1lc3BhY2U9IiMjb3RoZXIiIHByb2Nlc3NDb250ZW50cz0ic2tpcCIgLz4KICAgICAgICAgICAgPHhzOmFueSBuYW1lc3BhY2U9' +
    'IiMjbG9jYWwiIHByb2Nlc3NDb250ZW50cz0ic2tpcCIgLz4KICAgICAgICA8L3hzOmNob2ljZT4KICAgIDwveHM6Z3JvdXA+CiAgICA8eHM6ZWxlbWVudCBuYW1lPSJh' +
    'Y3RpdmUtcGF0dGVybiI+CiAgICAgICAgPHhzOmNvbXBsZXhUeXBlPgogICAgICAgICAgICA8eHM6YXR0cmlidXRlIG5hbWU9ImRvY3VtZW50cyIgdXNlPSJvcHRpb25h' +
    'bCIgLz4KICAgICAgICAgICAgPHhzOmF0dHJpYnV0ZSBuYW1lPSJpZCIgdHlwZT0ieHM6Tk1UT0tFTiIgdXNlPSJvcHRpb25hbCIgLz4KICAgICAgICAgICAgPHhzOmF0' +
    'dHJpYnV0ZSBuYW1lPSJuYW1lIiB1c2U9Im9wdGlvbmFsIiAvPgogICAgICAgICAgICA8eHM6YXR0cmlidXRlIG5hbWU9InJvbGUiIHR5cGU9InhzOk5NVE9LRU4iIHVz' +
    'ZT0ib3B0aW9uYWwiIC8+CiAgICAgICAgPC94czpjb21wbGV4VHlwZT4KICAgIDwveHM6ZWxlbWVudD4KICAgIDx4czplbGVtZW50IG5hbWU9ImRpYWdub3N0aWMtcmVm' +
    'ZXJlbmNlIj4KICAgICAgICA8eHM6Y29tcGxleFR5cGU+CiAgICAgICAgICAgIDx4czpzZXF1ZW5jZT4KICAgICAgICAgICAgICAgIDx4czplbGVtZW50IHJlZj0ic3Zy' +
    'bDp0ZXh0IiAvPgogICAgICAgICAgICA8L3hzOnNlcXVlbmNlPgogICAgICAgICAgICA8eHM6YXR0cmlidXRlIG5hbWU9ImRpYWdub3N0aWMiIHR5cGU9InhzOk5NVE9L' +
    'RU4iIHVzZT0icmVxdWlyZWQiIC8+CiAgICAgICAgPC94czpjb21wbGV4VHlwZT4KICAgIDwveHM6ZWxlbWVudD4KICAgIDx4czplbGVtZW50IG5hbWU9ImRpciI+CiAg' +
    'ICAgICAgPHhzOmNvbXBsZXhUeXBlIG1peGVkPSJ0cnVlIj4KICAgICAgICAgICAgPHhzOmF0dHJpYnV0ZSBuYW1lPSJjbGFzcyIgdXNlPSJvcHRpb25hbCIgLz4KICAg' +
    'ICAgICAgICAgPHhzOmF0dHJpYnV0ZSBuYW1lPSJkaXIiIHVzZT0ib3B0aW9uYWwiIC8+CiAgICAgICAgPC94czpjb21wbGV4VHlwZT4KICAgIDwveHM6ZWxlbWVudD4K' +
    'ICAgIDx4czplbGVtZW50IG5hbWU9ImVtcGgiPgogICAgICAgIDx4czpjb21wbGV4VHlwZSBtaXhlZD0idHJ1ZSI+CiAgICAgICAgICAgIDx4czphdHRyaWJ1dGUgbmFt' +
    'ZT0iY2xhc3MiIHVzZT0ib3B0aW9uYWwiIC8+CiAgICAgICAgPC94czpjb21wbGV4VHlwZT4KICAgIDwveHM6ZWxlbWVudD4KICAgIDx4czplbGVtZW50IG5hbWU9ImZh' +
    'aWxlZC1hc3NlcnQiPgogICAgICAgIDx4czpjb21wbGV4VHlwZT4KICAgICAgICAgICAgPHhzOnNlcXVlbmNlPgogICAgICAgICAgICAgICAgPHhzOmVsZW1lbnQgcmVm' +
    'PSJzdnJsOmRpYWdub3N0aWMtcmVmZXJlbmNlIiBtaW5PY2N1cnM9IjAiIG1heE9jY3Vycz0idW5ib3VuZGVkIiAvPgogICAgICAgICAgICAgICAgPHhzOmVsZW1lbnQg' +
    'cmVmPSJzdnJsOnByb3BlcnR5LXJlZmVyZW5jZSIgbWluT2NjdXJzPSIwIiBtYXhPY2N1cnM9InVuYm91bmRlZCIgLz4KICAgICAgICAgICAgICAgIDx4czplbGVtZW50' +
    'IHJlZj0ic3ZybDp0ZXh0IiAvPgogICAgICAgICAgICA8L3hzOnNlcXVlbmNlPgogICAgICAgICAgICA8eHM6YXR0cmlidXRlR3JvdXAgcmVmPSJzdnJsOmF0dGxpc3Qu' +
    'YXNzZXJ0LWFuZC1yZXBvcnQiIC8+CiAgICAgICAgPC94czpjb21wbGV4VHlwZT4KICAgIDwveHM6ZWxlbWVudD4KICAgIDx4czplbGVtZW50IG5hbWU9ImZpcmVkLXJ1' +
    'bGUiPgogICAgICAgIDx4czpjb21wbGV4VHlwZT4KICAgICAgICAgICAgPHhzOmF0dHJpYnV0ZSBuYW1lPSJjb250ZXh0IiB1c2U9InJlcXVpcmVkIiAvPgogICAgICAg' +
    'ICAgICA8eHM6YXR0cmlidXRlIG5hbWU9ImZsYWciIHR5cGU9InhzOk5NVE9LRU4iIHVzZT0ib3B0aW9uYWwiIC8+CiAgICAgICAgICAgIDx4czphdHRyaWJ1dGUgbmFt' +
    'ZT0iaWQiIHR5cGU9InhzOk5NVE9LRU4iIHVzZT0ib3B0aW9uYWwiIC8+CiAgICAgICAgICAgIDx4czphdHRyaWJ1dGUgbmFtZT0ibmFtZSIgdXNlPSJvcHRpb25hbCIg' +
    'Lz4KICAgICAgICAgICAgPHhzOmF0dHJpYnV0ZSBuYW1lPSJyb2xlIiB0eXBlPSJ4czpOTVRPS0VOIiB1c2U9Im9wdGlvbmFsIiAvPgogICAgICAgIDwveHM6Y29tcGxl' +
    'eFR5cGU+CiAgICA8L3hzOmVsZW1lbnQ+CiAgICA8eHM6ZWxlbWVudCBuYW1lPSJucy1wcmVmaXgtaW4tYXR0cmlidXRlLXZhbHVlcyI+CiAgICAgICAgPHhzOmNvbXBs' +
    'ZXhUeXBlPgogICAgICAgICAgICA8eHM6YXR0cmlidXRlIG5hbWU9InByZWZpeCIgdHlwZT0ieHM6Tk1UT0tFTiIgdXNlPSJyZXF1aXJlZCIgLz4KICAgICAgICAgICAg' +
    'PHhzOmF0dHJpYnV0ZSBuYW1lPSJ1cmkiIHVzZT0icmVxdWlyZWQiIC8+CiAgICAgICAgPC94czpjb21wbGV4VHlwZT4KICAgIDwveHM6ZWxlbWVudD4KICAgIDx4czpl' +
    'bGVtZW50IG5hbWU9InByb3BlcnR5LXJlZmVyZW5jZSI+CiAgICAgICAgPHhzOmNvbXBsZXhUeXBlPgogICAgICAgICAgICA8eHM6c2VxdWVuY2U+CiAgICAgICAgICAg' +
    'ICAgICA8eHM6ZWxlbWVudCByZWY9InN2cmw6dGV4dCIgLz4KICAgICAgICAgICAgPC94czpzZXF1ZW5jZT4KICAgICAgICAgICAgPHhzOmF0dHJpYnV0ZSBuYW1lPSJw' +
    'cm9wZXJ0eSIgdHlwZT0ieHM6Tk1UT0tFTiIgdXNlPSJyZXF1aXJlZCIgLz4KICAgICAgICAgICAgPHhzOmF0dHJpYnV0ZSBuYW1lPSJyb2xlIiB1c2U9Im9wdGlvbmFs' +
    'IiAvPgogICAgICAgICAgICA8eHM6YXR0cmlidXRlIG5hbWU9InNjaGVtZSIgdXNlPSJvcHRpb25hbCIgLz4KICAgICAgICA8L3hzOmNvbXBsZXhUeXBlPgogICAgPC94' +
    'czplbGVtZW50PgogICAgPHhzOmVsZW1lbnQgbmFtZT0ic2NoZW1hdHJvbi1vdXRwdXQiPgogICAgICAgIDx4czpjb21wbGV4VHlwZT4KICAgICAgICAgICAgPHhzOnNl' +
    'cXVlbmNlPgogICAgICAgICAgICAgICAgPHhzOmVsZW1lbnQgcmVmPSJzdnJsOnRleHQiIG1pbk9jY3Vycz0iMCIgbWF4T2NjdXJzPSJ1bmJvdW5kZWQiIC8+CiAgICAg' +
    'ICAgICAgICAgICA8eHM6ZWxlbWVudCByZWY9InN2cmw6bnMtcHJlZml4LWluLWF0dHJpYnV0ZS12YWx1ZXMiIG1pbk9jY3Vycz0iMCIgbWF4T2NjdXJzPSJ1bmJvdW5k' +
    'ZWQiIC8+CiAgICAgICAgICAgICAgICA8eHM6c2VxdWVuY2UgbWluT2NjdXJzPSIwIiBtYXhPY2N1cnM9InVuYm91bmRlZCI+CiAgICAgICAgICAgICAgICAgICAgPHhz' +
    'OmVsZW1lbnQgcmVmPSJzdnJsOmFjdGl2ZS1wYXR0ZXJuIiBtaW5PY2N1cnM9IjAiIC8+CiAgICAgICAgICAgICAgICAgICAgPHhzOnNlcXVlbmNlIG1pbk9jY3Vycz0i' +
    'MCIgbWF4T2NjdXJzPSJ1bmJvdW5kZWQiPgogICAgICAgICAgICAgICAgICAgICAgICA8eHM6ZWxlbWVudCByZWY9InN2cmw6ZmlyZWQtcnVsZSIgbWluT2NjdXJzPSIw' +
    'IiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8eHM6Y2hvaWNlIG1pbk9jY3Vycz0iMCIgbWF4T2NjdXJzPSJ1bmJvdW5kZWQiPgogICAgICAgICAgICAgICAgICAg' +
    'ICAgICAgICAgPHhzOmVsZW1lbnQgcmVmPSJzdnJsOmZhaWxlZC1hc3NlcnQiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8eHM6ZWxlbWVudCByZWY9InN2' +
    'cmw6c3VjY2Vzc2Z1bC1yZXBvcnQiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwveHM6Y2hvaWNlPgogICAgICAgICAgICAgICAgICAgIDwveHM6c2VxdWVuY2U+' +
    'CiAgICAgICAgICAgICAgICA8L3hzOnNlcXVlbmNlPgogICAgICAgICAgICA8L3hzOnNlcXVlbmNlPgogICAgICAgICAgICA8eHM6YXR0cmlidXRlIG5hbWU9InBoYXNl' +
    'IiB0eXBlPSJ4czpOTVRPS0VOIiB1c2U9Im9wdGlvbmFsIiAvPgogICAgICAgICAgICA8eHM6YXR0cmlidXRlIG5hbWU9InNjaGVtYVZlcnNpb24iIHVzZT0ib3B0aW9u' +
    'YWwiIC8+CiAgICAgICAgICAgIDx4czphdHRyaWJ1dGUgbmFtZT0idGl0bGUiIHVzZT0ib3B0aW9uYWwiIC8+CiAgICAgICAgPC94czpjb21wbGV4VHlwZT4KICAgIDwv' +
    'eHM6ZWxlbWVudD4KICAgIDx4czplbGVtZW50IG5hbWU9InNwYW4iPgogICAgICAgIDx4czpjb21wbGV4VHlwZSBtaXhlZD0idHJ1ZSI+CiAgICAgICAgICAgIDx4czph' +
    'dHRyaWJ1dGUgbmFtZT0iY2xhc3MiIHVzZT0icmVxdWlyZWQiIC8+CiAgICAgICAgPC94czpjb21wbGV4VHlwZT4KICAgIDwveHM6ZWxlbWVudD4KICAgIDx4czplbGVt' +
    'ZW50IG5hbWU9InN1Y2Nlc3NmdWwtcmVwb3J0Ij4KICAgICAgICA8eHM6Y29tcGxleFR5cGU+CiAgICAgICAgICAgIDx4czpzZXF1ZW5jZT4KICAgICAgICAgICAgICAg' +
    'IDx4czplbGVtZW50IHJlZj0ic3ZybDpkaWFnbm9zdGljLXJlZmVyZW5jZSIgbWluT2NjdXJzPSIwIiBtYXhPY2N1cnM9InVuYm91bmRlZCIgLz4KICAgICAgICAgICAg' +
    'ICAgIDx4czplbGVtZW50IHJlZj0ic3ZybDpwcm9wZXJ0eS1yZWZlcmVuY2UiIG1pbk9jY3Vycz0iMCIgbWF4T2NjdXJzPSJ1bmJvdW5kZWQiIC8+CiAgICAgICAgICAg' +
    'ICAgICA8eHM6ZWxlbWVudCByZWY9InN2cmw6dGV4dCIgLz4KICAgICAgICAgICAgPC94czpzZXF1ZW5jZT4KICAgICAgICAgICAgPHhzOmF0dHJpYnV0ZUdyb3VwIHJl' +
    'Zj0ic3ZybDphdHRsaXN0LmFzc2VydC1hbmQtcmVwb3J0IiAvPgogICAgICAgIDwveHM6Y29tcGxleFR5cGU+CiAgICA8L3hzOmVsZW1lbnQ+CiAgICA8eHM6ZWxlbWVu' +
    'dCBuYW1lPSJ0ZXh0Ij4KICAgICAgICA8eHM6Y29tcGxleFR5cGU+CiAgICAgICAgICAgIDx4czpjb21wbGV4Q29udGVudD4KICAgICAgICAgICAgICAgIDx4czpleHRl' +
    'bnNpb24gYmFzZT0ic3ZybDpyaWNoLXRleHQiPgogICAgICAgICAgICAgICAgICAgIDx4czphdHRyaWJ1dGUgcmVmPSJ4bWw6c3BhY2UiIC8+CiAgICAgICAgICAgICAg' +
    'ICAgICAgPHhzOmF0dHJpYnV0ZSByZWY9InhtbDpsYW5nIiAvPgogICAgICAgICAgICAgICAgICAgIDx4czphdHRyaWJ1dGUgbmFtZT0iZnBpIiB1c2U9Im9wdGlvbmFs' +
    'IiAvPgogICAgICAgICAgICAgICAgICAgIDx4czphdHRyaWJ1dGUgbmFtZT0iaWNvbiIgdXNlPSJvcHRpb25hbCIgLz4KICAgICAgICAgICAgICAgICAgICA8eHM6YXR0' +
    'cmlidXRlIG5hbWU9InNlZSIgdXNlPSJvcHRpb25hbCIgLz4KICAgICAgICAgICAgICAgIDwveHM6ZXh0ZW5zaW9uPgogICAgICAgICAgICA8L3hzOmNvbXBsZXhDb250' +
    'ZW50PgogICAgICAgIDwveHM6Y29tcGxleFR5cGU+CiAgICA8L3hzOmVsZW1lbnQ+CjwveHM6c2NoZW1hPgoK';
  // XML-Namensraumattribute für SVRL bereitstellen; Original xml.xsd aus src/main/model/xsd/xml.xsd im KoSIT-Repository.
  FrameworkXmlNamespaceSchemaBase64 =
    'PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPCEtLQogIH4gQ29weXJpZ2h0IDIwMTctMjAyMiAgS29vcmRpbmllcnVuZ3NzdGVsbGUgZsO8ciBJ' +
    'VC1TdGFuZGFyZHMgKEtvU0lUKQogIH4KICB+IExpY2Vuc2VkIHVuZGVyIHRoZSBBcGFjaGUgTGljZW5zZSwgVmVyc2lvbiAyLjAgKHRoZSAiTGljZW5zZSIpOwogIH4g' +
    'eW91IG1heSBub3QgdXNlIHRoaXMgZmlsZSBleGNlcHQgaW4gY29tcGxpYW5jZSB3aXRoIHRoZSBMaWNlbnNlLgogIH4gWW91IG1heSBvYnRhaW4gYSBjb3B5IG9mIHRo' +
    'ZSBMaWNlbnNlIGF0CiAgfgogIH4gICAgIGh0dHA6Ly93d3cuYXBhY2hlLm9yZy9saWNlbnNlcy9MSUNFTlNFLTIuMAogIH4KICB+IFVubGVzcyByZXF1aXJlZCBieSBh' +
    'cHBsaWNhYmxlIGxhdyBvciBhZ3JlZWQgdG8gaW4gd3JpdGluZywgc29mdHdhcmUKICB+IGRpc3RyaWJ1dGVkIHVuZGVyIHRoZSBMaWNlbnNlIGlzIGRpc3RyaWJ1dGVk' +
    'IG9uIGFuICJBUyBJUyIgQkFTSVMsCiAgfiBXSVRIT1VUIFdBUlJBTlRJRVMgT1IgQ09ORElUSU9OUyBPRiBBTlkgS0lORCwgZWl0aGVyIGV4cHJlc3Mgb3IgaW1wbGll' +
    'ZC4KICB+IFNlZSB0aGUgTGljZW5zZSBmb3IgdGhlIHNwZWNpZmljIGxhbmd1YWdlIGdvdmVybmluZyBwZXJtaXNzaW9ucyBhbmQKICB+IGxpbWl0YXRpb25zIHVuZGVy' +
    'IHRoZSBMaWNlbnNlLgogIC0tPgoKPHhzOnNjaGVtYSB4bWxuczp4cz0iaHR0cDovL3d3dy53My5vcmcvMjAwMS9YTUxTY2hlbWEiIGVsZW1lbnRGb3JtRGVmYXVsdD0i' +
    'cXVhbGlmaWVkIgogICAgICAgICAgIHRhcmdldE5hbWVzcGFjZT0iaHR0cDovL3d3dy53My5vcmcvWE1MLzE5OTgvbmFtZXNwYWNlIj4KICAgIDx4czppbXBvcnQgbmFt' +
    'ZXNwYWNlPSJodHRwOi8vcHVybC5vY2xjLm9yZy9kc2RsL3N2cmwiIHNjaGVtYUxvY2F0aW9uPSJzdnJsLWtvc2l0LnhzZCIgLz4KICAgIDx4czphdHRyaWJ1dGUgbmFt' +
    'ZT0ic3BhY2UiIC8+CiAgICA8eHM6YXR0cmlidXRlIG5hbWU9ImxhbmciIC8+CiAgICA8eHM6YXR0cmlidXRlR3JvdXAgbmFtZT0ibG9jYWwiPgogICAgICAgIDx4czph' +
    'bnlBdHRyaWJ1dGUgbmFtZXNwYWNlPSIjI290aGVyIiBwcm9jZXNzQ29udGVudHM9InNraXAiIC8+CiAgICA8L3hzOmF0dHJpYnV0ZUdyb3VwPgo8L3hzOnNjaGVtYT4K';
  // XML-Knoten unverändert kopieren; Original identity.xsl aus src/main/resources/transform/identity.xsl im KoSIT-Repository.
  FrameworkIdentityStylesheetBase64 =
    'PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0idXRmLTgiPz4KPCEtLQogIH4gQ29weXJpZ2h0IDIwMTctMjAyNiAgS29vcmRpbmllcnVuZ3NzdGVsbGUgZsO8ciBJ' +
    'VC1TdGFuZGFyZHMgKEtvU0lUKQogIH4KICB+IExpY2Vuc2VkIHVuZGVyIHRoZSBBcGFjaGUgTGljZW5zZSwgVmVyc2lvbiAyLjAgKHRoZSAiTGljZW5zZSIpOwogIH4g' +
    'eW91IG1heSBub3QgdXNlIHRoaXMgZmlsZSBleGNlcHQgaW4gY29tcGxpYW5jZSB3aXRoIHRoZSBMaWNlbnNlLgogIH4gWW91IG1heSBvYnRhaW4gYSBjb3B5IG9mIHRo' +
    'ZSBMaWNlbnNlIGF0CiAgfgogIH4gICAgIGh0dHA6Ly93d3cuYXBhY2hlLm9yZy9saWNlbnNlcy9MSUNFTlNFLTIuMAogIH4KICB+IFVubGVzcyByZXF1aXJlZCBieSBh' +
    'cHBsaWNhYmxlIGxhdyBvciBhZ3JlZWQgdG8gaW4gd3JpdGluZywgc29mdHdhcmUKICB+IGRpc3RyaWJ1dGVkIHVuZGVyIHRoZSBMaWNlbnNlIGlzIGRpc3RyaWJ1dGVk' +
    'IG9uIGFuICJBUyBJUyIgQkFTSVMsCiAgfiBXSVRIT1VUIFdBUlJBTlRJRVMgT1IgQ09ORElUSU9OUyBPRiBBTlkgS0lORCwgZWl0aGVyIGV4cHJlc3Mgb3IgaW1wbGll' +
    'ZC4KICB+IFNlZSB0aGUgTGljZW5zZSBmb3IgdGhlIHNwZWNpZmljIGxhbmd1YWdlIGdvdmVybmluZyBwZXJtaXNzaW9ucyBhbmQKICB+IGxpbWl0YXRpb25zIHVuZGVy' +
    'IHRoZSBMaWNlbnNlLgogIC0tPgo8eHNsOnN0eWxlc2hlZXQgeG1sbnM6eHNsPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5L1hTTC9UcmFuc2Zvcm0iIHZlcnNpb249IjIu' +
    'MCI+CiAgICA8eHNsOnRlbXBsYXRlIG1hdGNoPSJlbGVtZW50KCkiPgogICAgICAgIDx4c2w6Y29weT4KICAgICAgICAgICAgPHhzbDphcHBseS10ZW1wbGF0ZXMgc2Vs' +
    'ZWN0PSJAKixub2RlKCkiLz4KICAgICAgICA8L3hzbDpjb3B5PgogICAgPC94c2w6dGVtcGxhdGU+CgogICAgPHhzbDp0ZW1wbGF0ZSBtYXRjaD0iYXR0cmlidXRlKCl8' +
    'dGV4dCgpfGNvbW1lbnQoKXxwcm9jZXNzaW5nLWluc3RydWN0aW9uKCkiPgogICAgICAgIDx4c2w6Y29weS8+CiAgICA8L3hzbDp0ZW1wbGF0ZT4KPC94c2w6c3R5bGVz' +
    'aGVldD4K';

// Wie beim Lesen eines Berichts werden Unicode-BOMs ausgewertet und nicht Teil des Ergebnistexts.
function DecodeSerializedBytes(const Bytes: TBytes): string;
var
  OutputEncoding: TEncoding;
  PreambleLength: Integer;
begin
  OutputEncoding := nil;
  PreambleLength := TEncoding.GetBufferEncoding(Bytes, OutputEncoding, TEncoding.UTF8);
  Result := OutputEncoding.GetString(Bytes, PreambleLength, Length(Bytes) - PreambleLength);
end;

// XPath-Präfixe dienen nur der Konfigurationsabfrage und verändern die Dateien nicht.
procedure SetNamespaces(const Document: IXMLDOMDocument3);
begin
  Document.setProperty('SelectionLanguage', 'XPath');
  Document.setProperty('SelectionNamespaces', 'xmlns:s="' + ScenarioNamespace + '" xmlns:in="' + InputNamespace +
    '" xmlns:svrl="' + SvrlNamespace + '" xmlns:rep="' + ReportNamespace + '" xmlns:h="' + HtmlNamespace + '"');
end;

// Fehlende optionale Werte bleiben leer; Pflichtfelder prüft das originale XSD.
function NodeText(const Parent: IXMLDOMNode; const Expression: string): string;
var
  Node: IXMLDOMNode;
begin
  Node := Parent.selectSingleNode(Expression);
  if Node = nil then
    Result := ''
  else
    Result := Node.text;
end;

// Attribute werden auch für beliebig präfigierte SVRL-Elemente gelesen.
function AttributeText(const Node: IXMLDOMNode; const Name: string): string;
var
  Attribute: IXMLDOMNode;
begin
  Result := '';
  if Node.attributes = nil then
    Exit;
  Attribute := Node.attributes.getNamedItem(Name);
  if Attribute <> nil then
    Result := Attribute.text;
end;

// Ressourcen bleiben lokal und werden relativ zum konfigurierten Repository aufgelöst.
function ResourceFile(const RepositoryDirectory: string; const Resource: IXMLDOMNode): string;
var
  Location: string;
begin
  if Resource = nil then
    raise EArgumentException.Create('KoSIT-Ressource fehlt');
  Location := Trim(NodeText(Resource, 's:location'));
  if (Location = '') or (Pos('://', Location) > 0) or Location.StartsWith('file:', True) then
    raise EArgumentException.Create('KoSIT-Ressourcen müssen lokale Dateipfade sein: ' + Location);
  Location := StringReplace(Location, '/', PathDelim, [rfReplaceAll]);
  Location := TNetEncoding.URL.Decode(Location);
  if TPath.IsPathRooted(Location) then
    Result := TPath.GetFullPath(Location)
  else
    Result := TPath.GetFullPath(TPath.Combine(RepositoryDirectory, Location));
  if not TFile.Exists(Result) then
    raise EFileNotFoundException.Create('KoSIT-Ressource fehlt: ' + Result);
end;

// Namespace-Kontext des Szenarios gilt sowohl für match als auch für acceptMatch.
function ScenarioNamespaces(const Scenario: IXMLDOMNode): TArray<string>;
var
  Nodes: IXMLDOMNodeList;
  Index: Integer;
begin
  Nodes := Scenario.selectNodes('s:namespace');
  SetLength(Result, Nodes.length * 2);
  for Index := 0 to Nodes.length - 1 do
  begin
    Result[Index * 2] := AttributeText(Nodes.item[Index], 'prefix');
    Result[Index * 2 + 1] := Trim(Nodes.item[Index].text);
  end;
end;

// Die Berichtseingabe verwendet exakt den Namespace des mitgelieferten Framework-XSD.
function AppendInput(const Document: IXMLDOMDocument3; const Parent: IXMLDOMNode; const Name: string; const Value: string = ''): IXMLDOMNode;
begin
  Result := Document.createNode(NODE_ELEMENT, 'in:' + Name, InputNamespace);
  if Value <> '' then
    Result.text := Value;
  Parent.appendChild(Result);
end;

// Import erhält Szenariobeschreibung und Ressourcenmetadaten unverändert.
procedure AppendImported(const Document: IXMLDOMDocument3; const Parent, Source: IXMLDOMNode);
begin
  Parent.appendChild(Document.importNode(Source, True));
end;

// JAXB bildet nur die Attribute des generierten SVRL-Modells ab; Wildcards bleiben erhalten.
procedure CollectSvrlAttributes(const Schema: IXMLDOMDocument3; const Model: IXMLDOMNode; const Attributes: TStrings; var AllowAny: Boolean);
var
  Child, ReferencedModel: IXMLDOMNode;
  ReferenceName, AttributeName: string;
  SeparatorPosition: Integer;
begin
  Child := Model.firstChild;
  while Child <> nil do
  begin
    if Child.nodeType = NODE_ELEMENT then
    begin
      if Child.baseName = 'attribute' then
      begin
        AttributeName := AttributeText(Child, 'name');
        if AttributeName <> '' then
          Attributes.Add('|' + AttributeName)
        else
        begin
          ReferenceName := AttributeText(Child, 'ref');
          if ReferenceName.StartsWith('xml:') then
            Attributes.Add('http://www.w3.org/XML/1998/namespace|' + Copy(ReferenceName, 5, MaxInt))
          else
            raise EInvalidOperation.Create('Nicht unterstützte SVRL-Attributreferenz: ' + ReferenceName);
        end;
      end
      else if Child.baseName = 'anyAttribute' then
        AllowAny := True
      else if Child.baseName = 'attributeGroup' then
      begin
        ReferenceName := AttributeText(Child, 'ref');
        SeparatorPosition := Pos(':', ReferenceName);
        if SeparatorPosition > 0 then
          Delete(ReferenceName, 1, SeparatorPosition);
        ReferencedModel := Schema.selectSingleNode('/xs:schema/xs:attributeGroup[@name="' + ReferenceName + '"]');
        if ReferencedModel = nil then
          raise EInvalidOperation.Create('SVRL-Attributgruppe fehlt: ' + ReferenceName);
        CollectSvrlAttributes(Schema, ReferencedModel, Attributes, AllowAny);
      end
      else if (Child.baseName = 'complexContent') or (Child.baseName = 'simpleContent') then
        CollectSvrlAttributes(Schema, Child, Attributes, AllowAny)
      else if (Child.baseName = 'extension') or (Child.baseName = 'restriction') then
      begin
        ReferenceName := AttributeText(Child, 'base');
        SeparatorPosition := Pos(':', ReferenceName);
        if SeparatorPosition > 0 then
          Delete(ReferenceName, 1, SeparatorPosition);
        ReferencedModel := Schema.selectSingleNode('/xs:schema/xs:complexType[@name="' + ReferenceName + '"]');
        if ReferencedModel = nil then
          raise EInvalidOperation.Create('SVRL-Basistyp fehlt: ' + ReferenceName);
        CollectSvrlAttributes(Schema, ReferencedModel, Attributes, AllowAny);
        CollectSvrlAttributes(Schema, Child, Attributes, AllowAny);
      end;
    end;
    Child := Child.nextSibling;
  end;
end;

// Der Bericht erhält die JAXB-Modellsicht; rohe Befunde werden weiterhin aus dem Saxon-Ergebnis gelesen.
procedure ProjectSvrlModel(const Schema: IXMLDOMDocument3; const Node: IXMLDOMNode);
var
  Model, Attribute, Child: IXMLDOMNode;
  Attributes: TStringList;
  AttributeIndex: Integer;
  AllowAny: Boolean;
begin
  if (Node.nodeType <> NODE_ELEMENT) or (Node.namespaceURI <> SvrlNamespace) then
    Exit;
  Model := Schema.selectSingleNode('/xs:schema/xs:element[@name="' + Node.baseName + '"]/xs:complexType');
  if Model = nil then
    raise EInvalidOperation.Create('Nicht im KoSIT-Modell definiertes SVRL-Element: ' + Node.baseName);
  Attributes := TStringList.Create;
  try
    Attributes.CaseSensitive := True;
    AllowAny := False;
    CollectSvrlAttributes(Schema, Model, Attributes, AllowAny);
    if not AllowAny then
      for AttributeIndex := Node.attributes.length - 1 downto 0 do
      begin
        Attribute := Node.attributes.item[AttributeIndex];
        // Namespacebindungen bleiben für XPath-Texte und fremde Rich-Text-Inhalte verfügbar.
        if (Attribute.namespaceURI = 'http://www.w3.org/2000/xmlns/') or (Attribute.nodeName = 'xmlns') then
          Continue;
        if Attributes.IndexOf(Attribute.namespaceURI + '|' + Attribute.baseName) < 0 then
          Node.attributes.removeNamedItem(Attribute.nodeName);
      end;
  finally
    FreeAndNil(Attributes);
  end;
  Child := Node.firstChild;
  while Child <> nil do
  begin
    ProjectSvrlModel(Schema, Child);
    Child := Child.nextSibling;
  end;
end;

// XSD- und Parserfehler werden in den vorgesehenen XMLSyntaxError-Elementen abgelegt.
procedure AppendSyntaxError(const Document: IXMLDOMDocument3; const Parent: IXMLDOMNode; const MessageText, Severity: string);
var
  ErrorNode: IXMLDOMNode;
begin
  ErrorNode := AppendInput(Document, Parent, 'xmlSyntaxError');
  AppendInput(Document, ErrorNode, 'message', StringReplace(StringReplace(MessageText, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]));
  AppendInput(Document, ErrorNode, 'severityCode', Severity);
end;

// Auch eine Ablehnung ohne Einzelbefunde bleibt durch Acceptance fachlich sichtbar.
procedure AddFinding(var Validation: TMGKositValidationResult; const Level, Code, Text, Location, ValidationStep: string);
var
  Finding: TMGKositFinding;
begin
  Finding.Level := Level;
  Finding.Code := Code;
  Finding.Text := Text;
  Finding.Location := Location;
  Finding.ValidationStep := ValidationStep;
  Validation.Findings := Validation.Findings + [Finding];
  if SameText(Level, 'warning') then
    Inc(Validation.Warnings)
  else if SameText(Level, 'error') or SameText(Level, 'fatal') then
    Inc(Validation.Errors);
end;

// Die originalen CustomLevels überschreiben nur die angegebene Assertion-ID.
function FindingLevel(const Assertion, Scenario: IXMLDOMNode): string;
var
  Flag, Role, AssertionId: string;
  Levels: IXMLDOMNodeList;
  LevelIndex: Integer;
  Tokens: TArray<string>;
  Token: string;
begin
  Flag := AttributeText(Assertion, 'flag');
  Role := AttributeText(Assertion, 'role');
  if (Flag = 'fatal') or (Flag = 'error') or (Role = 'fatal') or (Role = 'error') then
    Result := 'error'
  else if (Flag = 'warning') or (Flag = 'warn') or (Role = 'warning') or (Role = 'warn') then
    Result := 'warning'
  else if (Flag = 'information') or (Flag = 'info') or (Role = 'information') or (Role = 'info') then
    Result := 'information'
  else
    Result := 'error';
  AssertionId := AttributeText(Assertion, 'id');
  Levels := Scenario.selectNodes('s:createReport/s:customLevel');
  for LevelIndex := 0 to Levels.length - 1 do
  begin
    Tokens := string(Levels.item[LevelIndex].text).Split([' ', #9, #10, #13], TStringSplitOptions.ExcludeEmpty);
    for Token in Tokens do
      if Token = AssertionId then
        Exit(AttributeText(Levels.item[LevelIndex], 'level'));
  end;
end;

// Die Engine und ihre COM-/Saxon-Ressourcen bleiben an den aufrufenden Thread gebunden.
// Ohne explizite Auswahl gilt ausschließlich die Saxon-DLL neben der aktiven Anwendung.
constructor TMGKositValidator.Create(const SaxonLibraryFile: string);
var
  LibraryFile: string;
begin
  inherited Create;
  FScenarios := TObjectList<TMGKositScenarioDefinition>.Create(True);
  LibraryFile := SaxonLibraryFile;
  if LibraryFile = '' then
    LibraryFile := TPath.Combine(ExtractFilePath(ExpandFileName(ParamStr(0))), 'saxonc-core-he.dll');
  FEngine := TMGKositEngine.Create(LibraryFile);
  RegisterFrameworkResources;
end;

// Rechnungen und Berichte sind bereits als Strings im Ergebnis enthalten.
destructor TMGKositValidator.Destroy;
begin
  FreeAndNil(FScenarios);
  FreeAndNil(FEngine);
  inherited;
end;

// Anzahl der fachlichen Szenarien über alle geladenen Konfigurationen.
function TMGKositValidator.GetScenarioCount: Integer;
begin
  Result := FScenarios.Count;
end;

// Erzeugungszähler erlauben dem Aufrufer eine Laufzeitkontrolle ohne Einblick in native Handles.
function TMGKositValidator.GetStatistics: TMGKositStatistics;
begin
  Result := FEngine.Statistics;
  Result.SvrlProjectionMs := FSvrlProjectionMs;
  // Speicherübergaben benötigen weder Arbeitsverzeichnisse noch temporäre Dateibereinigung.
  Result.WorkingDirectoryMs := 0;
  Result.TemporaryCleanupMs := 0;
end;

// Original-XSD validiert die Konfiguration, bevor sie in die aktive Liste gelangt.
procedure TMGKositValidator.AddScenario(const ScenarioFile, RepositoryDirectory: string);
var
  Document: IXMLDOMDocument3;
  Nodes, Resources: IXMLDOMNodeList;
  Definition: TMGKositScenarioDefinition;
  Pending: TObjectList<TMGKositScenarioDefinition>;
  Index, ResourceIndex: Integer;
  RepositoryPath, Diagnostic, NoScenarioFile: string;
begin
  Document := FEngine.LoadDocument(ScenarioFile);
  SetNamespaces(Document);
  if (Document.documentElement.namespaceURI <> ScenarioNamespace) or
    not AttributeText(Document.documentElement, 'frameworkVersion').StartsWith('1') then
    raise EArgumentException.Create('Nicht unterstützte KoSIT-Konfiguration: ' + ScenarioFile);
  if not FEngine.ValidateDocumentSchemas(Document, [FrameworkUri + 'scenarios.xsd'], Diagnostic) then
    raise EArgumentException.Create('Ungültige KoSIT-Konfiguration: ' + Diagnostic);
  if RepositoryDirectory = '' then
    RepositoryPath := ExtractFilePath(TPath.GetFullPath(ScenarioFile))
  else
    RepositoryPath := TPath.GetFullPath(RepositoryDirectory);
  NoScenarioFile := ResourceFile(RepositoryPath, Document.selectSingleNode('/s:scenarios/s:noScenarioReport/s:resource'));
  Nodes := Document.selectNodes('/s:scenarios/s:scenario');
  Pending := TObjectList<TMGKositScenarioDefinition>.Create(True);
  try
    for Index := 0 to Nodes.length - 1 do
    begin
      Resources := Nodes.item[Index].selectNodes('s:validateWithXmlSchema/s:resource | s:validateWithSchematron/s:resource | s:createReport/s:resource');
      for ResourceIndex := 0 to Resources.length - 1 do
        ResourceFile(RepositoryPath, Resources.item[ResourceIndex]);
      Definition := TMGKositScenarioDefinition.Create;
      Definition.Document := Document;
      Definition.Node := Nodes.item[Index];
      Definition.RepositoryDirectory := RepositoryPath;
      Pending.Add(Definition);
    end;
    FEngine.ConfigureResourceRoots(FResourceRoots + [RepositoryPath]);
    FResourceRoots := FResourceRoots + [RepositoryPath];
    if FNoScenarioReport = '' then
      FNoScenarioReport := NoScenarioFile;
    while Pending.Count > 0 do
      FScenarios.Add(Pending.Extract(Pending[0]));
  finally
    FreeAndNil(Pending);
  end;
end;

// Eine Eingabedatei wird einmal gelesen; Hash, MSXML und Saxon erhalten denselben unveränderten Bytebestand.
function TMGKositValidator.ValidateFile(const XmlFile, Reference: string): TMGKositValidationResult;
var
  DocumentReference: string;
begin
  Result := Default(TMGKositValidationResult);
  DocumentReference := Reference;
  if DocumentReference = '' then
    DocumentReference := ExtractFileName(XmlFile);
  try
    try
      Result := ValidateInternal(FEngine.ReadFileBytes(XmlFile), TPath.GetFullPath(XmlFile), DocumentReference);
    finally
      FEngine.EndDocument;
    end;
  except
    on ExceptionObject: Exception do
    begin
      Result.ProcessingError := True;
      Result.ErrorMessage := ExceptionObject.Message;
      Result.DocumentReference := DocumentReference;
    end;
  end;
end;

// Der Stream wird ab seiner aktuellen Position gelesen und bleibt Eigentum des Aufrufers.
function TMGKositValidator.ValidateStream(Stream: TStream; const Reference: string): TMGKositValidationResult;
var
  DocumentReference: string;
  MemoryStream: TMemoryStream;
  XmlBytes: TBytes;
  Buffer: array[0..65535] of Byte;
  BytesRead: Integer;
begin
  Result := Default(TMGKositValidationResult);
  DocumentReference := Reference;
  if DocumentReference = '' then
    DocumentReference := 'stream.xml';
  try
    if Stream = nil then
      raise EArgumentNilException.Create('XML-Stream fehlt');
    MemoryStream := TMemoryStream.Create;
    try
      // Nicht jeder lesbare Stream unterstützt Size oder Seek, etwa eine Pipe.
      repeat
        BytesRead := Stream.Read(Buffer, SizeOf(Buffer));
        if (BytesRead < 0) or (BytesRead > SizeOf(Buffer)) then
          raise EReadError.Create('XML-Stream kann nicht gelesen werden');
        if BytesRead > 0 then
          MemoryStream.WriteBuffer(Buffer, BytesRead);
      until BytesRead = 0;
      SetLength(XmlBytes, MemoryStream.Size);
      if MemoryStream.Size > 0 then
        Move(MemoryStream.Memory^, XmlBytes[0], MemoryStream.Size);
    finally
      FreeAndNil(MemoryStream);
    end;
    try
      Result := ValidateInternal(XmlBytes, StreamDocumentUri, DocumentReference);
    finally
      FEngine.EndDocument;
    end;
  except
    on ExceptionObject: Exception do
    begin
      Result.ProcessingError := True;
      Result.ErrorMessage := ExceptionObject.Message;
      Result.DocumentReference := DocumentReference;
    end;
  end;
end;

// Fachliche Ablehnung, Parserfehler und Pipelinefehler bleiben voneinander unterscheidbar.
function TMGKositValidator.ValidateInternal(const XmlBytes: TBytes; const SourceUri, Reference: string): TMGKositValidationResult;
var
  InputDocument, ReportInput, SchematronDocument, ReportDocument, ErrorDocument, SvrlSchema: IXMLDOMDocument3;
  Root, EngineNode, Identification, HashNode, Wellformedness, SchemaResult, SchematronResult, ResultsNode, ErrorNode, HtmlNode, SvrlNode: IXMLDOMNode;
  Resources, Assertions: IXMLDOMNodeList;
  Definition, Selected: TMGKositScenarioDefinition;
  NamespaceBindings, SchemaFiles: TArray<string>;
  Index, AssertionIndex, MatchCount, FailedAssertions: Integer;
  Diagnostic, ParseError, ReportStylesheet, InputDocumentUri: string;
  InputDocumentBytes, SchematronBytes, ReportInputBytes, ReportBytes: TBytes;
  Parsed, Accepted: Boolean;
  InputStream: TBytesStream;
  ProjectionWatch: TStopwatch;
begin
  Result := Default(TMGKositValidationResult);
  Result.DocumentReference := Reference;
  try
    if FScenarios.Count = 0 then
      raise EInvalidOperation.Create('Keine KoSIT-Konfiguration geladen');
    ReportInput := FEngine.NewDocument;
    SetNamespaces(ReportInput);
    Root := AppendInput(ReportInput, ReportInput, 'createReportInput');
    (Root as IXMLDOMElement).setAttribute('frameworkVersion', '1.0.0');
    EngineNode := AppendInput(ReportInput, Root, 'engine');
    AppendInput(ReportInput, EngineNode, 'name', 'MGGM XML Validator für Delphi ' + FEngine.Version);
    AppendInput(ReportInput, Root, 'timestamp', DateToISO8601(Now, False));
    Identification := AppendInput(ReportInput, Root, 'documentIdentification');
    HashNode := AppendInput(ReportInput, Identification, 'documentHash');
    AppendInput(ReportInput, HashNode, 'hashAlgorithm', 'SHA-256');
    InputStream := TBytesStream.Create(XmlBytes);
    try
      AppendInput(ReportInput, HashNode, 'hashValue', TNetEncoding.Base64.EncodeBytesToString(THashSHA2.GetHashBytes(InputStream)));
    finally
      FreeAndNil(InputStream);
    end;
    AppendInput(ReportInput, Identification, 'documentReference', Reference);
    Parsed := False;
    ParseError := '';
    try
      InputDocument := FEngine.LoadDocumentBytes(XmlBytes, SourceUri);
      Parsed := True;
    except
      on ExceptionObject: Exception do
        ParseError := ExceptionObject.Message;
    end;
    Selected := nil;
    MatchCount := 0;
    if Parsed then
    begin
      FEngine.BeginDocumentBytes(XmlBytes, SourceUri);
      for Definition in FScenarios do
        if FEngine.EvaluateBooleanBytes(XmlBytes, SourceUri, NodeText(Definition.Node, 's:match'), ScenarioNamespaces(Definition.Node)) then
        begin
          Inc(MatchCount);
          Selected := Definition;
        end;
    end;
    if MatchCount <> 1 then
      Selected := nil;
    if Selected <> nil then
    begin
      Result.ScenarioName := NodeText(Selected.Node, 's:name');
      AppendImported(ReportInput, Root, Selected.Node);
    end;
    Wellformedness := AppendInput(ReportInput, Root, 'validationResultsWellformedness');
    InputDocumentBytes := XmlBytes;
    InputDocumentUri := SourceUri;
    if not Parsed then
    begin
      AppendSyntaxError(ReportInput, Wellformedness, ParseError, 'SEVERITY_FATAL_ERROR');
      AddFinding(Result, 'fatal', 'XML-WELLFORMEDNESS', ParseError, '', 'wellformedness');
      Result.ProcessingError := True;
      Result.ErrorMessage := ParseError;
      ErrorDocument := FEngine.NewDocument;
      AppendInput(ErrorDocument, ErrorDocument, 'error-message', ParseError);
      InputDocumentBytes := TEncoding.UTF8.GetBytes(ErrorDocument.xml);
      InputDocumentUri := FrameworkUri + 'parse-error.xml';
    end;
    FailedAssertions := 0;
    if Selected <> nil then
    begin
      Resources := Selected.Node.selectNodes('s:validateWithXmlSchema/s:resource');
      SetLength(SchemaFiles, Resources.length);
      SchemaResult := AppendInput(ReportInput, Root, 'validationResultsXmlSchema');
      for Index := 0 to Resources.length - 1 do
      begin
        AppendImported(ReportInput, SchemaResult, Resources.item[Index]);
        SchemaFiles[Index] := ResourceFile(Selected.RepositoryDirectory, Resources.item[Index]);
      end;
      Result.SchemaValid := FEngine.ValidateDocumentSchemas(InputDocument, SchemaFiles, Diagnostic);
      if not Result.SchemaValid then
      begin
        AppendSyntaxError(ReportInput, SchemaResult, Diagnostic, 'SEVERITY_ERROR');
        AddFinding(Result, 'error', 'XML-SCHEMA', Diagnostic, '', 'schema');
      end
      else
      begin
        SvrlSchema := FEngine.LoadDocumentBytes(TNetEncoding.Base64.DecodeStringToBytes(FrameworkSvrlSchemaBase64), FrameworkUri + 'svrl-kosit.xsd');
        SvrlSchema.setProperty('SelectionNamespaces', 'xmlns:xs="http://www.w3.org/2001/XMLSchema"');
        Resources := Selected.Node.selectNodes('s:validateWithSchematron/s:resource');
        for Index := 0 to Resources.length - 1 do
        begin
          SchematronResult := AppendInput(ReportInput, Root, 'validationResultsSchematron');
          AppendImported(ReportInput, SchematronResult, Resources.item[Index]);
          ResultsNode := AppendInput(ReportInput, SchematronResult, 'results');
          try
            SchematronBytes := FEngine.TransformBytes(XmlBytes, SourceUri, ResourceFile(Selected.RepositoryDirectory, Resources.item[Index]));
          except
            on NativeError: EMGKositNative do
            begin
              // Das Original erzeugt auch bei einer gescheiterten Prüfung den Bericht mit processingError.
              Result.ProcessingError := True;
              if Result.ErrorMessage <> '' then
                Result.ErrorMessage := Result.ErrorMessage + sLineBreak;
              Result.ErrorMessage := Result.ErrorMessage + 'Schematron-Prüfung "' + NodeText(Resources.item[Index], 's:name') + '": ' + NativeError.Message;
              SvrlNode := ReportInput.createNode(NODE_ELEMENT, 'svrl:schematron-output', SvrlNamespace);
              ResultsNode.appendChild(SvrlNode);
              Continue;
            end;
          end;
          SchematronDocument := FEngine.LoadDocumentBytes(SchematronBytes, FrameworkUri + 'schematron-' + IntToStr(Index) + '.xml');
          SetNamespaces(SchematronDocument);
          if (SchematronDocument.documentElement.namespaceURI <> SvrlNamespace) or
            (SchematronDocument.documentElement.baseName <> 'schematron-output') then
            raise EInvalidOperation.Create('Schematron liefert kein svrl:schematron-output');
          SvrlNode := ReportInput.importNode(SchematronDocument.documentElement, True);
          ProjectionWatch := TStopwatch.StartNew;
          try
            ProjectSvrlModel(SvrlSchema, SvrlNode);
          finally
            FSvrlProjectionMs := FSvrlProjectionMs + ProjectionWatch.Elapsed.TotalMilliseconds;
          end;
          ResultsNode.appendChild(SvrlNode);
          Assertions := SchematronDocument.selectNodes('/svrl:schematron-output/svrl:failed-assert | /svrl:schematron-output/svrl:successful-report');
          for AssertionIndex := 0 to Assertions.length - 1 do
          begin
            if Assertions.item[AssertionIndex].baseName = 'failed-assert' then
              Inc(FailedAssertions);
            AddFinding(Result, FindingLevel(Assertions.item[AssertionIndex], Selected.Node), AttributeText(Assertions.item[AssertionIndex], 'id'),
              NodeText(Assertions.item[AssertionIndex], 'svrl:text'), AttributeText(Assertions.item[AssertionIndex], 'location'), NodeText(Resources.item[Index], 's:name'));
          end;
        end;
      end;
      ErrorNode := Selected.Node.selectSingleNode('s:createReport/s:resource');
      if ErrorNode <> nil then
        ReportStylesheet := ResourceFile(Selected.RepositoryDirectory, ErrorNode)
      else
      begin
        // Identität ist das im Original ausdrücklich definierte Verhalten ohne createReport.
        ReportStylesheet := FrameworkUri + 'identity.xsl';
      end;
    end
    else
      ReportStylesheet := FNoScenarioReport;
    if Result.ProcessingError then
    begin
      ErrorNode := AppendInput(ReportInput, Root, 'processingError');
      AppendInput(ReportInput, ErrorNode, 'error', Result.ErrorMessage);
    end;
    Result.ReportInputXml := ReportInput.xml;
    if not FEngine.ValidateDocumentSchemas(ReportInput, [FrameworkUri + 'createReportInput.xsd'], Diagnostic) then
      raise EInvalidOperation.Create('KoSIT-Berichtseingabe verletzt das Framework-XSD: ' + Diagnostic);
    // Diese selbst aufgebauten DOMs besitzen keine abweichende XML-Kodierungsdeklaration.
    ReportInputBytes := TEncoding.UTF8.GetBytes(ReportInput.xml);
    ReportBytes := FEngine.TransformBytes(ReportInputBytes, FrameworkUri + 'report-input.xml', ReportStylesheet, InputDocumentBytes, InputDocumentUri);
    Result.ReportXml := DecodeSerializedBytes(ReportBytes);
    ReportDocument := FEngine.LoadDocumentBytes(ReportBytes, FrameworkUri + 'report.xml');
    SetNamespaces(ReportDocument);
    HtmlNode := ReportDocument.selectSingleNode('//h:html[@data-report-type="report"]');
    if HtmlNode = nil then
      HtmlNode := ReportDocument.selectSingleNode('//h:html');
    if HtmlNode <> nil then
    begin
      // XHTML-Serialisierung erhält für text/html nötige Endtags, beispielsweise bei leeren Tabellenzellen.
      Result.ReportHtml := DecodeSerializedBytes(FEngine.TransformBytes(ReportBytes, FrameworkUri + 'report.xml', FrameworkUri + 'extract-html.xsl'));
    end;
    if Selected = nil then
      Result.Acceptance := kaReject
    else if not Result.ProcessingError then
    begin
      NamespaceBindings := ScenarioNamespaces(Selected.Node);
      if Result.SchemaValid and (Selected.Node.selectSingleNode('s:acceptMatch') <> nil) then
        Accepted := FEngine.EvaluateBooleanBytes(ReportBytes, FrameworkUri + 'report.xml', NodeText(Selected.Node, 's:acceptMatch'), NamespaceBindings)
      else
        Accepted := Result.SchemaValid and (FailedAssertions = 0);
      if Accepted then
        Result.Acceptance := kaAccept
      else
        Result.Acceptance := kaReject;
    end;
  except
    on ExceptionObject: Exception do
    begin
      Result.ProcessingError := True;
      Result.Acceptance := kaUndefined;
      Result.ErrorMessage := ExceptionObject.Message;
      if ReportInput <> nil then
        Result.ReportInputXml := ReportInput.xml;
    end;
  end;
end;

// Unveränderte Frameworkbytes erhalten logische URIs und bleiben während der Instanzlebensdauer im Speicher.
// Die Base64-Inhalte werden dekodiert und unter mggm-kosit:/framework/ registriert; die lesbaren Source-Dateien werden nicht eingelesen.
procedure TMGKositValidator.RegisterFrameworkResources;
begin
  FEngine.RegisterMemoryResource(FrameworkUri + 'scenarios.xsd', TNetEncoding.Base64.DecodeStringToBytes(FrameworkScenariosSchemaBase64));
  FEngine.RegisterMemoryResource(FrameworkUri + 'createReportInput.xsd', TNetEncoding.Base64.DecodeStringToBytes(FrameworkReportInputSchemaBase64));
  FEngine.RegisterMemoryResource(FrameworkUri + 'svrl-kosit.xsd', TNetEncoding.Base64.DecodeStringToBytes(FrameworkSvrlSchemaBase64));
  FEngine.RegisterMemoryResource(FrameworkUri + 'xml.xsd', TNetEncoding.Base64.DecodeStringToBytes(FrameworkXmlNamespaceSchemaBase64));
  FEngine.RegisterMemoryResource(FrameworkUri + 'identity.xsl', TNetEncoding.Base64.DecodeStringToBytes(FrameworkIdentityStylesheetBase64));
  FEngine.RegisterMemoryResource(FrameworkUri + 'extract-html.xsl', TEncoding.UTF8.GetBytes(HtmlSerializationStylesheet));
end;

end.
