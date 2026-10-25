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

function Invoke-Bcd {
    <#
    .SYNOPSIS
        Runs bcdedit and returns its output.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & bcdedit @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit $($Arguments -join ' ') failed:`n$($output -join "`r`n")"
    }
    return ($output -join "`r`n")
}

function Get-BcdEntryId {
    <#
    .SYNOPSIS
        Finds the identifier of an existing boot entry by its description.
    #>
    param([Parameter(Mandatory)][string]$Description)

    $all = Invoke-Bcd @('/enum', 'all')
    $blocks = $all -split '(?m)^\s*$'
    foreach ($block in $blocks) {
        if ($block -match '(?m)^\s*description\s+(.+?)\s*$' -and
            $Matches[1].Trim() -eq $Description) {
            if ($block -match '(?m)^\s*identifier\s+(\{[0-9a-fA-F-]{36}\})\s*$') {
                return $Matches[1]
            }
        }
    }
    return $null
}

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
    $applicationHash = (Get-FileHash -LiteralPath $application -Algorithm SHA256).Hash.ToLowerInvariant()
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
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected[$name]) {
            throw "A firmware asset does not match its pinned SHA-256: $name`n  expected $($expected[$name])`n  actual   $actual"
        }
    }
    Write-Ok 'All five firmware assets match their pinned SHA-256'

    Write-Step 'Staging the files on the EFI system partition'

    $stagingRoot = Join-Path $espPath 'EFI\WindowsGPUUnlock'
    $stagingAssets = Join-Path $stagingRoot 'ASSETS'

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
    $stagedHash = (Get-FileHash -LiteralPath (Join-Path $stagingRoot $script:EfiApplicationName) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($stagedHash -ne $applicationHash) {
        throw 'The staged EFI application does not match the one that was verified'
    }
    foreach ($name in $expected.Keys) {
        $actual = (Get-FileHash -LiteralPath (Join-Path $stagingAssets $name) -Algorithm SHA256).Hash.ToLowerInvariant()
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
    & bcdedit /export (Join-Path $backupRoot 'BCD-export') | Out-Null
    Write-Ok ("Boot configuration exported to {0}" -f $backupRoot)

    $existing = Get-BcdEntryId -Description $Description
    if ($existing) {
        throw "A boot entry named '$Description' already exists. Remove it first, or choose another name."
    }

    $before = Invoke-Bcd @('/enum', '{fwbootmgr}')
    $beforeOrder = [regex]::Matches($before, '(?m)^\s*description\s+(.+?)\s*$') | ForEach-Object { $_.Groups[1].Trim() }

    $manager = Invoke-Bcd @('/enum', '{bootmgr}')
    [void](Invoke-Bcd @('/copy', '{bootmgr}', '/d', $Description))
    $newId = Get-BcdEntryId -Description $Description
    if (-not $newId) {
        throw 'The new boot entry could not be found after it was created'
    }

    # Point the entry at the staged application on the EFI partition.
    [void](Invoke-Bcd @('/set', $newId, 'device', "partition=$espLetter:"))
    [void](Invoke-Bcd @('/set', $newId, 'path', ($script:EfiRelativeDirectory + '\' + $script:EfiApplicationName)))

    # Put the entry first in the firmware boot order, so the unlock runs
    # before the NVIDIA driver binds the card.
    $managerText = Invoke-Bcd @('/enum', '{bootmgr}')
    $managerId = $null
    if ($managerText -match '(?m)^\s*identifier\s+(\{[0-9a-fA-F-]{36}\})\s*$') {
        $managerId = $Matches[1]
    }
    [void](Invoke-Bcd @('/set', '{fwbootmgr}', 'bootsequence', $newId))

    # Read the result back.
    $after = Invoke-Bcd @('/enum', '{fwbootmgr}')
    $afterText = Invoke-Bcd @('/enum', $newId)
    if ($afterText -notmatch ('(?mi)^path\s+' + [regex]::Escape(($script:EfiRelativeDirectory + '\' + $script:EfiApplicationName)) + '\s*$')) {
        throw 'The boot entry does not point at the staged application'
    }

    Write-Ok "Boot entry '$Description' registered as $newId"
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
        InstalledUtc      = [DateTime]::UtcNow.ToString('o')
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8

    Write-Step 'Installation finished'
    Write-Host ''
    Write-Host '    Reboot and let the machine boot normally. The unlock application runs' -ForegroundColor Green
    Write-Host '    before Windows, unlocks the card and then starts Windows.' -ForegroundColor Green
    Write-Host ''
    Write-Host '    The report of every run is written to:' -ForegroundColor Green
    Write-Host "      {0}\EFI\WindowsGPUUnlock\RUNnn\REPORT.TXT" -f $espPath -ForegroundColor Green
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
    Write-Ok ("Installation record found: entry {0} on {1}" -f $state.EntryId, $state.espPath)

    Write-Step 'Removing the boot entry'

    $existing = Get-BcdEntryId -Description $Description
    if ($existing) {
        [void](Invoke-Bcd @('/delete', $existing))
        Write-Ok "Boot entry '$Description' removed"
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
    Write-Host "      {0}" -f $state.BackupRoot -ForegroundColor Green
}

# Load the modules that sit next to this file.
. (Join-Path $PSScriptRoot 'Installer-Common.ps1')
. (Join-Path $PSScriptRoot 'Detect-Hardware.ps1')
. (Join-Path $PSScriptRoot 'Test-Preconditions.ps1')
. (Join-Path $PSScriptRoot 'Get-FirmwareAssets.ps1')

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
