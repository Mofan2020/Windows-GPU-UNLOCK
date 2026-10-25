# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
<#
.SYNOPSIS
    The Windows GPU UNLOCK installer. Double-click the packaged executable to
    run this.

.DESCRIPTION
    This is the entry point the packaged installer calls. It shows what the
    tool will do, checks the machine, and then installs or removes the
    application.

    The order of the screens matters. The notes come first, before anything
    is checked, so the user knows what they are agreeing to before the
    installer looks at the machine.

    Everything that is printed is also written into a log file, because the
    window that shows it can be hidden behind another one, and because a
    message that is gone with the window is of no use to anybody. The last
    line of the log is a marker that says how the installation ended, so the
    caller can tell a refusal from a failure.

.PARAMETER Yes
    Do not wait for a key press. The packaged installer sets this, because
    its own window is the one the user is looking at.

.PARAMETER Silent
    Print nothing but the result marker. Used by the automatic test.

.PARAMETER LogPath
    Where the log file goes. Defaults to a file in the temporary directory.

.PARAMETER CheckOnly
    Only report what the machine looks like, and change nothing. Used by the
    automatic test, so that a test run cannot touch the boot configuration
    of the machine it runs on.
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Yes,
    [switch]$Silent,
    [switch]$CheckOnly,
    [string]$PayloadDirectory,
    [string]$AssetDirectory,
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $LogPath) {
    $LogPath = Join-Path $env:TEMP 'WindowsGPUUnlock-install.log'
}

# The log is written first, so that a failure while loading the other
# scripts is in there as well. The file is appended to, because the
# packaged installer writes the first line itself, before it starts this
# script.
$transcript = $null
try {
    $logDirectory = Split-Path -Parent $LogPath
    if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $LogPath) {
        Start-Transcript -Path $LogPath -Append | Out-Null
    } else {
        Start-Transcript -Path $LogPath -Force | Out-Null
    }
    $transcript = $true
} catch {
    Write-Host "The log file could not be opened: $($_.Exception.Message)"
}

function Test-Administrator {
    <#
    .SYNOPSIS
        Whether the script runs with the administrator token.
    #>
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Write-Heading {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor White
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkGray
}

function Write-Result {
    <#
    .SYNOPSIS
        Writes the marker that says how the installation ended.
    #>
    param([string]$Outcome, [string]$Detail)

    if ($Detail) {
        Write-Host "WGPU-RESULT: $Outcome - $Detail"
    } else {
        Write-Host "WGPU-RESULT: $Outcome"
    }
}

function Show-Notes {
    Write-Heading 'BEFORE YOU CONTINUE - please read this'

    Write-Host @'
This tool unlocks the FP16 and BF16 tensor instruction rate on NVIDIA
GeForce RTX 30-series cards (GA102, GA103, GA104 and GA106 - the RTX 3090,
3080, 3070 and 3060 families). Consumer cards run these instructions at
about half the rate of the professional cards; the unlock removes that
limit. It changes no clocks and no power limits, and it does not flash the
card's VBIOS.

WHAT THIS DOES TO YOUR MACHINE
  * It installs an unsigned EFI application on the EFI system partition and
    registers a boot entry that runs before Windows starts.
  * On every boot that entry runs, unlocks the card, and then starts
    Windows. The card's GPU is reset once during that boot.
  * The application writes to the card's firmware and to its registers. A
    card that is already in use by a driver is refused, so the unlock only
    happens from a cold boot.
  * The EFI system partition is hidden by default. The boot configuration can
    only name a partition by drive letter, so the installer gives it one
    (S:, T:, ...) and takes it away again when you uninstall. Nothing else
    about the partition layout is changed, and no new partition is created.

WHAT YOU NEED TO DO FIRST
  1. Turn Secure Boot OFF in your BIOS. The application is not signed, so a
     firmware that enforces Secure Boot will refuse to load it. This is not
     optional and the installer will refuse to continue while it is on.
  2. Turn off Windows Fast Startup, so a shutdown really powers the card
     down. Run this in an administrator terminal:
        powercfg /h off
     A hibernated session keeps the old card state and the unlock will be
     skipped.
  3. If BitLocker protects your Windows volume, suspend that protection
     before installing. The installer refuses to continue while it is on:
        manage-bde -protectors -disable C:
     Turn it back on afterwards with:
        manage-bde -protectors -enable C:

WHAT TO EXPECT AT BOOT
  * The screen may go black for a few seconds while the card resets. This is
    normal.
  * The unlock application asks you to press U to proceed. Press Esc to
    cancel and boot Windows unchanged.
  * If the card drives the display, the firmware console has nowhere to
    draw, so the tool refuses to run. Use a machine with an integrated GPU
    and keep the display plugged into it.

RISKS, HONESTLY
  * This is experimental. It modifies low-level firmware state. The upstream
    project has hardware reports for a small number of cards, not for all of
    them.
  * If the card or the firmware misbehaves, the usual outcome is a failed
    boot that you recover with the BIOS boot menu. Keep a bootable USB
    handy.
  * BitLocker, if enabled, will ask for its recovery key on a boot where the
    card state changed. This is why the installer asks you to suspend it.
  * Do not use it on a machine you depend on for work, unless you have
    verified the recovery path first.

WHAT IS NOT INCLUDED
  * The NVIDIA firmware files are not shipped with this installer. NVIDIA's
    licence does not allow it. The installer downloads the pinned upstream
    inputs from NVIDIA and generates the assets on your machine, and checks
    every file against its SHA-256.
'@ -ForegroundColor Gray

    Write-Host ''
    Write-Host 'Press Enter to continue, or Ctrl+C to stop.' -ForegroundColor White
    if (-not $Yes) {
        [void](Read-Host)
    }
}

function Show-HardwareReport {
    Write-Heading 'Your display hardware'

    Write-Host '  ... looking for the display adapters'
    $adapters = @(Get-DisplayAdapter)
    if ($adapters.Count -eq 0) {
        Write-Host '  No display adapter was reported by Windows.' -ForegroundColor Red
        return
    }
    foreach ($adapter in $adapters) {
        $label = if ($adapter.IsSupported) { 'supported' } elseif ($adapter.IsNvidia) { 'NVIDIA, not supported' } else { 'other vendor' }
        $color = if ($adapter.IsSupported) { 'Green' } else { 'Yellow' }
        Write-Host ("  {0}" -f $adapter.Adapter) -ForegroundColor White
        Write-Host ("    PCI {0:X4}:{1:X4}  driver {2}  [{3}]" -f `
            ($(if ($null -ne $adapter.VendorId) { $adapter.VendorId } else { 0 })),
            ($(if ($null -ne $adapter.DeviceId) { $adapter.DeviceId } else { 0 })),
            $adapter.DriverVersion, $label) -ForegroundColor $color
    }

    $target = Test-UnlockTarget
    Write-Host ''
    if ($target.Supported) {
        Write-Host ("  This tool applies to: {0}" -f $target.Target.Adapter) -ForegroundColor Green
    } else {
        Write-Host ("  This tool does not apply: {0}" -f $target.Reason) -ForegroundColor Red
    }
}

function Show-PreconditionReport {
    Write-Heading 'System checks'

    $preconditions = Test-InstallPreconditions

    $secure = $preconditions.SecureBoot
    $color = if ($secure.Enabled -eq $false) { 'Green' } else { 'Red' }
    Write-Host ("  Secure Boot      : {0}" -f $secure.Description) -ForegroundColor $color

    $bitlocker = $preconditions.BitLocker
    $color = if ($bitlocker.Protected) { 'Red' } else { 'Green' }
    Write-Host ("  BitLocker        : {0}" -f $bitlocker.Description) -ForegroundColor $color

    $color = if ($null -ne $preconditions.Esp) { 'Green' } else { 'Red' }
    if ($null -ne $preconditions.Esp) {
        Write-Host ("  EFI partition    : {0} ({1:N0} MB)" -f $preconditions.Esp.Path, ($preconditions.Esp.SizeBytes / 1MB)) -ForegroundColor $color
    } else {
        Write-Host ('  EFI partition    : not found') -ForegroundColor $color
    }

    $color = if ($preconditions.FastStartup) { 'Yellow' } else { 'Green' }
    Write-Host ("  Fast Startup     : {0}" -f $(if ($preconditions.FastStartup) { 'ON - the unlock needs a cold boot' } else { 'OFF' })) -ForegroundColor $color

    if ($preconditions.Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host '  Notes:' -ForegroundColor Yellow
        foreach ($warning in $preconditions.Warnings) {
            Write-Host "    - $warning" -ForegroundColor Yellow
        }
    }

    if ($preconditions.Blocking.Count -gt 0) {
        Write-Host ''
        Write-Host '  Blockers:' -ForegroundColor Red
        foreach ($blocking in $preconditions.Blocking) {
            Write-Host "    - $blocking" -ForegroundColor Red
        }
        Write-Host ''
        Write-Host '  Fix the blockers above and run the installer again.' -ForegroundColor Red
    }
    return $preconditions
}

# ---------------------------------------------------------------------------
# The scripts are loaded here, and not at the top of the file, so that a
# failure while loading one of them is caught and written into the log
# instead of ending the process without a word.

$exitCode = 0
$result = 'failed'
$detail = ''

try {
    . (Join-Path $PSScriptRoot 'Installer-Common.ps1')
    . (Join-Path $PSScriptRoot 'Detect-Hardware.ps1')
    . (Join-Path $PSScriptRoot 'Test-Preconditions.ps1')
    . (Join-Path $PSScriptRoot 'Get-FirmwareAssets.ps1')

    Write-Host ''
    Write-Host 'Windows GPU UNLOCK' -ForegroundColor White
    Write-Host 'Installer for the generic (all GA10x) build.' -ForegroundColor DarkGray
    Write-Host "Log file: $LogPath" -ForegroundColor DarkGray

    if (-not (Test-Administrator)) {
        $result = 'failed'
        $detail = 'the administrator rights are missing. Right-click the file and choose "Run as administrator".'
        $exitCode = 1
        throw $detail
    }

    if (-not $Silent) {
        Show-Notes
    }

    if ($Uninstall) {
        Write-Heading 'Uninstalling'
        & (Join-Path $PSScriptRoot 'Install-GpuUnlock.ps1') -Action Uninstall
        Write-Host ''
        Write-Host 'Done.' -ForegroundColor Green
        $result = 'ok'
        $exitCode = 0
    } else {
        Show-HardwareReport

        $preconditions = Show-PreconditionReport

        $target = Test-UnlockTarget
        if (-not $target.Supported) {
            Write-Host ''
            Write-Host ("  This tool does not apply to this machine: {0}" -f $target.Reason) -ForegroundColor Red
        }

        if ($CheckOnly) {
            # Nothing is downloaded and nothing is changed. The report above
            # is the whole answer.
            if ($target.Supported -and $preconditions.CanInstall) {
                $result = 'ok'
                $detail = 'the machine is ready'
                $exitCode = 0
            } else {
                $result = 'blocked'
                $detail = 'the machine is not ready'
                $exitCode = 1
            }
        } elseif (-not $preconditions.CanInstall) {
            Write-Host ''
            Write-Host 'Nothing was changed.' -ForegroundColor Red
            $result = 'blocked'
            $detail = 'the machine is not ready for the transaction'
            $exitCode = 1
        } else {
            Write-Host ''
            Write-Host 'Press Enter to install, or Ctrl+C to stop.' -ForegroundColor White
            if (-not $Yes) {
                [void](Read-Host)
            }

            # The firmware assets are produced here, on this machine, from
            # pinned upstream inputs. They are never downloaded as a
            # ready-made blob, because NVIDIA's licence does not permit that.
            $workRoot = Join-Path $env:TEMP 'WindowsGPUUnlock-assets'
            $assetRoot = Join-Path $workRoot 'assets'

            Write-Heading 'Preparing the firmware assets'
            Write-Host '  This downloads about 100 MB from NVIDIA and the CachyOS archive and' -ForegroundColor Gray
            Write-Host '  generates the firmware files locally. It can take a few minutes.' -ForegroundColor Gray
            Write-Host ''

            try {
                $assets = @(Get-FirmwareAssets -OutputDirectory $assetRoot -WorkingDirectory $workRoot)
            } catch {
                Write-Host ''
                Write-Host "  The firmware assets could not be prepared: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host '  Nothing was changed on this machine.' -ForegroundColor Red
                $result = 'failed'
                $detail = $_.Exception.Message
                $exitCode = 1
                $assets = @()
            }

            if ($exitCode -eq 0) {
                $payload = $PayloadDirectory
                if (-not $payload) {
                    $payload = Join-Path $PSScriptRoot 'payload'
                }

                & (Join-Path $PSScriptRoot 'Install-GpuUnlock.ps1') `
                    -Action Install `
                    -PayloadDirectory $payload `
                    -AssetDirectory $assetRoot

                Write-Host ''
                Write-Host 'Done. Reboot to try it.' -ForegroundColor Green
                $result = 'ok'
                $exitCode = 0
            }
        }
    }
} catch {
    # Nothing above this point is allowed to end the process without saying
    # what went wrong.
    $detail = $_.Exception.Message
    Write-Host ''
    Write-Host "The installation stopped: $detail" -ForegroundColor Red
    Write-Host "The log file is here: $LogPath" -ForegroundColor Red
    $result = 'failed'
    $exitCode = 1
}

Write-Result $result $detail

if ($transcript) {
    try { Stop-Transcript | Out-Null } catch { }
}

exit $exitCode
