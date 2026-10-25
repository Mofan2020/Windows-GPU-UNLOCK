# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
<#
.SYNOPSIS
    Turns the binaries of the installer into the text files it carries.

.DESCRIPTION
    The EFI application and the zstdcat helper are carried as base64 text
    rather than as files. Antivirus software on a Windows machine often
    refuses an unsigned EFI application, and then the installer cannot even
    unpack it, so it says "Error opening file for writing" and stops. Text
    is not noticed, and the script unpacks the real files itself, where a
    refusal can be reported with the reason.

    The digests of the two files are written into a manifest, so the script
    can check that it unpacked the ones that were packed.

.PARAMETER Application
    The EFI application.

.PARAMETER Helper
    The zstdcat helper.

.PARAMETER OutputDirectory
    Where the text files are written. The helper goes into the helper
    directory, because the installer takes it from there.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Application,
    [Parameter(Mandatory)][string]$Helper,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$HelperOutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $HelperOutputDirectory) {
    $HelperOutputDirectory = $OutputDirectory
}

foreach ($path in @($Application, $Helper)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "The file does not exist: $path"
    }
}

foreach ($directory in @($OutputDirectory, $HelperOutputDirectory)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

function Write-Base64File {
    param([string]$Source, [string]$Target)

    $bytes = [System.IO.File]::ReadAllBytes($Source)
    $text = [Convert]::ToBase64String($bytes)
    # The text is written in lines, because a single long line is awkward to
    # look at. The reader takes the whitespace out again.
    $lines = for ($offset = 0; $offset -lt $text.Length; $offset += 76) {
        $text.Substring($offset, [Math]::Min(76, $text.Length - $offset))
    }
    [System.IO.File]::WriteAllLines($Target, $lines)
    Write-Host ("  {0}  {1} bytes -> {2}" -f (Split-Path -Leaf $Source), $bytes.Length, (Split-Path -Leaf $Target))
}

Write-Base64File -Source $Application -Target (Join-Path $OutputDirectory 'unlock-payload.txt')
Write-Base64File -Source $Helper -Target (Join-Path $HelperOutputDirectory 'helper-payload.txt')

# The parentheses matter: in PowerShell the comma binds tighter than the
# plus, so without them this becomes one string with the two entries in it.
$manifest = @(
    ('application=' + (Get-FileHash -LiteralPath $Application -Algorithm SHA256).Hash.ToLowerInvariant())
    ('helper=' + (Get-FileHash -LiteralPath $Helper -Algorithm SHA256).Hash.ToLowerInvariant())
)
[System.IO.File]::WriteAllLines((Join-Path $OutputDirectory 'payload-manifest.txt'), $manifest)
Write-Host ("  payload-manifest.txt  {0}" -f (Split-Path -Leaf $OutputDirectory))
