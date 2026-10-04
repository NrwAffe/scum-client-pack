param(
    [string]$ManifestUrl = "https://raw.githubusercontent.com/NrwAffe/scum-client-pack/main/manifest-pak.json",
    [switch]$Repair
)

$ErrorActionPreference = "Stop"
$LauncherVersion = "0.1.2"

$GameRoot = "C:\SteamLibrary\steamapps\common\SCUM"
$GameExe  = Join-Path $GameRoot "SCUM\Binaries\Win64\SCUM.exe"
$PakDir   = Join-Path $GameRoot "SCUM\Content\Paks\~mods"
$StateDir = Join-Path $GameRoot ".scum-pak-launcher"
$StateFile = Join-Path $StateDir "installed.json"

function Log([string]$Text) { Write-Host ("[SCUM PAK Launcher] " + $Text) }
function Ensure-Directory([string]$Path) { if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null } }
function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }

function Load-State {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return [pscustomobject]@{ launcherVersion=$LauncherVersion; installed=@() }
    }
    try { return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json }
    catch { return [pscustomobject]@{ launcherVersion=$LauncherVersion; installed=@() } }
}

function Save-State($InstalledEntries) {
    Ensure-Directory $StateDir
    [ordered]@{
        launcherVersion = $LauncherVersion
        savedAtUtc = [DateTime]::UtcNow.ToString("o")
        installed = @($InstalledEntries)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Download-File([string]$Url, [string]$Destination, [switch]$NoCache) {
    $requestUrl = $Url
    $headers = @{}
    if ($NoCache) {
        $sep = if ($requestUrl.Contains("?")) { "&" } else { "?" }
        $requestUrl = $requestUrl + $sep + "_=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        $headers["Pragma"] = "no-cache"
    }
    Log "Download: $requestUrl"
    Invoke-WebRequest -Uri $requestUrl -OutFile $Destination -UseBasicParsing -Headers $headers
}

function Safe-ManagedPakName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "Leerer PAK-Dateiname." }
    $leaf = [IO.Path]::GetFileName($Name)
    if ($leaf -ne $Name) { throw "PAK-Dateiname darf keinen Pfad enthalten: $Name" }
    if (-not $leaf.ToLowerInvariant().EndsWith(".pak")) { throw "Nur .pak-Dateien erlaubt: $Name" }
    return $leaf
}

Write-Host ""
Write-Host "=========================================="
Write-Host " SCUM PAK Launcher v$LauncherVersion"
Write-Host "=========================================="
Write-Host ""

if (-not (Test-Path -LiteralPath $GameExe -PathType Leaf)) {
    throw "SCUM.exe nicht gefunden: $GameExe"
}

Ensure-Directory $PakDir
Ensure-Directory $StateDir

$tempRoot = Join-Path $env:TEMP ("SCUM-PakLauncher-" + [guid]::NewGuid().ToString("N"))
Ensure-Directory $tempRoot

try {
    $manifestPath = Join-Path $tempRoot "manifest.json"
    Log "Lade Mod-Manifest..."
    Download-File -Url $ManifestUrl -Destination $manifestPath -NoCache

    $manifestRaw = Get-Content -LiteralPath $manifestPath -Raw
    Log "Manifest-Inhalt:"
    Write-Host $manifestRaw

    try {
        $manifest = $manifestRaw | ConvertFrom-Json
    } catch {
        throw "Manifest ist kein gueltiges JSON.`n$($_.Exception.Message)"
    }

    if (-not $manifest.mods) {
        $manifest | Add-Member -NotePropertyName mods -NotePropertyValue @() -Force
    }

    Log ("Pack-Version: " + $manifest.packVersion)

    $state = Load-State
    $newState = @()
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($mod in @($manifest.mods)) {
        if ($mod.enabled -eq $false) { continue }

        $name = Safe-ManagedPakName ([string]$mod.fileName)
        [void]$wanted.Add($name)

        $expected = ([string]$mod.sha256).ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($expected)) {
            throw "SHA256 fehlt fuer $name"
        }

        $target = Join-Path $PakDir $name
        $needs = $Repair.IsPresent -or -not (Test-Path -LiteralPath $target -PathType Leaf)

        if (-not $needs) {
            $actual = Get-Sha256 $target
            if ($actual -ne $expected) {
                Log "Update/Reparatur erforderlich: $name"
                $needs = $true
            } else {
                Log "OK: $name"
            }
        }

        if ($needs) {
            $download = Join-Path $tempRoot $name
            Download-File -Url ([string]$mod.url) -Destination $download

            $got = Get-Sha256 $download
            if ($got -ne $expected) {
                throw "SHA256 stimmt nicht fuer $name. Erwartet: $expected / Ist: $got"
            }

            Copy-Item -LiteralPath $download -Destination $target -Force
            Log "Installiert: $name"
        }

        $newState += [pscustomobject]@{
            id = [string]$mod.id
            fileName = $name
            version = [string]$mod.version
            sha256 = $expected
        }
    }

    foreach ($old in @($state.installed)) {
        $oldName = [string]$old.fileName
        if ([string]::IsNullOrWhiteSpace($oldName)) { continue }

        if (-not $wanted.Contains($oldName)) {
            $oldPath = Join-Path $PakDir $oldName
            if (Test-Path -LiteralPath $oldPath -PathType Leaf) {
                Remove-Item -LiteralPath $oldPath -Force
                Log "Entfernt: $oldName"
            }
        }
    }

    Save-State $newState

    Log "Mods synchronisiert."
    Log "Starte SCUM mit -fileopenlog -nobattleye..."

    Start-Process `
        -FilePath $GameExe `
        -ArgumentList "-fileopenlog","-nobattleye" `
        -WorkingDirectory (Split-Path $GameExe -Parent)

    Log "SCUM gestartet."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
