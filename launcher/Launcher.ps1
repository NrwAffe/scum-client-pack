Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateFile = Join-Path $Root "installed-state.json"
$SettingsFile = Join-Path $Root "settings.json"
$LogFile = Join-Path $Root "launcher.log"
$CacheDir = Join-Path $Root "cache"

function Write-Log {
    param([string]$Message)
    $line = ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message)
    Add-Content -LiteralPath $LogFile -Value $line
    if($script:txtLog) {
        $script:txtLog.AppendText($line + [Environment]::NewLine)
        $script:txtLog.SelectionStart = $script:txtLog.TextLength
        $script:txtLog.ScrollToCaret()
    }
}

function Load-JsonFile {
    param([string]$Path, $Default)
    if(Test-Path $Path) {
        try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
        catch { return $Default }
    }
    return $Default
}

function Save-JsonFile {
    param([string]$Path, $Object)
    $Object | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-SteamLibraries {
    $libs = New-Object System.Collections.Generic.List[string]
    $steamRoots = @()

    try {
        $p = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath
        if($p){ $steamRoots += $p }
    } catch {}

    try {
        $p = (Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction Stop).InstallPath
        if($p){ $steamRoots += $p }
    } catch {}

    $steamRoots += @("$env:ProgramFiles(x86)\Steam", "$env:ProgramFiles\Steam")

    foreach($root in ($steamRoots | Where-Object { $_ } | Select-Object -Unique)) {
        $root = $root -replace '/', '\'
        if(Test-Path $root) {
            if(-not $libs.Contains($root)){ $libs.Add($root) }

            $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
            if(Test-Path $vdf) {
                foreach($line in Get-Content -LiteralPath $vdf -ErrorAction SilentlyContinue) {
                    if($line -match '"path"\s+"([^"]+)"') {
                        $p = $Matches[1] -replace '\\\\','\'
                        if((Test-Path $p) -and -not $libs.Contains($p)) { $libs.Add($p) }
                    }
                }
            }
        }
    }
    return $libs
}

function Find-SCUMPath {
    foreach($lib in Get-SteamLibraries) {
        $candidate = Join-Path $lib "steamapps\common\SCUM\SCUM\Binaries\Win64\SCUM.exe"
        if(Test-Path $candidate){ return (Resolve-Path $candidate).Path }
    }
    foreach($drive in "C","D","E","F","G","H") {
        $candidate = "${drive}:\SteamLibrary\steamapps\common\SCUM\SCUM\Binaries\Win64\SCUM.exe"
        if(Test-Path $candidate){ return (Resolve-Path $candidate).Path }
    }
    return ""
}

function Get-SCUMRoot {
    param([string]$ScumExe)
    if(-not $ScumExe) { return "" }
    try {
        return Split-Path (Split-Path (Split-Path (Split-Path $ScumExe -Parent) -Parent) -Parent) -Parent
    } catch {
        return ""
    }
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-InstalledState {
    if(-not $script:InstalledState) {
        $script:InstalledState = Load-JsonFile $StateFile ([pscustomobject]@{ items = @{} })
        if(-not $script:InstalledState.items) {
            $script:InstalledState = [pscustomobject]@{ items = @{} }
        }
    }
    return $script:InstalledState
}

function Save-InstalledState {
    Save-JsonFile $StateFile (Get-InstalledState)
}

function Resolve-RelativeDestination {
    param([string]$GameRoot, [string]$Dest)
    if([string]::IsNullOrWhiteSpace($Dest)) { return $GameRoot }
    $destNorm = $Dest -replace '/', '\'
    if([System.IO.Path]::IsPathRooted($destNorm)) { return $destNorm }
    return Join-Path $GameRoot $destNorm
}

function Ensure-Dir {
    param([string]$Path)
    if(-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Download-File {
    param([string]$Url, [string]$OutFile)
    $requestUrl = $Url
    if($Url -match '\?') { $requestUrl += "&_=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    else { $requestUrl += "?_=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    Write-Log "Download: $Url"
    Invoke-WebRequest -Uri $requestUrl -OutFile $OutFile -UseBasicParsing
}

function Normalize-Manifest {
    param($Manifest)

    if(-not $Manifest.schemaVersion) {
        throw "Manifest ungueltig: schemaVersion fehlt."
    }

    if($Manifest.mods) {
        foreach($m in $Manifest.mods) {
            if(-not $m.destination) {
                $fileName = [string]$m.fileName
                if($fileName.ToLowerInvariant().EndsWith(".pak")) {
                    $m | Add-Member -NotePropertyName destination -NotePropertyValue "SCUM\Content\Paks\~mods" -Force
                    $m | Add-Member -NotePropertyName requiredFiles -NotePropertyValue @($fileName) -Force
                } else {
                    $m | Add-Member -NotePropertyName destination -NotePropertyValue ("SCUM\Binaries\Win64\Mods\" + $m.id) -Force
                }
            }
        }
    }

    return $Manifest
}

function Load-Manifest {
    $url = $script:txtManifest.Text.Trim()
    if([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show("Manifest-URL fehlt.","Launcher") | Out-Null
        return
    }

    try {
        Ensure-Dir $CacheDir
        $manifestPath = Join-Path $CacheDir "manifest.json"

        $urlsToTry = New-Object System.Collections.Generic.List[string]
        $urlsToTry.Add($url)

        if($url -match '/manifest\.json$') {
            $fallback = $url -replace '/manifest\.json$','/manifest-pak.json'
            if(-not $urlsToTry.Contains($fallback)) { $urlsToTry.Add($fallback) }
        }

        $loadedUrl = $null
        $lastError = $null

        foreach($tryUrl in $urlsToTry) {
            try {
                if(Test-Path $manifestPath){ Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue }
                Download-File -Url $tryUrl -OutFile $manifestPath
                $loadedUrl = $tryUrl
                break
            } catch {
                $lastError = $_
                Write-Log "Manifest nicht erreichbar: $tryUrl"
            }
        }

        if(-not $loadedUrl) {
            if($lastError){ throw $lastError.Exception }
            throw "Kein Manifest erreichbar."
        }

        $rawManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $script:Manifest = Normalize-Manifest $rawManifest

        $script:txtManifest.Text = $loadedUrl
        $script:Settings.manifestUrl = $loadedUrl
        $script:Settings.scumPath = $script:txtScum.Text.Trim()
        Save-JsonFile $SettingsFile $script:Settings

        Write-Log "Manifest geladen: $loadedUrl"
        Write-Log "Pack-Version: $($script:Manifest.packVersion)"
        Refresh-ModList
    }
    catch {
        Write-Log "FEHLER Manifest: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Manifest konnte nicht geladen werden.`r`n`r`n$($_.Exception.Message)","Launcher") | Out-Null
    }
}

function Get-ModStatus {
    param($Mod)

    $gameRoot = Get-SCUMRoot $script:txtScum.Text.Trim()
    if(-not $gameRoot) { return "SCUM fehlt" }

    $dest = Resolve-RelativeDestination -GameRoot $gameRoot -Dest ([string]$Mod.destination)
    $state = Get-InstalledState
    $installedVersion = ""
    if($state.items.PSObject.Properties.Name -contains $Mod.id) {
        $installedVersion = [string]$state.items.$($Mod.id).version
    }

    $requiredOk = $true
    if($Mod.requiredFiles) {
        foreach($rf in $Mod.requiredFiles) {
            $p = Join-Path $dest ([string]$rf -replace '/', '\')
            if(-not (Test-Path $p)) { $requiredOk = $false; break }
        }
    } else {
        if(-not (Test-Path $dest)) { $requiredOk = $false }
    }

    if(-not $requiredOk) { return "Nicht installiert" }
    if($installedVersion -ne [string]$Mod.version) { return "Update verfuegbar" }
    return "OK"
}

function Refresh-ModList {
    $script:listMods.Items.Clear()
    if(-not $script:Manifest -or -not $script:Manifest.mods) { return }

    foreach($mod in $script:Manifest.mods) {
        $state = Get-InstalledState
        $installedVersion = ""
        if($state.items.PSObject.Properties.Name -contains $mod.id) {
            $installedVersion = [string]$state.items.$($mod.id).version
        }
        $status = Get-ModStatus -Mod $mod

        $item = New-Object System.Windows.Forms.ListViewItem([string]$mod.id)
        [void]$item.SubItems.Add([string]$mod.name)
        [void]$item.SubItems.Add($status)
        [void]$item.SubItems.Add($installedVersion)
        [void]$item.SubItems.Add([string]$mod.version)
        [void]$item.SubItems.Add([string]$mod.destination)
        [void]$script:listMods.Items.Add($item)
    }
}

function Install-OrUpdateMods {
    if(-not $script:Manifest -or -not $script:Manifest.mods) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst Manifest laden.","Launcher") | Out-Null
        return
    }

    $scumExe = $script:txtScum.Text.Trim()
    if(-not (Test-Path $scumExe)) {
        [System.Windows.Forms.MessageBox]::Show("SCUM.exe nicht gefunden.","Launcher") | Out-Null
        return
    }

    $gameRoot = Get-SCUMRoot $scumExe
    Ensure-Dir $CacheDir
    $state = Get-InstalledState

    foreach($mod in $script:Manifest.mods) {
        if($mod.enabled -eq $false) {
            Write-Log "Uebersprungen (disabled): $($mod.name)"
            continue
        }

        try {
            $tmp = Join-Path $CacheDir ("download_" + $mod.id + "_" + [IO.Path]::GetFileName(([string]$mod.url)))
            if(Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

            Download-File -Url ([string]$mod.url) -OutFile $tmp

            if($mod.sha256) {
                $got = Get-Sha256 $tmp
                $want = ([string]$mod.sha256).Trim().ToUpperInvariant()
                if($got -ne $want) {
                    throw "SHA256 stimmt nicht fuer $($mod.id).`r`nErwartet: $want`r`nIst: $got"
                }
            }

            $dest = Resolve-RelativeDestination -GameRoot $gameRoot -Dest ([string]$mod.destination)
            Ensure-Dir $dest

            $ext = [IO.Path]::GetExtension($tmp).ToLowerInvariant()
            switch($ext) {
                ".zip" {
                    Expand-Archive -LiteralPath $tmp -DestinationPath $dest -Force
                }
                default {
                    $targetName = if($mod.fileName) { [string]$mod.fileName } else { [IO.Path]::GetFileName($tmp) }
                    Copy-Item -LiteralPath $tmp -Destination (Join-Path $dest $targetName) -Force
                }
            }

            if($mod.requiredFiles) {
                foreach($rf in $mod.requiredFiles) {
                    $p = Join-Path $dest ([string]$rf -replace '/', '\')
                    if(-not (Test-Path $p)) {
                        throw "Paket $($mod.id) wurde installiert, aber requiredFiles fehlen: $rf"
                    }
                }
            }

            $state.items | Add-Member -NotePropertyName ([string]$mod.id) -NotePropertyValue ([pscustomobject]@{
                version = [string]$mod.version
                installedAt = (Get-Date).ToString("s")
            }) -Force

            Write-Log "Installiert/aktualisiert: $($mod.name) $($mod.version)"
        }
        catch {
            Write-Log "FEHLER bei $($mod.name): $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Fehler bei $($mod.name):`r`n`r`n$($_.Exception.Message)","Launcher") | Out-Null
        }
    }

    Save-InstalledState
    Refresh-ModList
}

function Verify-Mods {
    if(-not $script:Manifest -or -not $script:Manifest.mods) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst Manifest laden.","Launcher") | Out-Null
        return
    }

    $scumExe = $script:txtScum.Text.Trim()
    if(-not (Test-Path $scumExe)) {
        [System.Windows.Forms.MessageBox]::Show("SCUM.exe nicht gefunden.","Launcher") | Out-Null
        return
    }

    $gameRoot = Get-SCUMRoot $scumExe
    $messages = New-Object System.Collections.Generic.List[string]

    foreach($mod in $script:Manifest.mods) {
        $dest = Resolve-RelativeDestination -GameRoot $gameRoot -Dest ([string]$mod.destination)
        $ok = $true
        if($mod.requiredFiles) {
            foreach($rf in $mod.requiredFiles) {
                $p = Join-Path $dest ([string]$rf -replace '/', '\')
                if(-not (Test-Path $p)) { $ok = $false; $messages.Add("$($mod.id): fehlt $rf") }
            }
        } else {
            if(-not (Test-Path $dest)) { $ok = $false; $messages.Add("$($mod.id): Zielordner fehlt") }
        }

        if($ok) {
            $messages.Add("$($mod.id): OK")
            Write-Log "Pruefung OK: $($mod.id)"
        } else {
            Write-Log "Pruefung FEHLER: $($mod.id)"
        }
    }

    Refresh-ModList
    [System.Windows.Forms.MessageBox]::Show(($messages -join "`r`n"),"Pruefergebnis") | Out-Null
}


function Start-ClientHelpers {
    if(-not $script:Manifest -or -not $script:Manifest.mods) { return }

    $scumExe = $script:txtScum.Text.Trim()
    $gameRoot = Get-SCUMRoot $scumExe
    if(-not $gameRoot) { return }

    foreach($mod in $script:Manifest.mods) {
        if($mod.enabled -eq $false) { continue }
        if(-not $mod.clientHelper) { continue }
        if($mod.clientHelper.startWithGame -ne $true) { continue }

        try {
            $dest = Resolve-RelativeDestination -GameRoot $gameRoot -Dest ([string]$mod.destination)
            $helper = Join-Path $dest ([string]$mod.clientHelper.executable -replace '/', '\')

            if(-not (Test-Path $helper)) {
                Write-Log "[HELPER:$($mod.id)] Datei fehlt: $helper"
                continue
            }

            Write-Log "[HELPER:$($mod.id)] Starte: $helper"

            $ext = [IO.Path]::GetExtension($helper).ToLowerInvariant()
            if($ext -eq ".bat" -or $ext -eq ".cmd") {
                $hp = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$helper`"" -WorkingDirectory (Split-Path $helper -Parent) -PassThru
            }
            elseif($ext -eq ".ps1") {
                $hp = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile","-STA","-ExecutionPolicy","Bypass","-File","`"$helper`"" -WorkingDirectory (Split-Path $helper -Parent) -PassThru
            }
            else {
                $hp = Start-Process -FilePath $helper -WorkingDirectory (Split-Path $helper -Parent) -PassThru
            }

            Write-Log "[HELPER:$($mod.id)] gestartet PID=$($hp.Id)"
        }
        catch {
            Write-Log "[HELPER:$($mod.id)] FEHLER: $($_.Exception.Message)"
        }
    }
}

function Start-SCUMGame {
    $scumExe = $script:txtScum.Text.Trim()
    if(-not (Test-Path $scumExe)) {
        [System.Windows.Forms.MessageBox]::Show("SCUM.exe nicht gefunden.","Launcher") | Out-Null
        return
    }

    $launchArgs = @()
    if($script:Settings.launchArguments) {
        foreach($a in $script:Settings.launchArguments) { $launchArgs += [string]$a }
    }

    $script:Settings.scumPath = $scumExe
    $script:Settings.manifestUrl = $script:txtManifest.Text.Trim()
    Save-JsonFile $SettingsFile $script:Settings

    Start-ClientHelpers

    Write-Log "Starte SCUM: $($launchArgs -join ' ')"
    Start-Process -FilePath $scumExe -WorkingDirectory (Split-Path $scumExe -Parent) -ArgumentList $launchArgs
}

function Browse-SCUMExe {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "SCUM.exe|SCUM.exe|EXE-Dateien|*.exe"
    $dlg.Title = "SCUM.exe auswaehlen"
    if($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:txtScum.Text = $dlg.FileName
    }
}

# Load settings
$defaultSettings = [pscustomobject]@{
    manifestUrl = "https://raw.githubusercontent.com/NrwAffe/scum-client-pack/main/manifest-pak.json"
    scumPath = ""
    launchArguments = @("-nobattleye","-fileopenlog")
}
$script:Settings = Load-JsonFile $SettingsFile $defaultSettings
if(-not $script:Settings.launchArguments) { $script:Settings.launchArguments = @("-nobattleye","-fileopenlog") }
if(-not $script:Settings.manifestUrl) { $script:Settings.manifestUrl = $defaultSettings.manifestUrl }
if(-not $script:Settings.scumPath) { $script:Settings.scumPath = Find-SCUMPath }

# Build UI
$form = New-Object System.Windows.Forms.Form
$form.Text = "SCUM Server Launcher"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1180,760)
$form.MinimumSize = New-Object System.Drawing.Size(1180,760)
$form.BackColor = [System.Drawing.Color]::Black

$bgPath = Join-Path $Root "assets\server-background.png"
$bg = New-Object System.Windows.Forms.PictureBox
$bg.Dock = "Fill"
$bg.SizeMode = "StretchImage"
if(Test-Path $bgPath) { $bg.Image = [System.Drawing.Image]::FromFile($bgPath) }
$form.Controls.Add($bg)

$overlay = New-Object System.Windows.Forms.Panel
$overlay.Dock = "Fill"
$overlay.BackColor = [System.Drawing.Color]::FromArgb(110, 10, 10, 10)
$bg.Controls.Add($overlay)

$title = New-Object System.Windows.Forms.Label
$title.Text = "SCUM MOD LAUNCHER"
$title.ForeColor = [System.Drawing.Color]::White
$title.BackColor = [System.Drawing.Color]::Transparent
$title.Font = New-Object System.Drawing.Font("Segoe UI",24,[System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(24,18)
$title.Size = New-Object System.Drawing.Size(500,44)
$overlay.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Mods aktualisieren, pruefen und SCUM starten"
$subtitle.ForeColor = [System.Drawing.Color]::Gainsboro
$subtitle.BackColor = [System.Drawing.Color]::Transparent
$subtitle.Font = New-Object System.Drawing.Font("Segoe UI",11,[System.Drawing.FontStyle]::Regular)
$subtitle.Location = New-Object System.Drawing.Point(26,60)
$subtitle.Size = New-Object System.Drawing.Size(480,24)
$overlay.Controls.Add($subtitle)

$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Location = New-Object System.Drawing.Point(20,100)
$panelTop.Size = New-Object System.Drawing.Size(1125,120)
$panelTop.BackColor = [System.Drawing.Color]::FromArgb(145,20,20,20)
$overlay.Controls.Add($panelTop)

function Make-Label([string]$Text,[int]$X,[int]$Y,[int]$W=120) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.ForeColor = [System.Drawing.Color]::White
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
    $l.Location = New-Object System.Drawing.Point($X,$Y)
    $l.Size = New-Object System.Drawing.Size($W,24)
    return $l
}

$panelTop.Controls.Add((Make-Label "SCUM.exe" 18 16 100))
$script:txtScum = New-Object System.Windows.Forms.TextBox
$script:txtScum.Location = New-Object System.Drawing.Point(120,14)
$script:txtScum.Size = New-Object System.Drawing.Size(780,26)
$script:txtScum.Font = New-Object System.Drawing.Font("Segoe UI",10)
$script:txtScum.Text = [string]$script:Settings.scumPath
$panelTop.Controls.Add($script:txtScum)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Durchsuchen"
$btnBrowse.Location = New-Object System.Drawing.Point(915,13)
$btnBrowse.Size = New-Object System.Drawing.Size(185,30)
$btnBrowse.Add_Click({ Browse-SCUMExe })
$panelTop.Controls.Add($btnBrowse)

$panelTop.Controls.Add((Make-Label "Manifest URL" 18 56 100))
$script:txtManifest = New-Object System.Windows.Forms.TextBox
$script:txtManifest.Location = New-Object System.Drawing.Point(120,54)
$script:txtManifest.Size = New-Object System.Drawing.Size(980,26)
$script:txtManifest.Font = New-Object System.Drawing.Font("Segoe UI",10)
$script:txtManifest.Text = [string]$script:Settings.manifestUrl
$panelTop.Controls.Add($script:txtManifest)

$btnLoadManifest = New-Object System.Windows.Forms.Button
$btnLoadManifest.Text = "Manifest laden"
$btnLoadManifest.Location = New-Object System.Drawing.Point(18,88)
$btnLoadManifest.Size = New-Object System.Drawing.Size(160,24)
$btnLoadManifest.Add_Click({ Load-Manifest })
$panelTop.Controls.Add($btnLoadManifest)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = "Mods updaten / installieren"
$btnInstall.Location = New-Object System.Drawing.Point(190,88)
$btnInstall.Size = New-Object System.Drawing.Size(220,24)
$btnInstall.Add_Click({ Install-OrUpdateMods })
$panelTop.Controls.Add($btnInstall)

$btnVerify = New-Object System.Windows.Forms.Button
$btnVerify.Text = "Mods pruefen"
$btnVerify.Location = New-Object System.Drawing.Point(420,88)
$btnVerify.Size = New-Object System.Drawing.Size(130,24)
$btnVerify.Add_Click({ Verify-Mods })
$panelTop.Controls.Add($btnVerify)

$btnStartGame = New-Object System.Windows.Forms.Button
$btnStartGame.Text = "SCUM starten"
$btnStartGame.Location = New-Object System.Drawing.Point(560,88)
$btnStartGame.Size = New-Object System.Drawing.Size(130,24)
$btnStartGame.Add_Click({ Start-SCUMGame })
$panelTop.Controls.Add($btnStartGame)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Text = "Launcher-Ordner"
$btnOpenFolder.Location = New-Object System.Drawing.Point(700,88)
$btnOpenFolder.Size = New-Object System.Drawing.Size(150,24)
$btnOpenFolder.Add_Click({ Start-Process explorer.exe $Root })
$panelTop.Controls.Add($btnOpenFolder)

$listPanel = New-Object System.Windows.Forms.Panel
$listPanel.Location = New-Object System.Drawing.Point(20,235)
$listPanel.Size = New-Object System.Drawing.Size(1125,250)
$listPanel.BackColor = [System.Drawing.Color]::FromArgb(145,18,18,18)
$overlay.Controls.Add($listPanel)

$listTitle = New-Object System.Windows.Forms.Label
$listTitle.Text = "Mod-Uebersicht"
$listTitle.ForeColor = [System.Drawing.Color]::White
$listTitle.BackColor = [System.Drawing.Color]::Transparent
$listTitle.Font = New-Object System.Drawing.Font("Segoe UI",12,[System.Drawing.FontStyle]::Bold)
$listTitle.Location = New-Object System.Drawing.Point(10,8)
$listTitle.Size = New-Object System.Drawing.Size(220,24)
$listPanel.Controls.Add($listTitle)

$script:listMods = New-Object System.Windows.Forms.ListView
$script:listMods.Location = New-Object System.Drawing.Point(12,38)
$script:listMods.Size = New-Object System.Drawing.Size(1100,200)
$script:listMods.View = "Details"
$script:listMods.FullRowSelect = $true
$script:listMods.GridLines = $true
$script:listMods.BackColor = [System.Drawing.Color]::FromArgb(28,28,28)
$script:listMods.ForeColor = [System.Drawing.Color]::White
$script:listMods.Columns.Add("ID",160) | Out-Null
$script:listMods.Columns.Add("Name",220) | Out-Null
$script:listMods.Columns.Add("Status",170) | Out-Null
$script:listMods.Columns.Add("Installiert",130) | Out-Null
$script:listMods.Columns.Add("Manifest",130) | Out-Null
$script:listMods.Columns.Add("Ziel",270) | Out-Null
$listPanel.Controls.Add($script:listMods)

$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Location = New-Object System.Drawing.Point(20,500)
$logPanel.Size = New-Object System.Drawing.Size(1125,200)
$logPanel.BackColor = [System.Drawing.Color]::FromArgb(145,18,18,18)
$overlay.Controls.Add($logPanel)

$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Text = "Log"
$logTitle.ForeColor = [System.Drawing.Color]::White
$logTitle.BackColor = [System.Drawing.Color]::Transparent
$logTitle.Font = New-Object System.Drawing.Font("Segoe UI",12,[System.Drawing.FontStyle]::Bold)
$logTitle.Location = New-Object System.Drawing.Point(10,8)
$logTitle.Size = New-Object System.Drawing.Size(220,24)
$logPanel.Controls.Add($logTitle)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Location = New-Object System.Drawing.Point(12,36)
$script:txtLog.Size = New-Object System.Drawing.Size(1100,150)
$script:txtLog.Multiline = $true
$script:txtLog.ReadOnly = $true
$script:txtLog.ScrollBars = "Vertical"
$script:txtLog.BackColor = [System.Drawing.Color]::FromArgb(23,23,23)
$script:txtLog.ForeColor = [System.Drawing.Color]::White
$script:txtLog.Font = New-Object System.Drawing.Font("Consolas",9)
$logPanel.Controls.Add($script:txtLog)

Write-Log "Launcher bereit."
if($script:txtScum.Text) { Write-Log "SCUM erkannt: $($script:txtScum.Text)" }
Write-Log "Tipp: Manifest laden -> Mods updaten -> Mods pruefen -> SCUM starten"

try { Load-Manifest } catch {}

[void]$form.ShowDialog()
