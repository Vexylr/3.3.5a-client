#Requires -Version 5.1
<#
.SYNOPSIS
  Downloads client.*.bin from this repo's GitHub Release and installs WoW 3.3.5a.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [string]$BinDir = '',
    [string]$GitHubRepo = 'Vexylr/3.3.5a-client'
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red }

function Save-Url([string]$Url, [string]$OutFile) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & curl.exe -L --fail --retry 3 --retry-delay 2 --progress-bar -o $OutFile $Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url (curl exit $LASTEXITCODE)" }
        return
    }
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Get-SevenZip {
    $dir = Join-Path $env:TEMP 'wow335-7zip'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $exe = Join-Path $dir '7zr.exe'
    if (-not (Test-Path $exe)) {
        Write-Step 'Fetching unpacker'
        # Official reduced 7-Zip console (extracts .7z / multi-volume)
        Save-Url 'https://www.7-zip.org/a/7zr.exe' $exe
    }
    if (-not (Test-Path $exe)) { throw 'Failed to download 7zr.exe' }
    return $exe
}

function Get-LocalParts([string]$dir) {
    Get-ChildItem -Path $dir -Filter 'client.*.bin' -File -ErrorAction SilentlyContinue |
        Sort-Object Name
}

function Test-PartsComplete([System.IO.FileInfo[]]$parts, $manifest) {
    if (-not $parts -or $parts.Count -eq 0) { return $false }
    $expected = 1
    foreach ($p in $parts) {
        if ($p.Name -notmatch '^client\.(\d+)\.bin$') { return $false }
        if ([int]$Matches[1] -ne $expected) { return $false }
        $expected++
    }
    if ($manifest -and $manifest.partCount -and ($parts.Count -ne [int]$manifest.partCount)) {
        return $false
    }
    return $true
}

function Get-LatestReleaseAssets([string]$repo) {
    $api = "https://api.github.com/repos/$repo/releases/latest"
    Write-Step "Looking up latest release ($repo)"
    try {
        $release = Invoke-RestMethod -Uri $api -Headers @{
            'User-Agent' = 'WoW-335a-Installer'
            'Accept'     = 'application/vnd.github+json'
        }
    } catch {
        throw "Could not reach GitHub Releases for $repo.`n$($_.Exception.Message)"
    }
    if (-not $release.assets) {
        throw "No release assets found on $repo yet (bins still uploading / release still draft)."
    }
    Write-Ok "Release: $($release.tag_name)"
    return $release
}

function Sync-ClientBins([string]$repo, [string]$destDir) {
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $release = Get-LatestReleaseAssets $repo

    $binAssets = @($release.assets | Where-Object { $_.name -match '^client\.\d+\.bin$' } | Sort-Object name)
    $manifestAsset = $release.assets | Where-Object { $_.name -eq 'manifest.json' } | Select-Object -First 1

    if ($binAssets.Count -eq 0) {
        throw "Release $($release.tag_name) has no client.*.bin files yet."
    }

    if ($manifestAsset) {
        Write-Step 'Downloading manifest.json'
        Save-Url $manifestAsset.browser_download_url (Join-Path $destDir 'manifest.json')
    }

    $i = 0
    foreach ($asset in $binAssets) {
        $i++
        $out = Join-Path $destDir $asset.name
        if ((Test-Path $out) -and ((Get-Item $out).Length -eq [int64]$asset.size)) {
            Write-Ok "[$i/$($binAssets.Count)] $($asset.name) already downloaded"
            continue
        }
        $gb = [math]::Round($asset.size / 1GB, 2)
        Write-Step "[$i/$($binAssets.Count)] Downloading $($asset.name) ($gb GB)"
        $tmp = "$out.partial"
        if (Test-Path $tmp) { Remove-Item $tmp -Force }
        Save-Url $asset.browser_download_url $tmp
        Move-Item -LiteralPath $tmp -Destination $out -Force
        Write-Ok "Saved $($asset.name)"
    }
}

$ScriptDir = $PSScriptRoot
if (-not $BinDir) {
    $BinDir = Join-Path $ScriptDir 'bins'
    if (-not (Test-Path $BinDir)) { $BinDir = $ScriptDir }
}

Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  WoW 3.3.5a Client Installer'
Write-Host '========================================' -ForegroundColor Cyan

$SevenZip = Get-SevenZip

$downloadDir = Join-Path $ScriptDir 'bins'
$parts = Get-LocalParts $BinDir
if (-not $parts) { $parts = Get-LocalParts $downloadDir }

$manifestPath = Join-Path $downloadDir 'manifest.json'
if (-not (Test-Path $manifestPath)) { $manifestPath = Join-Path $BinDir 'manifest.json' }
$manifest = $null
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
}

if (-not (Test-PartsComplete $parts $manifest)) {
    Write-Host 'Downloading client bins from GitHub...' -ForegroundColor Yellow
    try {
        Sync-ClientBins -repo $GitHubRepo -destDir $downloadDir
    } catch {
        Write-Fail $_.Exception.Message
        exit 1
    }
    $BinDir = $downloadDir
    $parts = Get-LocalParts $BinDir
    $manifestPath = Join-Path $BinDir 'manifest.json'
    if (Test-Path $manifestPath) {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    }
} else {
    if ((Get-LocalParts $downloadDir).Count -gt 0) { $BinDir = $downloadDir }
}

if (-not (Test-PartsComplete $parts $manifest)) {
    Write-Fail "Client parts are incomplete in:`n  $BinDir"
    exit 1
}

$totalGb = [math]::Round((($parts | Measure-Object Length -Sum).Sum / 1GB), 2)
Write-Host ("Parts ready : {0}  ({1} GB)" -f $parts.Count, $totalGb)

if (-not $InstallDir) {
    $default = 'C:\Games\World of Warcraft 3.3.5a'
    Write-Host ''
    Write-Host 'Choose where to install the client.' -ForegroundColor Yellow
    Write-Host 'A folder picker will open. Pick a folder (or Cancel to type a path).'
    Write-Host "Default if you cancel/skip: $default"
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Choose WoW 3.3.5a install folder'
        $dialog.ShowNewFolderButton = $true
        if (Test-Path 'C:\Games') { $dialog.SelectedPath = 'C:\Games' }
        $result = $dialog.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $dialog.SelectedPath) {
            # Install into a subfolder inside the chosen location
            $InstallDir = Join-Path $dialog.SelectedPath 'World of Warcraft 3.3.5a'
        }
    } catch {
        Write-Host 'Folder picker unavailable; type a path instead.' -ForegroundColor DarkYellow
    }
    if (-not $InstallDir) {
        $typed = Read-Host "Install folder [$default]"
        $InstallDir = if ([string]::IsNullOrWhiteSpace($typed)) { $default } else { $typed }
    }
    Write-Host "Install path: $InstallDir" -ForegroundColor Green
}

$InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir)

if (Test-Path (Join-Path $InstallDir 'Wow.exe')) {
    $ans = Read-Host "Wow.exe already exists in that folder. Overwrite / extract into it? (y/N)"
    if ($ans -notmatch '^[Yy]') { Write-Host 'Cancelled.'; exit 0 }
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$work = Join-Path $env:TEMP ("wow335-install-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

try {
    Write-Step 'Preparing archive volumes'
    $i = 1
    foreach ($p in $parts) {
        $name = 'client.7z.{0:D3}' -f $i
        $dest = Join-Path $work $name
        try {
            New-Item -ItemType HardLink -Path $dest -Target $p.FullName -ErrorAction Stop | Out-Null
        } catch {
            Copy-Item -LiteralPath $p.FullName -Destination $dest -Force
        }
        $i++
    }
    Write-Ok "Prepared $($parts.Count) volumes"

    $first = Join-Path $work 'client.7z.001'
    Write-Step "Extracting into $InstallDir"
    & $SevenZip x $first "-o$InstallDir" -y
    if ($LASTEXITCODE -ne 0) {
        throw "Extract failed with exit code $LASTEXITCODE"
    }

    if (-not (Test-Path (Join-Path $InstallDir 'Wow.exe'))) {
        throw 'Extract finished but Wow.exe was not found.'
    }

    Write-Step 'Install complete'
    Write-Ok $InstallDir
    Write-Host ''
    Write-Host 'Start the game with Wow.exe' -ForegroundColor Green

    $launch = Read-Host 'Open install folder now? (Y/n)'
    if ($launch -notmatch '^[Nn]') {
        Start-Process explorer.exe -ArgumentList $InstallDir
    }
}
finally {
    if (Test-Path $work) {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
