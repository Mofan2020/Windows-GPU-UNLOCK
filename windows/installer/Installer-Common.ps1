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

function Expand-EmbeddedPayload {
    <#
    .SYNOPSIS
        Writes a file that the installer carries as base64 text.

    .DESCRIPTION
        The EFI application and the helper are carried in text files, because
        antivirus software on a Windows machine often refuses an unsigned EFI
        application, and then the installer cannot even unpack it. The text
        is not noticed, and the file is written out here, where a refusal
        can be reported with the reason.
    #>
    param(
        [Parameter(Mandatory)][string]$TextFile,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $TextFile)) {
        throw "The installer is incomplete: $TextFile is missing"
    }

    $text = [System.IO.File]::ReadAllText($TextFile)
    $bytes = [Convert]::FromBase64String(($text -replace '\s', ''))

    $directory = Split-Path -Parent $TargetPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes($TargetPath, $bytes)

    $actual = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "The unpacked file does not match: expected $ExpectedSha256, got $actual"
    }
    return $TargetPath
}

function Expand-InstallerPayload {
    <#
    .SYNOPSIS
        Writes the EFI application and the helper out of the text files that
        the installer carries them in.

    .DESCRIPTION
        The digests are read from the manifest that was written when the
        installer was built, so the files that are unpacked are the ones that
        were packed.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$TargetDirectory
    )

    $manifestPath = Join-Path $ScriptRoot 'payload-manifest.txt'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "The installer is incomplete: $manifestPath is missing"
    }

    $digests = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($manifestPath)) {
        # The file holds "name=digest" entries. They are read one by one, so
        # that a line with more than one of them is still understood.
        foreach ($token in ($line -split '[\s]+')) {
            if ($token -match '^([a-z]+)=([0-9a-fA-F]{64})$') {
                $digests[$Matches[1]] = $Matches[2].ToLowerInvariant()
            }
        }
    }
    foreach ($name in @('application', 'helper')) {
        if (-not $digests.ContainsKey($name)) {
            throw "The installer is incomplete: the manifest has no digest for $name"
        }
    }

    $application = Expand-EmbeddedPayload `
        -TextFile (Join-Path $ScriptRoot 'unlock-payload.txt') `
        -TargetPath (Join-Path $TargetDirectory 'UNLOCK.EFI') `
        -ExpectedSha256 $digests['application']

    $helper = Expand-EmbeddedPayload `
        -TextFile (Join-Path $ScriptRoot 'helper-payload.txt') `
        -TargetPath (Join-Path $TargetDirectory 'zstdcat.exe') `
        -ExpectedSha256 $digests['helper']

    return [pscustomobject]@{
        Application = $application
        Helper      = $helper
    }
}

function Get-BcdDisplayOrder {    <#
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
