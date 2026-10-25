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

function Quote-ProcessArgument {
    <#
    .SYNOPSIS
        Puts one argument in the form that a program on Windows reads.
    #>
    param([string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-ProcessArchitecture {
    <#
    .SYNOPSIS
        Whether this process is a 64 bit one.
    #>
    if ([Environment]::Is64BitProcess) {
        return '64 bit'
    }
    return '32 bit'
}

function Restart-As64Bit {
    <#
    .SYNOPSIS
        Starts this script again as a 64 bit process, if it is not one.

    .DESCRIPTION
        bcdedit.exe is a 64 bit program and there is no 32 bit copy of it. A
        32 bit process cannot see it, because the system directory in the
        path of such a process points at the 32 bit one, and the command is
        then not found at all.

        The 64 bit PowerShell is reached through the Sysnative alias, which
        a 32 bit process may use to get at the 64 bit system directory.

        The function does not return when it starts the other process: the
        exit code of that process becomes the exit code of this one.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    if ([Environment]::Is64BitProcess) {
        return $false
    }

    $candidates = @(
        (Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe')
    )
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }

        $all = @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            (Quote-ProcessArgument $ScriptPath)
        ) + @($Arguments | ForEach-Object { Quote-ProcessArgument $_ })

        Write-Host "This process is a 32 bit one, so it is started again as a 64 bit one."
        try {
            $process = Start-Process -FilePath $candidate -ArgumentList $all -Wait -PassThru -NoNewWindow
        } catch {
            throw "The 64 bit PowerShell could not be started: $($_.Exception.Message)"
        }
        exit $process.ExitCode
    }

    throw ("The 64 bit PowerShell was not found, so the installation cannot continue." +
        " bcdedit.exe is a 64 bit program, and a 32 bit process cannot run it." +
        " Looked in: $($candidates -join ', ')")
}

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

function Get-Sha256 {
    <#
    .SYNOPSIS
        The SHA-256 of a file, in lower case hex.

    .DESCRIPTION
        This is written with the .NET cryptography classes on purpose. The
        Get-FileHash cmdlet is not in every Windows PowerShell that the
        installer can run on, and the installer cannot verify anything
        without it.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $algorithm.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
    } finally {
        $algorithm.Dispose()
    }
    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
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

    $actual = Get-Sha256 -Path $TargetPath
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
