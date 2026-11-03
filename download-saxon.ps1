[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$TargetDirectory = 'build'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Die feste Version und beide Hashes binden den Download an das geprüfte Herstellerpaket.
$SaxonArchiveUrl = 'https://downloads.saxonica.com/SaxonC/HE/12/SaxonCHE-windows-x86_64-12-10-1.zip'
$SaxonArchiveHash = '319d23516d2290491149ad71831c3b54ac3b61dba137e03ed88df60f03ce48d2'
$SaxonLibraryHash = '2a15c4631efa5b45a86b63b0618da32acf5552abf653c36b54f1b2932df94a6c'
$SaxonScriptDirectory = $PSScriptRoot

function Assert-SaxonHash {
    param([string]$Path, [string]$ExpectedHash)
    # Ein fehlender oder abweichender Inhalt darf nicht installiert werden.
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualHash -ne $ExpectedHash) {
        throw "SHA256-Prüfung fehlgeschlagen: $Path (erwartet $ExpectedHash, erhalten $actualHash)."
    }
}

function Assert-SaxonTargetPath {
    param([string]$Path)
    # Verknüpfungen dürfen die Installation nicht in andere Verzeichnisse umleiten.
    $currentPath = $Path
    while ($currentPath) {
        if (Test-Path -LiteralPath $currentPath) {
            $item = Get-Item -LiteralPath $currentPath -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Zielkonflikt: Verknüpfung im Zielpfad $currentPath."
            }
            if (($currentPath -ne $Path) -and -not $item.PSIsContainer) {
                throw "Zielkonflikt: Datei statt Verzeichnis $currentPath."
            }
        }
        $currentPath = [IO.Path]::GetDirectoryName($currentPath)
    }
}

function Receive-SaxonArchive {
    param([string]$Path)
    # Windows PowerShell 5.1 benötigt TLS 1.2 für den Herstellerdownload.
    $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $SaxonArchiveUrl -OutFile $Path -UseBasicParsing -ErrorAction Stop
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
    }
}

function Invoke-SaxonDownload {
    param([string]$Destination = 'build')
    # Relative Ziele beziehen sich wie das Standardziel auf das Skriptverzeichnis.
    if ([string]::IsNullOrWhiteSpace($Destination)) {
        throw 'Das Zielverzeichnis darf nicht leer sein.'
    }
    if (-not [IO.Path]::IsPathRooted($Destination)) {
        $Destination = Join-Path $SaxonScriptDirectory $Destination
    }
    $Destination = [IO.Path]::GetFullPath($Destination)
    Assert-SaxonTargetPath $Destination
    if ([IO.File]::Exists($Destination)) {
        throw "Zielkonflikt: Datei statt Zielverzeichnis $Destination."
    }

    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('mggm-saxon-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temporaryDirectory)
    $temporaryFiles = New-Object 'System.Collections.Generic.List[string]'
    $archive = $null
    try {
        $archivePath = Join-Path $temporaryDirectory 'saxon.zip'
        $temporaryFiles.Add($archivePath)
        Receive-SaxonArchive $archivePath
        Assert-SaxonHash $archivePath $SaxonArchiveHash
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
        $selectedFiles = @(
            @{ Entry = 'SaxonCCoreHE/bin/saxonc-core-he.dll'; Target = 'saxonc-core-he.dll' },
            @{ Entry = 'notices/LICENSE.txt'; Target = 'Notices/SaxonC/SDK/LICENSE.txt' },
            @{ Entry = 'notices/JAMESCLARK.txt'; Target = 'Notices/SaxonC/SDK/JAMESCLARK.txt' },
            @{ Entry = 'notices/JLINE2.txt'; Target = 'Notices/SaxonC/SDK/JLINE2.txt' }
        )
        foreach ($selectedFile in $selectedFiles) {
            $entries = @($archive.Entries | Where-Object { $_.FullName -ceq $selectedFile.Entry })
            if ($entries.Count -ne 1) {
                throw "Herstellerpaket enthält den Eintrag nicht eindeutig: $($selectedFile.Entry)."
            }
            $stagedPath = Join-Path $temporaryDirectory ([IO.Path]::GetFileName($selectedFile.Target))
            $temporaryFiles.Add($stagedPath)
            $inputStream = $entries[0].Open()
            try {
                $outputStream = [IO.File]::Open($stagedPath, [IO.FileMode]::CreateNew)
                try { $inputStream.CopyTo($outputStream) }
                finally { $outputStream.Dispose() }
            }
            finally { $inputStream.Dispose() }
            $selectedFile.Staged = $stagedPath
            $selectedFile.Path = [IO.Path]::Combine($Destination, $selectedFile.Target)
        }
        Assert-SaxonHash $selectedFiles[0].Staged $SaxonLibraryHash
        $archive.Dispose()
        $archive = $null

        # Erst alle Konflikte prüfen, bevor die erste Zieldatei geschrieben wird.
        foreach ($selectedFile in $selectedFiles) {
            Assert-SaxonTargetPath $selectedFile.Path
            if ([IO.Directory]::Exists($selectedFile.Path)) {
                throw "Zielkonflikt: Verzeichnis statt Datei $($selectedFile.Path)."
            }
            if ([IO.File]::Exists($selectedFile.Path)) {
                $expectedHash = (Get-FileHash -LiteralPath $selectedFile.Staged -Algorithm SHA256).Hash
                Assert-SaxonHash $selectedFile.Path $expectedHash
            }
        }
        foreach ($selectedFile in $selectedFiles) {
            if ([IO.File]::Exists($selectedFile.Path)) {
                $expectedHash = (Get-FileHash -LiteralPath $selectedFile.Staged -Algorithm SHA256).Hash
                Assert-SaxonHash $selectedFile.Path $expectedHash
            }
            else {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($selectedFile.Path))
                # Copy mit overwrite=false schützt auch vor zwischenzeitlich angelegten Dateien.
                [IO.File]::Copy($selectedFile.Staged, $selectedFile.Path, $false)
            }
        }
        Write-Host "SaxonC-HE 12.10.1 geprüft: $Destination"
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
        foreach ($temporaryFile in $temporaryFiles) {
            if ([IO.File]::Exists($temporaryFile)) { [IO.File]::Delete($temporaryFile) }
        }
        [IO.Directory]::Delete($temporaryDirectory, $false)
    }
}

# Dot-Sourcing erlaubt isolierte Tests der Prüfschritte ohne produktive URL-Option.
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-SaxonDownload $TargetDirectory }
    catch {
        [Console]::Error.WriteLine("SaxonC-Download fehlgeschlagen: " + $_.Exception.Message)
        exit 1
    }
}
