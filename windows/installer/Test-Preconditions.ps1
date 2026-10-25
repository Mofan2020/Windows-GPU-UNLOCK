# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
<#
.SYNOPSIS
    Checks the Windows-side preconditions this tool needs.

.DESCRIPTION
    Every check is read-only. The installer uses the results to decide what
    to tell the user and whether it may continue. A failed check never
    modifies the machine.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Installer-Common.ps1')

<#
.SYNOPSIS
    Reports whether Secure Boot is enabled.

.DESCRIPTION
    The EFI application and its firmware assets are not signed. A firmware
    that enforces Secure Boot will refuse to load them, so the unlock cannot
    run. This reads the SecureBoot UEFI variable through the registry, which
    is what Windows itself reports, and falls back to the Win32_ComputerSystem
    property when the registry key is missing.
#>
function Get-SecureBootState {
    [CmdletBinding()]
    param()

    try {
        $value = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name 'UEFISecureBootEnabled' -ErrorAction Stop
        $enabled = [bool]$value.UEFISecureBootEnabled
        return [pscustomobject]@{
            Enabled     = $enabled
            Method      = 'Registry'
            Description = if ($enabled) { 'Secure Boot is ON' } else { 'Secure Boot is OFF' }
        }
    } catch {
        # The key is absent on some firmware. Fall back to the WMI property.
        try {
            $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            $enabled = [bool]$system.SecureBootState
            return [pscustomobject]@{
                Enabled     = $enabled
                Method      = 'WMI'
                Description = if ($enabled) { 'Secure Boot is ON' } else { 'Secure Boot is OFF' }
            }
        } catch {
            return [pscustomobject]@{
                Enabled     = $null
                Method      = 'Unavailable'
                Description = 'Could not determine the Secure Boot state'
            }
        }
    }
}

<#
.SYNOPSIS
    Reports the BitLocker protection state of the system volume.

.DESCRIPTION
    The EFI transaction resets the display adapter. On a machine where the
    operating system volume is encrypted, that reset can trigger recovery.
    The installer refuses to proceed while the volume is protected and asks
    the user to suspend protection first.
#>
function Get-BitLockerState {
    [CmdletBinding()]
    param()

    try {
        $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $protection = [string]$volume.ProtectionStatus
        return [pscustomobject]@{
            Available  = $true
            Volume     = $env:SystemDrive
            Protection = $protection
            Protected  = ($protection -eq 'On')
            Description = switch ($protection) {
                'On'  { 'BitLocker protection is ON for ' + $env:SystemDrive }
                'Off' { 'BitLocker protection is OFF for ' + $env:SystemDrive }
                default { "BitLocker protection is $protection for " + $env:SystemDrive }
            }
        }
    } catch {
        # The cmdlet is absent without the management feature. The state can
        # still be read from the WMI class.
        try {
            $volume = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop |
                Where-Object { $_.DriveLetter -eq $env:SystemDrive.TrimEnd(':') }
            if ($null -eq $volume) {
                return [pscustomobject]@{
                    Available  = $false
                    Volume     = $env:SystemDrive
                    Protection = 'Unknown'
                    Protected  = $false
                    Description = 'BitLocker state is unavailable for ' + $env:SystemDrive
                }
            }
            $protected = ($volume.ProtectionStatus -ne 0)
            return [pscustomobject]@{
                Available  = $true
                Volume     = $env:SystemDrive
                Protection = if ($protected) { 'On' } else { 'Off' }
                Protected  = $protected
                Description = if ($protected) {
                    'BitLocker protection is ON for ' + $env:SystemDrive
                } else {
                    'BitLocker protection is OFF for ' + $env:SystemDrive
                }
            }
        } catch {
            return [pscustomobject]@{
                Available  = $false
                Volume     = $env:SystemDrive
                Protection = 'Unknown'
                Protected  = $false
                Description = 'BitLocker state could not be determined'
            }
        }
    }
}

<#
.SYNOPSIS
    Finds the EFI system partition that Windows uses.

.DESCRIPTION
    The unlock application and its firmware assets are staged on the EFI
    system partition, because that is the only FAT32 volume the firmware can
    read during boot. Returns the partition object, or $null.

    The partition is confirmed by the Windows Boot Manager sitting on it, so
    that a second EFI partition cannot be picked up by accident. This check is
    read only: it never changes the machine.
#>
function Get-EfiSystemPartition {
    [CmdletBinding()]
    param()

    try {
        $partitions = @(Get-Partition -ErrorAction Stop)
    } catch {
        return $null
    }

    # The Windows EFI partition is the one flagged as the system partition and
    # carrying the ESP type GUID.
    foreach ($partition in $partitions) {
        if (-not $partition.IsSystem) { continue }
        if ($partition.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') { continue }

        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume) { continue }
        if ($volume.FileSystem -ne 'FAT32') { continue }

        # The path of the volume is the root of the partition, whether it is
        # reached through a drive letter or through a mount folder.
        $root = [string]$volume.Path
        if ([string]::IsNullOrEmpty($root)) { continue }

        # The Windows Boot Manager has to be on this partition. That is the
        # proof that it is the partition the firmware boots from.
        if (-not (Test-Path -LiteralPath (Join-Path $root 'EFI\Microsoft\Boot\bootmgfw.efi'))) { continue }

        return [pscustomobject]@{
            Partition       = $partition
            Volume          = $volume
            Path            = $root
            DriveLetter     = [string]$volume.DriveLetter
            Guid            = [string]$partition.Guid
            SizeBytes       = [uint64]$partition.Size
            DiskNumber      = $partition.DiskNumber
            PartitionNumber = $partition.PartitionNumber
        }
    }
    return $null
}

<#
.SYNOPSIS
    Gives the EFI system partition a drive letter.

.DESCRIPTION
    The boot configuration can only name a partition by drive letter, and the
    EFI partition is hidden by default. When it has no letter, one is assigned
    and the caller is told, because the letter is removed again on uninstall.
#>
function Enable-EspDriveLetter {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Esp)

    if (-not [string]::IsNullOrEmpty($Esp.DriveLetter)) {
        return $Esp.DriveLetter
    }

    $letter = New-FreeDriveLetter
    if ([string]::IsNullOrEmpty($letter)) {
        throw 'No free drive letter was found for the EFI system partition.'
    }
    Set-Partition -DiskNumber $Esp.DiskNumber -PartitionNumber $Esp.PartitionNumber `
        -NewDriveLetter $letter -ErrorAction Stop
    Write-Ok ("The EFI system partition was given the drive letter {0}:" -f $letter)
    return $letter
}

<#
.SYNOPSIS
    Finds a drive letter that is not in use.
#>
function New-FreeDriveLetter {
    foreach ($candidate in @('S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'P', 'Q', 'R')) {
        if (-not (Test-Path -LiteralPath ($candidate + ':\'))) {
            return $candidate
        }
    }
    return $null
}

<#
.SYNOPSIS
    Removes a drive letter that was added to the EFI system partition.
#>
function Remove-EspDriveLetter {
    param(
        [Parameter(Mandatory)]$Esp,
        [Parameter(Mandatory)][string]$Letter
    )

    try {
        Remove-PartitionAccessPath -DiskNumber $Esp.DiskNumber -PartitionNumber $Esp.PartitionNumber `
            -AccessPath ($Letter + ':\') -ErrorAction Stop
    } catch {
        Write-Verbose "The drive letter $Letter could not be removed: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Reports whether the machine is in a state the installer can work with.

.DESCRIPTION
    Returns an object with:
      CanInstall   $true when every blocking condition is clear
      Blocking     the list of blocking reasons
      Warnings     the list of advisory notes
      SecureBoot   the Secure Boot state
      BitLocker    the BitLocker state
      Esp          the EFI system partition, or $null
      FastStartup  $true when hibernation is enabled
#>
function Test-InstallPreconditions {
    [CmdletBinding()]
    param()

    $blocking = @()
    $warnings = @()

    $secureBoot = Get-SecureBootState
    if ($secureBoot.Enabled -eq $true) {
        $blocking += 'Secure Boot is enabled. This tool installs an unsigned EFI application, so the firmware will refuse to load it. Turn Secure Boot off in the BIOS and reboot before installing.'
    } elseif ($null -eq $secureBoot.Enabled) {
        $warnings += 'The Secure Boot state could not be determined. If Secure Boot is on, the installed application will not run.'
    }

    $bitLocker = Get-BitLockerState
    if ($bitLocker.Protected) {
        $blocking += 'BitLocker is protecting the Windows volume. The transaction resets the graphics card, which can send a locked machine into recovery. Suspend BitLocker protection before installing.'
    }

    $esp = Get-EfiSystemPartition
    if ($null -eq $esp) {
        $blocking += 'No FAT32 EFI system partition was found. The unlock application must be staged on one, because the firmware can only read FAT32 volumes during boot.'
    } elseif ($esp.SizeBytes -lt 120MB) {
        $warnings += ("The EFI system partition is only {0:N0} MB. The firmware assets need about 85 MB of free space." -f ($esp.SizeBytes / 1MB))
    }

    # Hibernation keeps a memory image of the running system. The unlock
    # changes the card's power state, and a hibernated session would restore
    # the old state on resume.
    $fastStartup = $false
    try {
        $hiberboot = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -ErrorAction Stop
        $fastStartup = ([int]$hiberboot.HiberbootEnabled -ne 0)
    } catch {
        $fastStartup = $false
    }
    if ($fastStartup) {
        $warnings += 'Windows Fast Startup is enabled. Turn it off (powercfg /h off) so a full shutdown really powers the card down; the unlock only works from a cold boot.'
    }

    return [pscustomobject]@{
        CanInstall  = ($blocking.Count -eq 0)
        Blocking    = $blocking
        Warnings    = $warnings
        SecureBoot  = $secureBoot
        BitLocker   = $bitLocker
        Esp         = $esp
        FastStartup = $fastStartup
    }
}
