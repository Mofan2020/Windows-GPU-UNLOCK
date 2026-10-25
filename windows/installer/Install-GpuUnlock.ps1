# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
<#
.SYNOPSIS
    Installs or removes the GPU unlock EFI application.

.DESCRIPTION
    The application is staged in the EFI system partition, in
    \EFI\WindowsGPUUnlock, together with the firmware assets. A boot entry is
    registered so that the application runs before Windows starts, unlocks the
    card and then hands over to the Windows Boot Manager.

    Every change is recorded, and the uninstall reverses exactly what the
    install did. The Windows Boot Manager's own configuration is exported
    before it is touched.

.PARAMETER Action
    Install or Uninstall.

.PARAMETER PayloadDirectory
    The directory holding the built EFI application. Required for Install.

.PARAMETER AssetDirectory
    The directory holding the five generated firmware assets. Required for
    Install.

.PARAMETER BootEntryName
    The name of the boot entry to create. The default is
    "Windows GPU UNLOCK".
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Uninstall')]
    [string]$Action,

    [string]$PayloadDirectory,
    [string]$AssetDirectory,
    [string]$BootEntryName = 'Windows GPU UNLOCK'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StateDirectory = Join-Path $env:ProgramData 'WindowsGPUUnlock'
$script:StateFile = Join-Path $script:StateDirectory 'install-state.json'
$script:EfiRelativeDirectory = '\EFI\WindowsGPUUnlock'
$script:EfiApplicationName = 'UNLOCK.EFI'

function Install-GpuUnlock {
    param(
        [Parameter(Mandatory)][string]$Payload,
        [Parameter(Mandatory)][string]$Assets,
        [Parameter(Mandatory)][string]$Description
    )

    Write-Step 'Checking the machine'

    $preconditions = Test-InstallPreconditions
    foreach ($warning in $preconditions.Warnings) {
        Write-Note $warning
    }
    if (-not $preconditions.CanInstall) {
        foreach ($blocking in $preconditions.Blocking) {
            Write-Host "    BLOCKED: $blocking" -ForegroundColor Red
        }
        throw 'The machine does not meet the requirements. Nothing was changed.'
    }

    $esp = $preconditions.Esp
    Write-Ok ("EFI system partition: {0} ({1:N0} MB)" -f $esp.Path, ($esp.SizeBytes / 1MB))

    # The boot configuration names a partition by drive letter, so the
    # partition needs one.
    $espLetter = Enable-EspDriveLetter -Esp $esp
    $espPath = $espLetter + ':\'
    $letterAdded = [string]::IsNullOrEmpty([string]$esp.DriveLetter)

    $stagingRoot = Join-Path $espPath 'EFI\WindowsGPUUnlock'
    $stagingAssets = Join-Path $stagingRoot 'ASSETS'

    # A run that stopped before it wrote its record leaves the files on the
    # partition and the drive letter with it, but no record. When the files
    # are there and there is no record, the letter belongs to that run, and
    # it has to be taken back as well.
    if (-not $letterAdded -and
        -not (Test-Path -LiteralPath $script:StateFile) -and
        (Test-Path -LiteralPath $stagingRoot)) {
        $letterAdded = $true
        Write-Note 'The files of an earlier run are on the partition, so the drive letter it gave is taken back when the installation is removed.'
    }

    # The record of what was changed is written before anything is changed,
    # so that a failure later on still leaves a record that the uninstaller
    # can use. The drive letter is the first thing that is given to the
    # machine, and it is the one that has to be taken back.
    New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    $partialState = [ordered]@{
        Version            = 1
        Action             = 'staging'
        EntryId            = ''
        EntryDescription   = $Description
        EspPath            = $espPath
        EspGuid            = $esp.Guid
        EspDriveLetter     = $espLetter
        EspLetterAdded     = $letterAdded
        EspDiskNumber      = $esp.DiskNumber
        EspPartitionNumber = $esp.PartitionNumber
        StagingRoot        = (Join-Path $espPath 'EFI\WindowsGPUUnlock')
        BackupRoot         = ''
        BootOrderBefore    = @()
        InstalledUtc       = [DateTime]::UtcNow.ToString('o')
    }
    $partialState | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8

    $target = Test-UnlockTarget
    if (-not $target.Supported) {
        throw $target.Reason
    }
    Write-Ok ("Card: {0} (PCI {1:X4}:{2:X4})" -f $target.Target.Adapter, $target.Target.VendorId, $target.Target.DeviceId)

    Write-Step 'Verifying the payload and the firmware assets'

    $application = Join-Path $Payload 'UNLOCK.EFI'
    if (-not (Test-Path -LiteralPath $application)) {
        throw "The EFI application was not found: $application"
    }
    $applicationHash = Get-Sha256 -Path $application
    Write-Ok ("UNLOCK.EFI  {0} bytes  sha256 {1}" -f (Get-Item -LiteralPath $application).Length, $applicationHash)

    $expected = @{
        'booter_load_ga102.bin'   = '056cbc064a888f80717726c54d7f64fcd68044d123870c95a74f37f4975dcaa4'
        'v67-ga102-610.43.03.bin' = '2a0aa1f86d0b6afff5214d641d87d46dc98ef06ed908ff05d0ddbad5ffb7e197'
        'gsp_ga10x.bin'           = '572373620a37418f24dc16b5031c39338778c3257e48e8408de9a57291b24f3a'
        'gsp_boot_ga102.bin'      = '3df651acb174fd5f5561a1996965b192f50c5d763168446ed0d4ead19d895768'
        'gsp_boot_desc_ga102.bin' = 'cc5a3fc1f4c47f2fe107b1b68f0176d8a448e6dec84b575e5560ccef5262bf15'
    }
    foreach ($name in $expected.Keys) {
        $path = Join-Path $Assets $name
        if (-not (Test-Path -LiteralPath $path)) {
            throw "A firmware asset is missing: $name"
        }
        $actual = Get-Sha256 -Path $path
        if ($actual -ne $expected[$name]) {
            throw "A firmware asset does not match its pinned SHA-256: $name`n  expected $($expected[$name])`n  actual   $actual"
        }
    }
    Write-Ok 'All five firmware assets match their pinned SHA-256'

    Write-Step 'Staging the files on the EFI system partition'

    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stagingAssets -Force | Out-Null

    Copy-Item -LiteralPath $application -Destination (Join-Path $stagingRoot $script:EfiApplicationName) -Force
    foreach ($name in $expected.Keys) {
        Copy-Item -LiteralPath (Join-Path $Assets $name) -Destination (Join-Path $stagingAssets $name) -Force
    }
    Write-Ok ("Staged in {0}" -f $stagingRoot)

    # Verify what landed on the partition, not what we intended to write.
    $stagedHash = Get-Sha256 -Path (Join-Path $stagingRoot $script:EfiApplicationName)
    if ($stagedHash -ne $applicationHash) {
        throw 'The staged EFI application does not match the one that was verified'
    }
    foreach ($name in $expected.Keys) {
        $actual = Get-Sha256 -Path (Join-Path $stagingAssets $name)
        if ($actual -ne $expected[$name]) {
            throw "The staged asset does not match its pinned SHA-256: $name"
        }
    }
    Write-Ok 'The staged files were read back and verified'

    Write-Step 'Registering the boot entry'

    New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null

    # Export the current boot configuration so it can be restored by hand if
    # anything goes wrong later.
    $backupRoot = Join-Path $script:StateDirectory ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    & (Get-BcdEditPath) /export (Join-Path $backupRoot 'BCD-export') | Out-Null
    Write-Ok ("Boot configuration exported to {0}" -f $backupRoot)

    $expectedPath = $script:EfiRelativeDirectory + '\' + $script:EfiApplicationName

    # An entry of an earlier run is taken out of the way first. It is only
    # touched when it points at the staged application, so that an entry that
    # belongs to the user is never removed.
    $existing = Get-BcdEntryId -Text (Invoke-Bcd @('/enum', 'all')) -Description $Description
    if ($existing) {
        $existingText = Invoke-Bcd @('/enum', $existing, '/v')
        if (-not (Test-BcdPropertyValue -Text $existingText -Value $expectedPath)) {
            throw "An entry named '$Description' already exists and is not the one of this tool. Remove it first, or choose another name."
        }
        Write-Note "The entry of an earlier run ($existing) is replaced."
        [void](Invoke-Bcd @('/delete', $existing))
    }

    # The entry itself. The boot manager is copied, so that the entry
    # inherits the partition that the boot manager boots from, and it is put
    # first in the firmware boot order, so that the unlock runs before the
    # driver of the card binds it.
    $entry = Register-BcdBootEntry -Description $Description -Path $expectedPath
    $newId = $entry.Identifier
    Write-Ok "Boot entry '$Description' registered as $newId"
    Write-Ok ("It boots from {0}" -f $entry.Device)
    Write-Ok 'It is first in the firmware boot order, so it runs before Windows starts'

    $state = [ordered]@{
        Version           = 1
        Action            = 'installed'
        EntryId           = $newId
        EntryDescription  = $Description
        ApplicationSha256 = $applicationHash
        EspPath           = $espPath
        EspGuid           = $esp.Guid
        EspDriveLetter    = $espLetter
        EspLetterAdded    = $letterAdded
        EspDiskNumber     = $esp.DiskNumber
        EspPartitionNumber = $esp.PartitionNumber
        StagingRoot       = $stagingRoot
        BackupRoot        = $backupRoot
        BootOrderBefore   = @($entry.OrderBefore)
        InstalledUtc      = [DateTime]::UtcNow.ToString('o')
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8

    Write-Step 'Installation finished'
    Write-Host ''
    Write-Host '    Reboot and let the machine boot normally. The unlock application runs' -ForegroundColor Green
    Write-Host '    before Windows, unlocks the card and then starts Windows.' -ForegroundColor Green
    Write-Host ''
    Write-Host '    The report of every run is written to:' -ForegroundColor Green
    Write-Host ("      {0}\EFI\WindowsGPUUnlock\RUNnn\REPORT.TXT" -f $espPath) -ForegroundColor Green
    Write-Host ''
    Write-Host '    To remove it, run this installer again and choose Uninstall.' -ForegroundColor Green
}

function Uninstall-GpuUnlock {
    param([Parameter(Mandatory)][string]$Description)

    Write-Step 'Checking the installed state'

    if (-not (Test-Path -LiteralPath $script:StateFile)) {
        Write-Note 'No installation record was found. Nothing to do.'
        return
    }
    $state = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
    if ($state.EntryId) {
        Write-Ok ("Installation record found: entry {0} on {1}" -f $state.EntryId, $state.espPath)
    } else {
        # The record is written before the machine is changed, so a run that
        # stopped halfway leaves one behind without a boot entry in it.
        Write-Ok ("Installation record found: the run stopped before the boot entry was made, on {0}" -f $state.espPath)
    }

    Write-Step 'Removing the boot entry'

    # The identifier of the entry comes from the record of the installation.
    # The name is only looked up when there is no record, because the name is
    # what a person sees and the identifier is what bcdedit works with.
    $existing = ''
    if ($state.EntryId) {
        $existing = [string]$state.EntryId
    }
    if (-not $existing) {
        $existing = Get-BcdEntryId -Text (Invoke-Bcd @('/enum', 'all')) -Description $Description
    }
    if ($existing) {
        # The order is put back the way it was before the installation, and
        # the entry itself is taken away as well, and not only put out of the
        # order.
        $orderBefore = @()
        if ($state.bootOrderBefore) {
            $orderBefore = @($state.bootOrderBefore)
        }
        $after = @(Unregister-BcdBootEntry -Identifier $existing -OrderBefore $orderBefore)
        Write-Ok "Boot entry '$Description' removed"

        if ($after -contains $existing) {
            throw 'The boot entry is still in the firmware boot order'
        }
    } else {
        Write-Note "The boot entry '$Description' was already gone"
    }

    Write-Step 'Removing the staged files'

    $stagingRoot = $state.stagingRoot
    if ($stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        Write-Ok 'The staged files were removed'
    } else {
        Write-Note 'The staged files were already gone'
    }

    # Give the EFI partition back the hidden state it had before, when this
    # installation is the one that gave it a drive letter.
    if ($state.espLetterAdded -and $state.espDriveLetter) {
        Remove-EspDriveLetter -Esp ([pscustomobject]@{
                DiskNumber      = $state.espDiskNumber
                PartitionNumber = $state.espPartitionNumber
            }) -Letter ([string]$state.espDriveLetter)
        Write-Ok ("The drive letter {0}: was removed from the EFI system partition" -f $state.espDriveLetter)
    }

    Remove-Item -LiteralPath $script:StateFile -Force -ErrorAction SilentlyContinue
    Write-Ok 'The installation record was removed'

    Write-Step 'Uninstallation finished'
    Write-Host ''
    Write-Host '    The boot configuration backup is kept in:' -ForegroundColor Green
    Write-Host ("      {0}" -f $state.BackupRoot) -ForegroundColor Green
}

# Load the modules that sit next to this file.
. (Join-Path $PSScriptRoot 'Installer-Common.ps1')
. (Join-Path $PSScriptRoot 'Detect-Hardware.ps1')
. (Join-Path $PSScriptRoot 'Test-Preconditions.ps1')
. (Join-Path $PSScriptRoot 'Get-FirmwareAssets.ps1')

# bcdedit.exe is a 64 bit program, so this script needs a 64 bit process. The
# uninstaller of the packaged installer is a 32 bit program and may start the
# 32 bit PowerShell, in which case this is where the work moves to the 64 bit
# one.
$forwarded = @('-Action', $Action)
if ($PayloadDirectory) { $forwarded += @('-PayloadDirectory', $PayloadDirectory) }
if ($AssetDirectory) { $forwarded += @('-AssetDirectory', $AssetDirectory) }
if ($BootEntryName) { $forwarded += @('-BootEntryName', $BootEntryName) }
Restart-As64Bit -ScriptPath $PSCommandPath -Arguments $forwarded

Write-Host ''
Write-Host 'Windows GPU UNLOCK installer' -ForegroundColor White
Write-Host 'Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.' -ForegroundColor DarkGray

switch ($Action) {
    'Install' {
        if (-not $PayloadDirectory) { throw '-PayloadDirectory is required to install.' }
        if (-not $AssetDirectory) { throw '-AssetDirectory is required to install.' }
        Install-GpuUnlock -Payload $PayloadDirectory -Assets $AssetDirectory -Description $BootEntryName
    }
    'Uninstall' {
        Uninstall-GpuUnlock -Description $BootEntryName
    }
}
