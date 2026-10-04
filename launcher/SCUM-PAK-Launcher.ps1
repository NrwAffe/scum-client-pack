param(
    [string]$ManifestUrl = "https://raw.githubusercontent.com/NrwAffe/scum-client-pack/main/manifest-pak.json",
    [switch]$Repair
)

$ErrorActionPreference = "Stop"
$LauncherVersion = "0.1.0"

# --------------------------------------------------------------------
# CONFIG
# --------------------------------------------------------------------
$GameRoot = "C:\SteamLibrary\steamapps\common\SCUM"
$GameExe  = Join-Path $GameRoot "SCUM\Binaries\Win64\SCUM.exe"
$PakDir   = Join-Path $GameRoot "SCUM\Content\Paks\~mods"
$StateDir = Join-Path $GameRoot ".scum-pak-launcher"
$StateFile = Join-Path $StateDir "installed.json"

# --------------------------------------------------------------------
# HELPERS
# --------------------------------------------------------------------
function Log([string]$Text) {
    Write-Host ("[SCUM PAK Launcher] " + $Text)
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return [pscustomobject]@{
            launcherVersion = $LauncherVersion
            installed = @()
        }
    }

    try {
        return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    } catch {
        Log "WARNUNG: State-Datei konnte nicht gelesen werden. Starte mit leerem Zustand."
        return [pscustomobject]@{
            launcherVersion = $LauncherVersion
            installed = @()
        }
    }
}

function Save-State($InstalledEntries) {
    Ensure-Directory $StateDir

    $obj = [ordered]@{
        launcherVersion = $LauncherVersion
        savedAtUtc = [DateTime]::UtcNow.ToString("o")
        installed = @($InstalledEntries)
    }

    $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Download-File([string]$Url, [string]$Destination) {
    Log "Download: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

function Safe-ManagedPakName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "Leerer PAK-Dateiname im Manifest."
    }

    $leaf = [IO.Path]::GetFileName($Name)

    if ($leaf -ne $Name) {
        throw "PAK-Dateiname darf keinen Pfad enthalten: $Name"
    }

    if (-not $leaf.ToLowerInvariant().EndsWith(".pak")) {
        throw "Nur .pak-Dateien sind erlaubt: $Name"
    }

    return $leaf
}

# --------------------------------------------------------------------
# START
# --------------------------------------------------------------------
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
    # --------------------------------------------------------------
    # MANIFEST
    # --------------------------------------------------------------
    $manifestPath = Join-Path $tempRoot "manifest.json"
    Log "Lade Mod-Manifest..."
    Download-File -Url $ManifestUrl -Destination $manifestPath

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    if (-not $manifest.schemaVersion) {
        throw "Manifest enthält keine schemaVersion."
    }

    if (-not $manifest.mods) {
        Log "Manifest enthält keine Mods."
        $manifest | Add-Member -NotePropertyName mods -NotePropertyValue @() -Force
    }

    Log ("Pack-Version: " + $manifest.packVersion)

    $state = Load-State
    $newState = @()
    $wantedNames = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

    # --------------------------------------------------------------
    # INSTALL / UPDATE
    # --------------------------------------------------------------
    foreach ($mod in @($manifest.mods)) {
        if ($mod.enabled -eq $false) {
            continue
        }

        $name = Safe-ManagedPakName ([string]$mod.fileName)
        [void]$wantedNames.Add($name)

        if ([string]::IsNullOrWhiteSpace([string]$mod.url)) {
            throw "URL fehlt für Mod '$name'."
        }

        if ([string]::IsNullOrWhiteSpace([string]$mod.sha256)) {
            throw "SHA256 fehlt für Mod '$name'."
        }

        $expectedHash = ([string]$mod.sha256).ToUpperInvariant()
        $target = Join-Path $PakDir $name

        $needsInstall = $Repair.IsPresent -or -not (Test-Path -LiteralPath $target -PathType Leaf)

        if (-not $needsInstall) {
            $actual = Get-Sha256 $target
            if ($actual -ne $expectedHash) {
                Log "Update/Reparatur erforderlich: $name"
                $needsInstall = $true
            } else {
                Log "OK: $name"
            }
        }

        if ($needsInstall) {
            $download = Join-Path $tempRoot $name
            Download-File -Url ([string]$mod.url) -Destination $download

            $downloadHash = Get-Sha256 $download
            if ($downloadHash -ne $expectedHash) {
                throw "SHA256 stimmt nicht für '$name'. Erwartet: $expectedHash / Ist: $downloadHash"
            }

            Copy-Item -LiteralPath $download -Destination $target -Force
            Log "Installiert: $name"
        }

        $newState += [pscustomobject]@{
            id = [string]$mod.id
            fileName = $name
            version = [string]$mod.version
            sha256 = $expectedHash
        }
    }

    # --------------------------------------------------------------
    # REMOVE OLD MANAGED PAKS
    # Only files previously installed by THIS launcher are removed.
    # Foreign/manual PAKs are left untouched.
    # --------------------------------------------------------------
    foreach ($old in @($state.installed)) {
        $oldName = [string]$old.fileName
        if ([string]::IsNullOrWhiteSpace($oldName)) {
            continue
        }

        if (-not $wantedNames.Contains($oldName)) {
            $oldPath = Join-Path $PakDir $oldName

            if (Test-Path -LiteralPath $oldPath -PathType Leaf) {
                Remove-Item -LiteralPath $oldPath -Force
                Log "Veralteten verwalteten Mod entfernt: $oldName"
            }
        }
    }

    Save-State $newState

    # --------------------------------------------------------------
    # START SCUM
    # --------------------------------------------------------------
    Log "Mods synchronisiert."
    Log "Starte SCUM ohne BattlEye..."

    Start-Process `
        -FilePath $GameExe `
        -ArgumentList "-nobattleye" `
        -WorkingDirectory (Split-Path $GameExe -Parent)

    Log "SCUM gestartet."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
