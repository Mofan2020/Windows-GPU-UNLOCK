# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
<#
.SYNOPSIS
    Reports what the installation left on the machine, and whether the unlock
    ran.

.DESCRIPTION
    Everything the firmware application does is written down in a report file
    on the EFI system partition, in the run directory that it makes for itself
    next to the application. This script finds that partition, finds that
    report, and prints it, together with the state of the boot entry.

    It only reads. Nothing is changed, and the drive letter of the partition
    is not touched: the partition is found by its content, so it does not
    matter whether it still has a letter.

    Run it in a terminal that has the administrator rights:

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\diagnose-installation.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$programData = $env:ProgramData
if (-not $programData) {
    $programData = [System.Environment]::GetFolderPath('CommonApplicationData')
}
$script:StateDirectory = Join-Path $programData 'WindowsGPUUnlock'
$script:StateFile = Join-Path $script:StateDirectory 'install-state.json'
$script:StagingName = 'EFI\WindowsGPUUnlock'

function Write-Heading {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor White
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkGray
}

function Get-CandidateRoots {
    <#
    .SYNOPSIS
        Every place the EFI system partition could be, whether it has a
        drive letter or not.
    #>
    $roots = @()

    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $state = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
            if ($state.espPath) { $roots += [string]$state.espPath }
        } catch {
            Write-Host "The installation record could not be read: $($_.Exception.Message)"
        }
    }

    foreach ($letter in [System.IO.DriveInfo]::GetDrives()) {
        if ($letter.IsReady) { $roots += $letter.RootDirectory.FullName }
    }

    # The volumes that have no letter are reachable by their path.
    try {
        foreach ($volume in @(Get-Volume -ErrorAction SilentlyContinue)) {
            if ($volume.Path) { $roots += [string]$volume.Path }
        }
    } catch {
        Write-Host "The volumes could not be listed: $($_.Exception.Message)"
    }

    return $roots | Where-Object { $_ } | Select-Object -Unique
}

function Find-StagingDirectory {
    <#
    .SYNOPSIS
        The directory that holds the application, wherever the partition is.
    #>
    foreach ($root in (Get-CandidateRoots)) {
        $candidate = Join-Path $root $script:StagingName
        if (Test-Path -LiteralPath (Join-Path $candidate 'UNLOCK.EFI')) {
            return [pscustomobject]@{
                Root   = $root
                Staging = $candidate
            }
        }
    }
    return $null
}

function Get-BcdText {
    param([string[]]$Arguments)
    $systemRoot = $env:SystemRoot
    if (-not $systemRoot) {
        $systemRoot = [System.Environment]::GetFolderPath('Windows')
    }
    if (-not $systemRoot) { return '' }
    $bcdedit = Join-Path $systemRoot 'System32\bcdedit.exe'
    if (-not (Test-Path -LiteralPath $bcdedit)) {
        $bcdedit = Join-Path $systemRoot 'Sysnative\bcdedit.exe'
    }
    if (-not (Test-Path -LiteralPath $bcdedit)) {
        return ''
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $bcdedit @Arguments 2>&1
    } finally {
        $ErrorActionPreference = $previous
    }
    return (@($output) | ForEach-Object { [string]$_ }) -join "`r`n"
}

Write-Heading 'The installation record'

if (Test-Path -LiteralPath $script:StateFile) {
    $state = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
    Write-Host ("  entry        : {0}" -f $(if ($state.EntryId) { $state.EntryId } else { '(none)' }))
    Write-Host ("  description  : {0}" -f $(if ($state.EntryDescription) { $state.EntryDescription } else { '(none)' }))
    Write-Host ("  partition    : {0}" -f $state.espPath)
    Write-Host ("  drive letter : {0} (added by the installation: {1})" -f $state.espDriveLetter, $state.espLetterAdded)
    Write-Host ("  staged in    : {0}" -f $state.stagingRoot)
    Write-Host ("  state        : {0}" -f $state.Action)
    Write-Host ("  installed at : {0}" -f $state.installedUtc)
    Write-Host ("  backup       : {0}" -f $state.BackupRoot)
} else {
    Write-Host '  There is no installation record.' -ForegroundColor Yellow
}

Write-Heading 'The EFI system partition'

$found = Find-StagingDirectory
if (-not $found) {
    Write-Host '  The application was not found on any of the partitions that were looked at.' -ForegroundColor Red
    Write-Host '  The partition holds it in \EFI\WindowsGPUUnlock\UNLOCK.EFI.' -ForegroundColor Yellow
} else {
    Write-Host ("  root     : {0}" -f $found.Root)
    Write-Host ("  staging  : {0}" -f $found.Staging)

    Write-Host ''
    Write-Host '  what is in the staging directory:'
    foreach ($item in @(Get-ChildItem -LiteralPath $found.Staging -Force -ErrorAction SilentlyContinue)) {
        $stamp = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        if ($item.PSIsContainer) {
            Write-Host ("    {0,-14} {1}  (directory)" -f $item.Name, $stamp)
        } else {
            Write-Host ("    {0,-14} {1,12:N0} bytes  {2}" -f $item.Name, $item.Length, $stamp)
        }
    }

    Write-Heading 'The run directories'

    $runs = @(Get-ChildItem -LiteralPath $found.Staging -Directory -Filter 'RUN*' -Force -ErrorAction SilentlyContinue |
            Sort-Object Name)
    if ($runs.Count -eq 0) {
        Write-Host '  There is no run directory.' -ForegroundColor Yellow
        Write-Host '  The application makes one for every boot, before it does anything else.' -ForegroundColor Yellow
        Write-Host '  So there was no boot in which the application got that far.' -ForegroundColor Yellow
    } else {
        Write-Host ("  {0} run directories" -f $runs.Count)
        foreach ($run in $runs) {
            $report = Join-Path $run.FullName 'REPORT.TXT'
            if (Test-Path -LiteralPath $report) {
                $info = Get-Item -LiteralPath $report
                Write-Host ("    {0}  REPORT.TXT  {1:N0} bytes  {2}" -f `
                        $run.Name, $info.Length, $info.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
            } else {
                Write-Host ("    {0}  (no report)" -f $run.Name) -ForegroundColor Yellow
            }
        }
    }
}

Write-Heading 'The boot entry'

if (Test-Path -LiteralPath $script:StateFile) {
    $state = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
    if ($state.EntryId) {
        Write-Host '  the entry that was registered:'
        Write-Host (Get-BcdText @('/enum', [string]$state.EntryId, '/v'))
    } else {
        Write-Host '  There is no entry in the record.' -ForegroundColor Yellow
    }
}

Write-Host '  the firmware boot order:'
Write-Host (Get-BcdText @('/enum', '{fwbootmgr}', '/v'))

Write-Heading 'What the last run said'

if ($found) {
    $runs = @(Get-ChildItem -LiteralPath $found.Staging -Directory -Filter 'RUN*' -Force -ErrorAction SilentlyContinue |
            Sort-Object Name)
    $reports = @($runs | ForEach-Object { Join-Path $_.FullName 'REPORT.TXT' } | Where-Object { Test-Path -LiteralPath $_ })
    if ($reports.Count -gt 0) {
        $newest = $reports | Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } | Select-Object -Last 1
        Write-Host ("  the newest report is {0}" -f $newest)
        Write-Host ''
        Get-Content -LiteralPath $newest | ForEach-Object { Write-Host ("    " + $_) }
    } else {
        Write-Host '  There is no report to read.' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Nothing was changed by this script.' -ForegroundColor DarkGray
