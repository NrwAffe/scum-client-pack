Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ErrorActionPreference = "Stop"
$LauncherVersion = "0.1.3"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root "launcher.config.json"
$StateDir = Join-Path $Root ".launcher-state"
$StatePath = Join-Path $StateDir "installed.json"

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

function Write-Log([string]$Message) {
    $stamp = Get-Date -Format "HH:mm:ss"
    $script:LogBox.AppendText("[$stamp] $Message`r`n")
    $script:LogBox.SelectionStart = $script:LogBox.Text.Length
    $script:LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Is-PlaceholderUrl([string]$Url) {
    return [string]::IsNullOrWhiteSpace($Url) -or $Url -match "YOUR-DOMAIN|example\.com|example/"
}

function Assert-AllowedUrl([string]$Url) {
    $u = [Uri]$Url
    if ($u.Scheme -eq "https") { return }
    if ($script:Config.AllowHttp -eq $true -and $u.Scheme -eq "http") { return }
    throw "Unsichere Download-URL blockiert: $Url"
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}


function Unblock-InstalledFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    try {
        Unblock-File -LiteralPath $Path -ErrorAction Stop
        return $true
    }
    catch {
        try {
            Remove-Item -LiteralPath $Path -Stream Zone.Identifier -ErrorAction Stop
            return $true
        }
        catch {
            return $false
        }
    }
}

function Unblock-Ue4ssRuntimeFiles {
    if (-not $script:GameRoot) { return }

    $win64 = Join-Path $script:GameRoot "SCUM\Binaries\Win64"
    if (-not (Test-Path $win64)) {
        $win64 = Join-Path $script:GameRoot "Binaries\Win64"
    }

    foreach ($name in @("dwmapi.dll", "UE4SS.dll")) {
        $path = Join-Path $win64 $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            if (Unblock-InstalledFile $path) {
                Write-Log ("Windows-Blockierung entfernt/geprüft: " + $name)
            } else {
                Write-Log ("WARNUNG: Konnte Windows-Blockierung nicht entfernen: " + $name)
            }
        }
    }
}

function Load-Config {
    if (-not (Test-Path $ConfigPath)) { throw "launcher.config.json fehlt." }
    return Get-Content $ConfigPath -Raw | ConvertFrom-Json
}

function Save-Config {
    $script:Config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Load-State {
    if (-not (Test-Path $StatePath)) {
        return [pscustomobject]@{
            packVersion = ""
            packages = @{}
        }
    }

    try {
        return Get-Content $StatePath -Raw | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            packVersion = ""
            packages = @{}
        }
    }
}

function Save-State($state) {
    $state | ConvertTo-Json -Depth 20 | Set-Content -Path $StatePath -Encoding UTF8
}

function Get-SteamRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    $candidates = @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam"
    )

    foreach ($key in $candidates) {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in @("SteamPath","InstallPath")) {
                if ($p.$name -and (Test-Path $p.$name)) {
                    $path = [IO.Path]::GetFullPath([string]$p.$name)
                    if (-not $roots.Contains($path)) { $roots.Add($path) }
                }
            }
        } catch {}
    }

    $expanded = New-Object System.Collections.Generic.List[string]
    foreach ($steam in $roots) {
        if (-not $expanded.Contains($steam)) { $expanded.Add($steam) }

        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            $txt = Get-Content $vdf -Raw
            $matches = [regex]::Matches($txt, '"path"\s+"([^"]+)"')
            foreach ($m in $matches) {
                $path = $m.Groups[1].Value -replace '\\\\','\'
                if (Test-Path $path) {
                    $path = [IO.Path]::GetFullPath($path)
                    if (-not $expanded.Contains($path)) { $expanded.Add($path) }
                }
            }
        }
    }

    return $expanded
}

function Find-ScumRoot {
    if ($script:Config.GameRoot -and (Test-Path $script:Config.GameRoot)) {
        return [IO.Path]::GetFullPath([string]$script:Config.GameRoot)
    }

    foreach ($steam in Get-SteamRoots) {
        $candidate = Join-Path $steam "steamapps\common\SCUM"
        if (Test-Path (Join-Path $candidate "SCUM\Binaries\Win64")) {
            return [IO.Path]::GetFullPath($candidate)
        }
        if (Test-Path (Join-Path $candidate "Binaries\Win64")) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    return $null
}

function Get-RemoteManifest {
    if (Is-PlaceholderUrl $script:Config.ManifestUrl) {
        throw "ManifestUrl ist noch nicht konfiguriert. Bitte launcher.config.json anpassen."
    }

    Assert-AllowedUrl $script:Config.ManifestUrl
    Write-Log "Lade Manifest..."
    return Invoke-RestMethod -Uri $script:Config.ManifestUrl -UseBasicParsing
}

function Get-PackageList($manifest) {
    $list = New-Object System.Collections.ArrayList

    if ($manifest.ue4ss -and $manifest.ue4ss.enabled -eq $true) {
        [void]$list.Add($manifest.ue4ss)
    }

    if ($manifest.mods) {
        foreach ($m in $manifest.mods) {
            if ($m.enabled -eq $true) {
                [void]$list.Add($m)
            }
        }
    }

    return $list
}

function Get-InstalledVersion($state, [string]$id) {
    if ($null -eq $state.packages) { return "" }

    $prop = $state.packages.PSObject.Properties[$id]
    if ($null -eq $prop) { return "" }

    return [string]$prop.Value.version
}

function Test-RequiredFiles($package) {
    if (-not $package.requiredFiles) { return $true }

    $dest = Join-Path $script:GameRoot ([string]$package.destination)
    foreach ($rel in $package.requiredFiles) {
        $p = Join-Path $dest ([string]$rel)
        if (-not (Test-Path $p)) {
            return $false
        }
    }
    return $true
}

function Download-Package($package) {
    Assert-AllowedUrl ([string]$package.url)

    $tmp = Join-Path $env:TEMP ("MySCUMPkg_" + [Guid]::NewGuid().ToString("N") + ".zip")
    Write-Log ("Download: {0} {1}" -f $package.name, $package.version)
    Invoke-WebRequest -Uri ([string]$package.url) -OutFile $tmp -UseBasicParsing

    $actual = Get-Sha256 $tmp
    $expected = ([string]$package.sha256).ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($expected) -or $expected -match "PUT_SHA256") {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw ("Kein gültiger SHA256 für Paket {0} konfiguriert." -f $package.id)
    }

    if ($actual -ne $expected) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw ("SHA256-Fehler bei {0}. Erwartet {1}, erhalten {2}" -f $package.id, $expected, $actual)
    }

    return $tmp
}

function Install-Package($package, $state) {
    $zip = Download-Package $package
    $extract = Join-Path $env:TEMP ("MySCUMExtract_" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $extract -Force | Out-Null

    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $extract)

        $dest = Join-Path $script:GameRoot ([string]$package.destination)
        New-Item -ItemType Directory -Path $dest -Force | Out-Null

        $destFull = [IO.Path]::GetFullPath($dest)
        $files = Get-ChildItem -Path $extract -File -Recurse

        foreach ($f in $files) {
            $rel = $f.FullName.Substring($extract.Length).TrimStart('\','/')
            $target = [IO.Path]::GetFullPath((Join-Path $dest $rel))

            if (-not $target.StartsWith($destFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsicherer Archivpfad blockiert: $rel"
            }

            $parent = Split-Path -Parent $target
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            Copy-Item $f.FullName $target -Force

            if (-not (Unblock-InstalledFile $target)) {
                Write-Log ("WARNUNG: Datei konnte nicht entsperrt werden: " + $rel)
            }
        }

        if (-not (Test-RequiredFiles $package)) {
            throw ("Paket {0} wurde entpackt, aber requiredFiles fehlen." -f $package.id)
        }

        if ($null -eq $state.packages) {
            $state | Add-Member -NotePropertyName packages -NotePropertyValue ([pscustomobject]@{}) -Force
        }

        $state.packages | Add-Member -NotePropertyName ([string]$package.id) -NotePropertyValue ([pscustomobject]@{
            version = [string]$package.version
            installedAt = (Get-Date).ToString("o")
            destination = [string]$package.destination
        }) -Force

        Write-Log ("Installiert: {0} {1}" -f $package.name, $package.version)
    }
    finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Check-Updates([bool]$Repair) {
    if (-not $script:GameRoot) {
        throw "SCUM-Installation wurde nicht gefunden."
    }

    $manifest = Get-RemoteManifest
    if ([int]$manifest.schemaVersion -ne 1) {
        throw "Nicht unterstützte Manifest-Version."
    }

    $state = Load-State
    $packages = Get-PackageList $manifest
    $needs = @()

    foreach ($p in $packages) {
        $installed = Get-InstalledVersion $state ([string]$p.id)
        $filesOk = Test-RequiredFiles $p
        $versionDiffers = $installed -ne [string]$p.version

        if ($Repair -or $versionDiffers -or -not $filesOk) {
            $needs += $p
            if ($Repair) {
                Write-Log ("Repair geplant: {0}" -f $p.name)
            } elseif ($versionDiffers) {
                Write-Log ("Update nötig: {0} {1} -> {2}" -f $p.name, $installed, $p.version)
            } else {
                Write-Log ("Reparatur nötig: {0} (Dateien fehlen)" -f $p.name)
            }
        } else {
            Write-Log ("Aktuell: {0} {1}" -f $p.name, $p.version)
        }
    }

    if ($needs.Count -eq 0) {
        $state.packVersion = [string]$manifest.packVersion
        Save-State $state
        Write-Log "Alles aktuell."
        return
    }

    $script:Progress.Minimum = 0
    $script:Progress.Maximum = $needs.Count
    $script:Progress.Value = 0

    foreach ($p in $needs) {
        Install-Package $p $state
        $script:Progress.Value++
        [System.Windows.Forms.Application]::DoEvents()
    }

    $state.packVersion = [string]$manifest.packVersion
    Save-State $state
    Write-Log ("Client-Pack aktualisiert auf {0}." -f $manifest.packVersion)
}

function Choose-GameRoot {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "SCUM-Hauptordner auswählen (Steam\steamapps\common\SCUM)"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:GameRoot = [IO.Path]::GetFullPath($dlg.SelectedPath)
        $script:Config.GameRoot = $script:GameRoot
        Save-Config
        Update-PathLabel
        Write-Log ("SCUM-Pfad gesetzt: " + $script:GameRoot)
    }
}

function Update-PathLabel {
    if ($script:GameRoot) {
        $script:PathLabel.Text = "SCUM: " + $script:GameRoot
    } else {
        $script:PathLabel.Text = "SCUM: nicht gefunden"
    }
}

function Start-Scum {
    if (-not $script:GameRoot) { throw "SCUM wurde nicht gefunden." }

    if ($script:Config.AutoUpdateOnStart -eq $true) {
        Check-Updates $false
    }

    Unblock-Ue4ssRuntimeFiles

    $win64 = Join-Path $script:GameRoot "SCUM\\Binaries\\Win64"
    $exe = Join-Path $win64 "SCUM.exe"

    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        $win64 = Join-Path $script:GameRoot "Binaries\\Win64"
        $exe = Join-Path $win64 "SCUM.exe"
    }

    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "SCUM.exe wurde im Win64-Ordner nicht gefunden."
    }

    Write-Log "Starte SCUM direkt ohne BattlEye..."
    Write-Log ("EXE: " + $exe)
    Start-Process -FilePath $exe -ArgumentList "-nobattleye" -WorkingDirectory $win64
}

$script:Config = Load-Config
$script:GameRoot = Find-ScumRoot

$form = New-Object System.Windows.Forms.Form
$form.Text = "My SCUM Server Launcher v$LauncherVersion"
$form.Size = New-Object System.Drawing.Size(760, 520)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$title = New-Object System.Windows.Forms.Label
$title.Text = "SCUM Client Mod Launcher"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20, 18)
$form.Controls.Add($title)

$script:PathLabel = New-Object System.Windows.Forms.Label
$script:PathLabel.AutoSize = $true
$script:PathLabel.Location = New-Object System.Drawing.Point(22, 62)
$form.Controls.Add($script:PathLabel)

$choose = New-Object System.Windows.Forms.Button
$choose.Text = "SCUM-Ordner wählen"
$choose.Size = New-Object System.Drawing.Size(150, 32)
$choose.Location = New-Object System.Drawing.Point(20, 92)
$choose.Add_Click({
    try { Choose-GameRoot } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Fehler") }
})
$form.Controls.Add($choose)

$check = New-Object System.Windows.Forms.Button
$check.Text = "Updates prüfen"
$check.Size = New-Object System.Drawing.Size(150, 42)
$check.Location = New-Object System.Drawing.Point(190, 92)
$check.Add_Click({
    try { Check-Updates $false } catch { Write-Log ("FEHLER: " + $_.Exception.Message); [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Update-Fehler") }
})
$form.Controls.Add($check)

$repair = New-Object System.Windows.Forms.Button
$repair.Text = "Reparieren"
$repair.Size = New-Object System.Drawing.Size(150, 42)
$repair.Location = New-Object System.Drawing.Point(360, 92)
$repair.Add_Click({
    try { Check-Updates $true } catch { Write-Log ("FEHLER: " + $_.Exception.Message); [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Repair-Fehler") }
})
$form.Controls.Add($repair)

$start = New-Object System.Windows.Forms.Button
$start.Text = "SCUM starten"
$start.Size = New-Object System.Drawing.Size(180, 42)
$start.Location = New-Object System.Drawing.Point(530, 92)
$start.Add_Click({
    try { Start-Scum } catch { Write-Log ("FEHLER: " + $_.Exception.Message); [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Start-Fehler") }
})
$form.Controls.Add($start)

$script:Progress = New-Object System.Windows.Forms.ProgressBar
$script:Progress.Location = New-Object System.Drawing.Point(20, 148)
$script:Progress.Size = New-Object System.Drawing.Size(690, 18)
$form.Controls.Add($script:Progress)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = "Vertical"
$script:LogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$script:LogBox.Location = New-Object System.Drawing.Point(20, 182)
$script:LogBox.Size = New-Object System.Drawing.Size(690, 275)
$form.Controls.Add($script:LogBox)

Update-PathLabel
Write-Log "Launcher bereit."
if ($script:GameRoot) {
    Write-Log ("SCUM automatisch gefunden: " + $script:GameRoot)
} else {
    Write-Log "SCUM konnte nicht automatisch gefunden werden. Bitte Ordner auswählen."
}
if (Is-PlaceholderUrl $script:Config.ManifestUrl) {
    Write-Log "HINWEIS: ManifestUrl ist noch ein Platzhalter. Vor Verteilung konfigurieren."
}

[void]$form.ShowDialog()
