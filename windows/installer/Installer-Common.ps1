# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
<#
.SYNOPSIS
    Shared output helpers for the installer scripts.

.DESCRIPTION
    The installer scripts are loaded in any order and by different entry
    points, so the helpers that format the progress output live in their own
    file. Loading it more than once is harmless.
#>

Set-StrictMode -Version Latest

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Green
}

function Write-Note {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Red
}

function Get-BcdDisplayOrder {
    <#
    .SYNOPSIS
        Reads the firmware boot order from a boot configuration dump.
    .DESCRIPTION
        The order lives in the displayorder element of the firmware boot
        manager. It is the order in which the boot manager tries the entries,
        so the unlock application is put in front of the Windows Boot Manager.
    #>
    param([Parameter(Mandatory)][string]$Text)

    $match = [regex]::Match($Text, '(?ms)^displayorder\s+(.*?)(?=\r?\n\S|\z)')
    if (-not $match.Success) {
        return @()
    }
    return @([regex]::Matches($match.Groups[1].Value, '\{(?:bootmgr|[0-9a-f-]{36})\}') | ForEach-Object { $_.Value })
}
