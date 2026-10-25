# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
<#
.SYNOPSIS
    Tests the decision logic of the installer scripts.

.DESCRIPTION
    The installer must refuse to run on hardware it cannot unlock, and it must
    refuse to run on a machine that is not prepared for the transaction. Both
    decisions are pure logic once the hardware and the system state are known,
    so they are tested here with the Windows specific commands replaced by
    stubs.

    The test runs on any platform with PowerShell 7, so it can be part of the
    continuous integration as well as the local check.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'windows/installer/Detect-Hardware.ps1')
. (Join-Path $root 'windows/installer/Test-Preconditions.ps1')

$script:Failures = 0
$script:Checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Checks++
    if (-not $Condition) {
        $script:Failures++
        Write-Host "  FAIL $Message" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    $script:Checks++
    if ($Expected -ne $Actual) {
        $script:Failures++
        Write-Host "  FAIL $Message" -ForegroundColor Red
        Write-Host "       expected: $Expected"
        Write-Host "       actual:   $Actual"
    }
}

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Message)
    $script:Checks++
    if ($null -eq $Haystack -or $Haystack -notlike "*$Needle*") {
        $script:Failures++
        Write-Host "  FAIL $Message" -ForegroundColor Red
        Write-Host "       expected to contain: $Needle"
        Write-Host "       actual:              $Haystack"
    }
}

# Every installer script has to parse. This is checked here as well, because
# a parse error in a script that this test does not call would otherwise only
# show up in the continuous integration.
foreach ($script in (Get-ChildItem (Join-Path $root 'windows/installer') -Filter *.ps1)) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$parseErrors)
    Assert-True ($null -eq $parseErrors -or $parseErrors.Count -eq 0) `
        ("{0} parses: {1}" -f $script.Name, (($parseErrors | ForEach-Object { $_.Message }) -join '; '))
}

# ---------------------------------------------------------------------------
# Stubs for the Windows specific commands.
# ---------------------------------------------------------------------------

# The fake adapters the next test case wants to present.
$script:FakeVideoControllers = @()

function Get-CimInstance {
    param(
        [string]$ClassName,
        [string]$Namespace,
        [int]$OperationTimeoutSec,
        [Parameter(ValueFromPipeline = $true)]$InputObject
    )
    if ($ClassName -eq 'Win32_VideoController') {
        return $script:FakeVideoControllers
    }
    throw "Get-CimInstance was called for an unexpected class: $ClassName"
}

# The fake system state the next test case wants to present.
$script:FakeSecureBoot = $null
$script:FakeBitLocker = $null
$script:FakeEsp = $null
$script:FakeHiberboot = $null

# The EFI system partition is represented by a real directory, so that the
# path checks behave the way they do on Windows.
$script:FakeEspRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('gpu-unlock-esp-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $script:FakeEspRoot 'EFI\Microsoft\Boot') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $script:FakeEspRoot 'EFI\Microsoft\Boot\bootmgfw.efi') -Value 'stub'
$script:FakeEspLetter = 'S'

function Get-ItemProperty {
    param([string]$Path, [string]$Name)
    if ($Path -like '*SecureBoot*') {
        if ($null -eq $script:FakeSecureBoot) { throw 'The key does not exist' }
        return [pscustomobject]@{ UEFISecureBootEnabled = $script:FakeSecureBoot }
    }
    if ($Path -like '*Session Manager\Power*') {
        if ($null -eq $script:FakeHiberboot) { throw 'The key does not exist' }
        return [pscustomobject]@{ HiberbootEnabled = $script:FakeHiberboot }
    }
    throw "Get-ItemProperty was called for an unexpected path: $Path"
}

function Get-BitLockerVolume {
    param([string]$MountPoint)
    if ($null -eq $script:FakeBitLocker) { throw 'The cmdlet is not available' }
    return [pscustomobject]@{ ProtectionStatus = $script:FakeBitLocker }
}

function Get-Partition {
    if ($null -eq $script:FakeEsp) { return @() }
    return @([pscustomobject]@{
        IsSystem       = $true
        GptType        = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        Guid           = '11111111-2222-3333-4444-555555555555'
        Size           = [uint64]268435456
        DiskNumber     = 0
        PartitionNumber = 1
    })
}

function Get-Volume {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    if ($null -eq $script:FakeEsp) { return $null }
    return [pscustomobject]@{
        FileSystem  = 'FAT32'
        DriveLetter = $script:FakeEspLetter
        Path        = $script:FakeEspRoot
        Size        = [uint64]268435456
    }
}

function Set-Partition {
    param([int]$DiskNumber, [int]$PartitionNumber, [string]$NewDriveLetter)
    $script:FakeEspLetter = $NewDriveLetter
}

function Remove-PartitionAccessPath {
    param([int]$DiskNumber, [int]$PartitionNumber, [string]$AccessPath)
    $script:FakeEspLetter = ''
}

# ---------------------------------------------------------------------------
# Hardware detection.
# ---------------------------------------------------------------------------

function New-FakeAdapter {
    param([string]$Name, [string]$Vendor, [string]$Device)
    return [pscustomobject]@{
        Name           = $Name
        PNPDeviceID    = "PCI\VEN_${Vendor}&DEV_${Device}&SUBSYS_12345678"
        DriverVersion  = '31.0.15.3623'
        AdapterRAM     = 8589934592
        Status         = 'OK'
    }
}

Write-Host 'Hardware detection'

$script:FakeVideoControllers = @()
$result = Test-UnlockTarget
Assert-True (-not $result.Supported) 'A machine without any adapter is refused'
Assert-Contains $result.Reason 'No display adapter' 'The reason mentions the missing adapter'

$script:FakeVideoControllers = @(New-FakeAdapter -Name 'AMD Radeon Graphics' -Vendor '1002' -Device '164E')
$result = Test-UnlockTarget
Assert-True (-not $result.Supported) 'A machine without an NVIDIA card is refused'
Assert-Contains $result.Reason 'No NVIDIA display adapter' 'The reason mentions that no NVIDIA card was found'
Assert-Contains $result.Reason 'AMD Radeon Graphics' 'The reason names the adapter that was found'

$script:FakeVideoControllers = @(New-FakeAdapter -Name 'NVIDIA GeForce RTX 4090' -Vendor '10DE' -Device '2684')
$result = Test-UnlockTarget
Assert-True (-not $result.Supported) 'An NVIDIA card outside GA10x is refused'
Assert-Contains $result.Reason 'not a supported GA10x part' 'The reason explains that the part is not supported'

$script:FakeVideoControllers = @(New-FakeAdapter -Name 'NVIDIA GeForce RTX 3060' -Vendor '10DE' -Device '2503')
$result = Test-UnlockTarget
Assert-True $result.Supported 'An RTX 3060 8GB is accepted'
Assert-Equal 'GA106  RTX 3060 8GB' $result.Target.DeviceName 'The target carries the friendly name'
Assert-Equal 0x2503 $result.Target.DeviceId 'The target carries the device ID'

$script:FakeVideoControllers = @(New-FakeAdapter -Name 'NVIDIA GeForce RTX 3060' -Vendor '10DE' -Device '2504')
$result = Test-UnlockTarget
Assert-True $result.Supported 'An RTX 3060 12GB is accepted'
Assert-Equal 'GA106  RTX 3060 12GB' $result.Target.DeviceName 'The target carries the friendly name'

$script:FakeVideoControllers = @(
    New-FakeAdapter -Name 'Intel UHD Graphics' -Vendor '8086' -Device '9A49'
    New-FakeAdapter -Name 'NVIDIA GeForce RTX 3070 Ti' -Vendor '10DE' -Device '2482'
)
$result = Test-UnlockTarget
Assert-True $result.Supported 'An integrated GPU next to a supported card is accepted'
Assert-Equal 2 $result.Adapters.Count 'Both adapters are listed'

$script:FakeVideoControllers = @(
    New-FakeAdapter -Name 'NVIDIA GeForce RTX 3060' -Vendor '10DE' -Device '2503'
    New-FakeAdapter -Name 'NVIDIA GeForce RTX 3080' -Vendor '10DE' -Device '2206'
)
$result = Test-UnlockTarget
Assert-True (-not $result.Supported) 'Two supported cards are refused'
Assert-Contains $result.Reason 'More than one supported NVIDIA card' 'The reason explains the duplicate'

# ---------------------------------------------------------------------------
# System preconditions.
# ---------------------------------------------------------------------------

Write-Host 'System preconditions'

$script:FakeSecureBoot = $true
$script:FakeBitLocker = 'Off'
$script:FakeEsp = $true
$script:FakeHiberboot = 0
$result = Test-InstallPreconditions
Assert-True (-not $result.CanInstall) 'Secure Boot on blocks the installation'
Assert-Contains ($result.Blocking -join ' ') 'Secure Boot is enabled' 'The blocking reason names Secure Boot'

$script:FakeSecureBoot = $false
$script:FakeBitLocker = 'On'
$result = Test-InstallPreconditions
Assert-True (-not $result.CanInstall) 'BitLocker blocks the installation'
Assert-Contains ($result.Blocking -join ' ') 'BitLocker' 'The blocking reason names BitLocker'

$script:FakeBitLocker = 'Off'
$script:FakeEsp = $null
$result = Test-InstallPreconditions
Assert-True (-not $result.CanInstall) 'A missing EFI system partition blocks the installation'
Assert-Contains ($result.Blocking -join ' ') 'EFI system partition' 'The blocking reason names the partition'

$script:FakeEsp = $true
$script:FakeHiberboot = 1
$result = Test-InstallPreconditions
Assert-True $result.CanInstall 'A prepared machine is allowed'
Assert-Contains ($result.Warnings -join ' ') 'Fast Startup' 'Fast Startup is reported as a warning'
Assert-True $result.FastStartup 'The Fast Startup flag is reported'

$script:FakeHiberboot = 0
$result = Test-InstallPreconditions
Assert-True $result.CanInstall 'A prepared machine is still allowed'
Assert-True (-not $result.FastStartup) 'The Fast Startup flag is cleared'

Write-Host 'The firmware boot order'

$dump = @"
Firmware Boot Manager
---------------------
identifier              {fwbootmgr}
bootsequence            {9dea862c-5cdd-4e70-acc1-f32b344d4795}
displayorder            {bootmgr}
                        {9dea862c-5cdd-4e70-acc1-f32b344d4795}
                        {11111111-2222-3333-4444-555555555555}
description             Windows Boot Manager
"@
$order = @(Get-BcdDisplayOrder $dump)
Assert-Equal 3 $order.Count 'The firmware boot order has three entries'
Assert-Equal '{bootmgr}' $order[0] 'The Windows Boot Manager is first'
Assert-Equal '{11111111-2222-3333-4444-555555555555}' $order[2] 'The last entry is read'
Assert-Equal 0 @(Get-BcdDisplayOrder 'nothing here').Count 'A dump without an order gives no entries'

Write-Host 'The EFI system partition'

$script:FakeEsp = $true
$script:FakeEspLetter = 'S'
$esp = Get-EfiSystemPartition
Assert-True ($null -ne $esp) 'The EFI system partition is found'
Assert-Equal 'S' $esp.DriveLetter 'The partition keeps the drive letter it has'
Assert-True (Test-Path -LiteralPath (Join-Path $esp.Path 'EFI\Microsoft\Boot\bootmgfw.efi')) 'The partition is the one with the Windows Boot Manager'

$letter = Enable-EspDriveLetter -Esp $esp
Assert-Equal 'S' $letter 'A partition that has a letter keeps it'
Assert-Equal 'S' $script:FakeEspLetter 'No other letter was assigned'

$script:FakeEspLetter = ''
$esp = Get-EfiSystemPartition
Assert-True ($null -ne $esp) 'A hidden EFI system partition is found as well'
Assert-Equal '' $esp.DriveLetter 'The hidden partition has no drive letter'
$letter = Enable-EspDriveLetter -Esp $esp
Assert-True (-not [string]::IsNullOrEmpty($letter)) 'A drive letter is assigned to the hidden partition'
Assert-Equal $letter $script:FakeEspLetter 'The assigned drive letter was applied'
Remove-EspDriveLetter -Esp $esp -Letter $letter
Assert-Equal '' $script:FakeEspLetter 'The assigned drive letter is removed again'

Write-Host 'The zstd helper'
# The firmware download is written into the standard input of the helper. The
# parameter that carries the stream must not be called $input, because that
# name belongs to the automatic variable of PowerShell and it cannot be bound
# to a stream.
. (Join-Path $root 'windows/installer/Get-FirmwareAssets.ps1')
Assert-True ($null -ne (Get-Command Invoke-ZstdHelper -ErrorAction SilentlyContinue)) 'The helper call is a function of its own'
Assert-True ($null -ne (Get-Command Get-PackageMember -ErrorAction SilentlyContinue)) 'The package download is a function of its own'

$parameters = (Get-Command Invoke-ZstdHelper).Parameters.Keys
foreach ($name in @('HelperPath', 'Member', 'OutputPath', 'InputStream')) {
    Assert-True ($parameters -contains $name) "The helper call takes a $name"
}
$streamParameter = (Get-Command Invoke-ZstdHelper).Parameters['InputStream']
Assert-True ($null -ne $streamParameter) 'The stream parameter exists'
Assert-Equal 'System.IO.Stream' $streamParameter.ParameterType.FullName 'The stream parameter is a stream'
Assert-True (-not $parameters.Contains('Input')) 'The stream parameter is not called Input'

Write-Host 'The entry point of the installer'

# The packaged installer calls this script with these switches, so they have
# to exist. Without the log the user is left with a window that closed
# again, and without the check only mode the automatic test would change
# the boot configuration of the machine it runs on.
$entry = Get-Command (Join-Path $root 'windows/installer/Invoke-Installer.ps1')
$entryParameters = $entry.Parameters.Keys
foreach ($name in @('Yes', 'CheckOnly', 'LogPath', 'Uninstall', 'PayloadDirectory', 'AssetDirectory')) {
    Assert-True ($entryParameters -contains $name) "the entry point takes a $name"
}

$source = Get-Content (Join-Path $root 'windows/installer/Invoke-Installer.ps1') -Raw
Assert-Contains $source 'WGPU-RESULT' 'the entry point writes a result marker'
Assert-Contains $source 'Start-Transcript' 'the entry point writes a log file'
Assert-Contains $source 'Stop-Transcript' 'the entry point closes the log file'

Write-Host 'The log that the installer writes'

# The installer writes the first lines of the log itself, and the script
# takes the file over from there. Two things went wrong with that before.
# The line endings were written as text, so the welcome page and the log
# showed "`r`n" instead of a line break. And the append mode of FileOpen
# opens the file without truncating it but leaves the position at the
# start, so every line was written over the one before it.
$nsi = Get-Content (Join-Path $root 'windows/installer/WindowsGPUUnlock.nsi') -Raw
Assert-True (-not $nsi.Contains('`r`n')) 'the installer script has no backtick line endings'
Assert-True ($nsi.Contains('$\r$\n')) 'the installer script writes real line endings'

$openings = [regex]::Matches($nsi, 'FileOpen \$2 "\$INSTDIR\\\$\{LOGFILE\}" a')
Assert-Equal 2 $openings.Count 'the log is opened in append mode twice'
foreach ($opening in $openings) {
    $after = $nsi.Substring($opening.Index + $opening.Length)
    $write = $after.IndexOf('FileWrite')
    Assert-True ($write -ge 0) 'there is a write after every append'
    if ($write -ge 0) {
        $between = $after.Substring(0, $write)
        Assert-Contains $between 'FileSeek $2 0 END' 'the append is put at the end of the file before it is written to'
    }
}

# One writer for the file. Appending the transcript to what the installer
# wrote leaves two encodings in one file, and half of it cannot be read.
Assert-True ($source -notmatch 'Start-Transcript[^\r\n]*-Append') 'the entry point does not append to the log'
Assert-Contains $source 'Start-Transcript -Path $LogPath -Force' 'the entry point takes the log file over'

Write-Host 'The payload that the installer carries'

# The EFI application and the helper are carried as base64 text, because
# antivirus software on a Windows machine often refuses an unsigned EFI
# application, and the installer would then not even unpack it. The file
# that comes out has to be the one that went in.
. (Join-Path $root 'windows/installer/Installer-Common.ps1')
Assert-True ($null -ne (Get-Command Expand-EmbeddedPayload -ErrorAction SilentlyContinue)) 'the unpacker is a function of its own'
Assert-True ($null -ne (Get-Command Expand-InstallerPayload -ErrorAction SilentlyContinue)) 'the payload unpacker is a function of its own'

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('wgpu-payload-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    # A file with a known content, written as the text that the installer
    # would carry.
    $original = [byte[]](0, 1, 2, 3, 250, 251, 252, 253, 254, 255)
    $text = [Convert]::ToBase64String($original)
    $textFile = Join-Path $scratch 'sample-payload.txt'
    [System.IO.File]::WriteAllText($textFile, $text)

    $target = Join-Path $scratch 'sample.bin'
    $digest = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($original)).Replace('-', '').ToLowerInvariant()
    $null = Expand-EmbeddedPayload -TextFile $textFile -TargetPath $target -ExpectedSha256 $digest
    $actual = [System.IO.File]::ReadAllBytes($target)
    Assert-Equal $original.Length $actual.Length 'the unpacked file has the same length'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual([byte[]]$original, [byte[]]$actual)) 'the unpacked file has the same content'

    # A digest that does not match has to be refused.
    $refused = $false
    try {
        $null = Expand-EmbeddedPayload -TextFile $textFile -TargetPath $target -ExpectedSha256 ('0' * 64)
    } catch {
        $refused = $true
    }
    Assert-True $refused 'an unpacked file with the wrong digest is refused'
} finally {
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}

Write-Host 'The digest function'

# The installer has to be able to compute a digest on every Windows it runs
# on. The Get-FileHash cmdlet is not in every Windows PowerShell, and a
# machine that does not have it cannot verify anything.
Assert-True ($null -ne (Get-Command Get-Sha256 -ErrorAction SilentlyContinue)) 'the digest function exists'

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('wgpu-digest-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $file = Join-Path $scratch 'bytes.bin'
    [System.IO.File]::WriteAllBytes($file, [byte[]](0..255))
    $digest = Get-Sha256 -Path $file
    Assert-Equal '40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880' $digest 'the digest of the 256 bytes is right'
} finally {
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}

Write-Host ''
if ($script:Failures -eq 0) {
    Write-Host "all checks passed ($script:Checks)" -ForegroundColor Green
    exit 0
}
Write-Host "$script:Failures of $script:Checks checks failed" -ForegroundColor Red
exit 1
