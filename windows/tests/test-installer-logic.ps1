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

# A format expression in a command has to be in parentheses. Without them
# PowerShell reads the -f as the name of a parameter, and the value that
# comes after it ends up in the parameter that comes next. That happened with
# the last line of the installer: the installation itself had worked, but the
# line that says so failed, and the installer reported a failure because of
# it. The parser tells the two forms apart, so the check is exact.
foreach ($script in (Get-ChildItem (Join-Path $root 'windows/installer') -Filter *.ps1)) {
    $parseErrors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$parseErrors)
    if ($null -eq $tree) { continue }
    $commands = $tree.FindAll({
            param($node) $node -is [System.Management.Automation.Language.CommandAst]
        }, $true)
    foreach ($command in $commands) {
        if ($command.GetCommandName() -ne 'Write-Host') { continue }
        foreach ($element in $command.CommandElements) {
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($element.ParameterName -ne 'f') { continue }
            Assert-True $false ("{0}:{1} has a format expression without parentheses" -f `
                    $script.Name, $element.Extent.StartLineNumber)
        }
    }
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

# A virtual display adapter, such as the one a remote desktop program
# installs. It has no place on the PCI bus.
function New-FakeVirtualAdapter {
    param([string]$Name)
    return [pscustomobject]@{
        Name           = $Name
        PNPDeviceID    = 'ROOT\DISPLAY\0000'
        DriverVersion  = '1.0.0.0'
        AdapterRAM     = 0
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

# A virtual display adapter has no place on the PCI bus, so it cannot take
# the screen over from the card that is unlocked.
$script:FakeVideoControllers = @(
    New-FakeAdapter -Name 'NVIDIA GeForce RTX 3060' -Vendor '10DE' -Device '2504'
    New-FakeVirtualAdapter -Name 'GameViewer Virtual Display Adapter'
)
$result = Test-UnlockTarget
Assert-True $result.Supported 'A machine with a virtual display adapter next to the card is accepted'
$physical = @($result.Adapters | Where-Object { $_.IsPhysical })
Assert-Equal 1 $physical.Count 'The virtual adapter is not a physical one'
Assert-Equal 'NVIDIA GeForce RTX 3060' $physical[0].Adapter 'The card itself is the physical one'

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

Write-Host 'The boot configuration parser'
# bcdedit does not always report a failure in its exit code. It writes the
# reason into its output and returns zero all the same, so the output has to
# be read as well. That is what the installer does now, and the reasons that
# were seen on a real Windows are the ones that are checked here.
Assert-True (-not (Test-BcdFailure -Text 'The operation completed successfully.')) `
    'a command that worked is not a failure'
Assert-True (Test-BcdFailure -Text 'An error occurred while attempting the specified create operation.') `
    'a command that could not be carried out is a failure'
Assert-True (Test-BcdFailure -Text 'The application type switch specified is not valid.') `
    'a switch that does not exist is a failure'
Assert-True (Test-BcdFailure -Text 'The request is not supported.') `
    'a request that is not supported is a failure'
Assert-True (Test-BcdFailure -Text 'An error occurred while attempting to reference the specified entry.') `
    'a reference to an entry that is not there is a failure'
Assert-True (-not (Test-BcdFailure -Text 'There are no matching objects or the store is empty.')) `
    'an entry that is not there is an answer and not a failure'

# bcdedit prints the names of the properties in the language of the machine.
# A Chinese Windows says "标识符" where an English one says "identifier", so
# the parser must not look for a name at all. It looks for the values, and an
# identifier always has the shape of a GUID.
$english = @"
Windows Boot Manager
--------------------
identifier              {bootmgr}
device                  partition=\Device\HarddiskVolume3
path                    \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager
locale                  en-US
"@
Assert-True ($null -eq (Get-BcdIdentifier -Text $english)) `
    'a dump that was not taken with the verbose switch has no identifier to read'

$verbose = @"
Windows Boot Manager
--------------------
identifier              {9dea862c-5cdd-4e70-acc1-f32b344d4795}
device                  partition=\Device\HarddiskVolume3
path                    \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager
"@
Assert-Equal '{9dea862c-5cdd-4e70-acc1-f32b344d4795}' (Get-BcdIdentifier -Text $verbose) `
    'the identifier is read from a verbose dump'
Assert-Equal 'partition=\Device\HarddiskVolume3' `
    (@(Get-BcdPropertyValue -Text $verbose -ValuePattern '^partition=')[0]) `
    'the device is read by the shape of its value'
Assert-True (Test-BcdPropertyValue -Text $verbose -Value '\EFI\Microsoft\Boot\bootmgfw.efi') `
    'the path is found by its value'
Assert-True (-not (Test-BcdPropertyValue -Text $verbose -Value '\EFI\Other\Other.efi')) `
    'a value that is not there is not found'

# The same dump in the language of a Chinese Windows. Nothing in it is known
# to the parser except the values.
$chinese = @"
Windows 启动管理器
--------------------
标识符                 {9dea862c-5cdd-4e70-acc1-f32b344d4795}
设备                   partition=\Device\HarddiskVolume3
路径                   \EFI\Microsoft\Boot\bootmgfw.efi
描述                   Windows 启动管理器
"@
Assert-Equal '{9dea862c-5cdd-4e70-acc1-f32b344d4795}' (Get-BcdIdentifier -Text $chinese) `
    'the identifier is read from a Chinese dump'
Assert-Equal 'partition=\Device\HarddiskVolume3' `
    (@(Get-BcdPropertyValue -Text $chinese -ValuePattern '^partition=')[0]) `
    'the device is read from a Chinese dump'
Assert-True (Test-BcdPropertyValue -Text $chinese -Value '\EFI\Microsoft\Boot\bootmgfw.efi') `
    'the path is found in a Chinese dump'

# A dump with names that the parser has never seen.
$unknown = @"
Whatever this is
----------------
somethingelse         {12345678-1234-1234-1234-123456789abc}
anotherthing          partition=\Device\HarddiskVolume9
"@
Assert-Equal '{12345678-1234-1234-1234-123456789abc}' (Get-BcdIdentifier -Text $unknown) `
    'the identifier is found without any known name'
Assert-Equal 'partition=\Device\HarddiskVolume9' `
    (@(Get-BcdPropertyValue -Text $unknown -ValuePattern '^partition=')[0]) `
    'the device is found without any known name'

Write-Host 'The firmware boot order'

$firmware = @"
Firmware Boot Manager
---------------------
identifier              {a5a30fa2-3d06-4e9f-b5f4-a01df9d1fcba}
displayorder            {9dea862c-5cdd-4e70-acc1-f32b344d4795}
timeout                 0
"@
$order = @(Get-BcdDisplayOrder $firmware)
Assert-Equal 1 $order.Count 'The firmware boot order has one entry'
Assert-Equal '{9dea862c-5cdd-4e70-acc1-f32b344d4795}' $order[0] 'The Windows Boot Manager is the entry'
Assert-Equal 0 @(Get-BcdDisplayOrder 'nothing here').Count 'A dump without an order gives no entries'

# An order with more than one entry is printed on more than one line.
$firmware = @"
Firmware Boot Manager
---------------------
identifier              {a5a30fa2-3d06-4e9f-b5f4-a01df9d1fcba}
displayorder            {11111111-2222-3333-4444-555555555555}
                        {9dea862c-5cdd-4e70-acc1-f32b344d4795}
timeout                 0
"@
$order = @(Get-BcdDisplayOrder $firmware)
Assert-Equal 2 $order.Count 'The firmware boot order has two entries'
Assert-Equal '{11111111-2222-3333-4444-555555555555}' $order[0] 'The first entry is read'
Assert-Equal '{9dea862c-5cdd-4e70-acc1-f32b344d4795}' $order[1] 'The second entry is read'

# The name of the property is in the language of the machine, so the order is
# taken from the identifiers of the dump and not from a name.
$firmware = @"
固件启动管理器
---------------------
标识符                 {a5a30fa2-3d06-4e9f-b5f4-a01df9d1fcba}
显示顺序               {11111111-2222-3333-4444-555555555555}
超时                   0
"@
$order = @(Get-BcdDisplayOrder $firmware)
Assert-Equal 1 $order.Count 'The firmware boot order is read in Chinese too'
Assert-Equal '{11111111-2222-3333-4444-555555555555}' $order[0] 'The entry is the right one'

Write-Host 'The boot entry that was made'

$all = @"
Windows Boot Manager
--------------------
identifier              {bootmgr}
device                  partition=\Device\HarddiskVolume3
path                    \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager

Windows GPU UNLOCK
------------------
identifier              {7a7a7a7a-1b2b-3c3c-4d4d-5e5e5e5e5e5e}
device                  partition=\Device\HarddiskVolume3
path                    \EFI\WindowsGPUUnlock\UNLOCK.EFI
description             Windows GPU UNLOCK

Windows Memory Tester
---------------------
identifier              {memdiag}
inherit                 {bootmgr}
testsigning             Yes
"@
Assert-Equal '{7a7a7a7a-1b2b-3c3c-4d4d-5e5e5e5e5e5e}' `
    (Get-BcdEntryId -Text $all -Description 'Windows GPU UNLOCK') `
    'The entry is found by its description'
Assert-True ($null -eq (Get-BcdEntryId -Text $all -Description 'Windows Boot Manager')) `
    'A well known object has no identifier of its own to read'
Assert-True ($null -eq (Get-BcdEntryId -Text $all -Description 'Windows Memory Tester')) `
    'A well known object is not found by its name either'
Assert-True ($null -eq (Get-BcdEntryId -Text $all -Description 'Nothing Like This')) `
    'An entry that is not there is not found'

# The same list in Chinese.
$all = @"
Windows GPU UNLOCK
------------------
标识符                 {7a7a7a7a-1b2b-3c3c-4d4d-5e5e5e5e5e5e}
设备                   partition=\Device\HarddiskVolume3
路径                   \EFI\WindowsGPUUnlock\UNLOCK.EFI
描述                   Windows GPU UNLOCK
"@
Assert-Equal '{7a7a7a7a-1b2b-3c3c-4d4d-5e5e5e5e5e5e}' `
    (Get-BcdEntryId -Text $all -Description 'Windows GPU UNLOCK') `
    'The entry is found in a Chinese dump as well'

# bcdedit ends its lines with a carriage return and a line feed. A pattern
# that expects the end of the line right after the value does not match that,
# and the entry was not found on a Windows. The dumps that Windows produces
# are therefore read with the same endings.
$crlf = ($all -replace "`r`n", "`n") -replace "`n", "`r`n"
Assert-Equal '{7a7a7a7a-1b2b-3c3c-4d4d-5e5e5e5e5e5e}' `
    (Get-BcdEntryId -Text $crlf -Description 'Windows GPU UNLOCK') `
    'The entry is found in a dump with CRLF line endings'

$crlf = ($verbose -replace "`r`n", "`n") -replace "`n", "`r`n"
Assert-Equal '{9dea862c-5cdd-4e70-acc1-f32b344d4795}' (Get-BcdIdentifier -Text $crlf) `
    'The identifier is read from a dump with CRLF line endings'
Assert-Equal 'partition=\Device\HarddiskVolume3' `
    (@(Get-BcdPropertyValue -Text $crlf -ValuePattern '^partition=')[0]) `
    'The device is read from a dump with CRLF line endings'
Assert-True (Test-BcdPropertyValue -Text $crlf -Value '\EFI\Microsoft\Boot\bootmgfw.efi') `
    'The path is found in a dump with CRLF line endings'

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

Write-Host 'The tar calls'

# The output of a native program is not part of the transcript of Windows
# PowerShell, so a tar that fails has to say why, in the log. The helper
# gives back what tar wrote and what it returned.
. (Join-Path $root 'windows/installer/Get-FirmwareAssets.ps1')

Assert-True ($null -ne (Get-Command Invoke-Tar -ErrorAction SilentlyContinue)) 'the tar caller is a function of its own'
Assert-True ($null -ne (Get-Command Quote-NativeArgument -ErrorAction SilentlyContinue)) 'the argument quoter is a function of its own'
Assert-True ($null -ne (Get-Command Get-GeneratedSourceFromApi -ErrorAction SilentlyContinue)) 'the mirror reader is a function of its own'

# The pipeline does not let tar match a pattern. The tar of Windows does not
# match them the way the one on a Linux machine does, and a pattern that it
# does not match ends the extraction with an error and nothing extracted.
$assets = Get-Content (Join-Path $root 'windows/installer/Get-FirmwareAssets.ps1') -Raw
Assert-True (-not $assets.Contains('*/src/nvidia/generated')) 'the pipeline does not ask tar to match a pattern'
Assert-Contains $assets "Invoke-Tar" 'the pipeline runs tar through the helper'

# An argument with a space in it has to reach the program as one argument.
Assert-Equal 'plain' (Quote-NativeArgument 'plain') 'a plain argument is left alone'
Assert-Equal '"with space"' (Quote-NativeArgument 'with space') 'an argument with a space is quoted'
Assert-Equal 'C:\dir\' (Quote-NativeArgument 'C:\dir\') 'an argument without a space is left alone'
Assert-Equal '"C:\dir with space\\"' (Quote-NativeArgument 'C:\dir with space\') 'a trailing backslash is doubled in a quoted argument'

$tarPath = (Get-Command tar -ErrorAction SilentlyContinue).Source
if ($tarPath) {
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('wgpu-tar-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    try {
        # A file with a known name, so that the listing has something to say.
        [System.IO.File]::WriteAllText((Join-Path $scratch 'member.txt'), "hello`n")
        $archive = Join-Path $scratch 'test.tar'
        & $tarPath -cf $archive -C $scratch 'member.txt'
        if ($LASTEXITCODE -ne 0) { throw 'the test archive could not be made' }

        $listing = Invoke-Tar -TarPath $tarPath -Arguments @('-tf', $archive) -WorkingDirectory $scratch
        Assert-Equal 0 $listing.ExitCode 'tar lists the archive'
        Assert-True ($listing.StdOut -like '*member.txt*') 'the listing names the member'

        # A member that is not in the archive makes tar fail, and it says so
        # on its error stream. That is what has to reach the log.
        $failure = Invoke-Tar -TarPath $tarPath -Arguments @('-xf', $archive, '-C', $scratch, 'nosuchmember.txt') -WorkingDirectory $scratch
        Assert-True ($failure.ExitCode -ne 0) 'tar fails on a member that is not there'
        Assert-True ($failure.StdErr.Trim().Length -gt 0) 'tar says why it failed'
    } finally {
        if (Test-Path -LiteralPath $scratch) {
            Remove-Item -LiteralPath $scratch -Recurse -Force
        }
    }
}

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

Write-Host 'The 64 bit process'

# bcdedit.exe is a 64 bit program and there is no 32 bit copy of it. A 32 bit
# process cannot see it, because the system directory of such a process
# points at the 32 bit one, and the command is then not found at all. The
# installer is a 32 bit program, so the scripts have to make sure that they
# run in a 64 bit process.
. (Join-Path $root 'windows/installer/Installer-Common.ps1')

Assert-True ($null -ne (Get-Command Restart-As64Bit -ErrorAction SilentlyContinue)) 'the guard is a function of its own'
Assert-True ($null -ne (Get-Command Get-ProcessArchitecture -ErrorAction SilentlyContinue)) 'the architecture helper is a function of its own'

$architecture = Get-ProcessArchitecture
Assert-True ($architecture -in @('32 bit', '64 bit')) 'the architecture is named'
Write-Host "    this test runs in a $architecture process"

# An argument with a space in it has to reach the program as one argument.
Assert-Equal 'plain' (Quote-ProcessArgument 'plain') 'a plain argument is left alone'
Assert-Equal '"with space"' (Quote-ProcessArgument 'with space') 'an argument with a space is quoted'
Assert-Equal '"C:\dir with space\\"' (Quote-ProcessArgument 'C:\dir with space\') 'a trailing backslash is doubled in a quoted argument'

# The entry point has to ask for the 64 bit process before it opens the log,
# so that the log belongs to the process that does the work.
$entrySource = Get-Content (Join-Path $root 'windows/installer/Invoke-Installer.ps1') -Raw
$guardAt = $entrySource.IndexOf('Restart-As64Bit')
$transcriptAt = $entrySource.IndexOf('Start-Transcript')
Assert-True ($guardAt -ge 0) 'the entry point asks for a 64 bit process'
Assert-True ($transcriptAt -ge 0) 'the entry point opens a log'
Assert-True ($guardAt -lt $transcriptAt) 'the guard comes before the log is opened'

# bcdedit is called by its path, and not by its name, because the name is
# only found in a 64 bit process. The caller lives in the common file, so
# that the installer and the uninstaller use the same one.
$commonSource = Get-Content (Join-Path $root 'windows/installer/Installer-Common.ps1') -Raw
$installSource = Get-Content (Join-Path $root 'windows/installer/Install-GpuUnlock.ps1') -Raw
Assert-Contains $commonSource 'Get-BcdEditPath' 'bcdedit is found by its path'
Assert-Contains $commonSource 'Sysnative\bcdedit.exe' 'the 64 bit bcdedit is looked for'
Assert-True (-not $installSource.Contains('& bcdedit ')) 'bcdedit is not called by its name'
Assert-True (-not $commonSource.Contains('& bcdedit ')) 'bcdedit is not called by its name in the common file'

# The parser must not look for the name of a property, because the name is in
# the language of the machine and the value is not.
foreach ($property in @('identifier', 'displayorder', 'description', 'device', 'path')) {
    Assert-True (-not $commonSource.Contains("$property\s")) "the parser does not look for the property $property"
}

# A run that stopped halfway leaves the files on the partition and the drive
# letter with it, but no record. The letter has to be given back then too,
# so the installer looks for that situation and takes the letter over.
Assert-Contains $installSource 'The files of an earlier run are on the partition' 'the installer takes over the drive letter of an earlier run'

# The registry is read and written in the 64 bit view on both sides, so
# that the 32 bit installer and the 64 bit script see the same keys.
$nsiSource = Get-Content (Join-Path $root 'windows/installer/WindowsGPUUnlock.nsi') -Raw
Assert-Contains $nsiSource 'SetRegView 64' 'the installer uses the 64 bit registry view'
Assert-Contains $nsiSource 'Locate-PowerShell' 'the installer looks for the 64 bit PowerShell'

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
Assert-True ($openings.Count -ge 2) 'the log is opened in append mode more than once'
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
