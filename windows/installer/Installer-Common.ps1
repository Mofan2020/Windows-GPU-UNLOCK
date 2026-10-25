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

# ---------------------------------------------------------------------------
# The boot configuration.
#
# bcdedit prints the boot configuration in the language of the machine: the
# name of a property is translated, so "identifier" is "Identificador" on a
# Spanish Windows and something else on a Chinese one. The value of a
# property is not translated, and an identifier always has the same shape.
#
# Everything below therefore looks for values and never for names. A dump
# also has to be taken with the verbose switch, because bcdedit prints the
# name of a well known object, such as {bootmgr}, instead of its identifier
# when it is not.
# ---------------------------------------------------------------------------

$script:BcdIdentifierPattern = '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}'

# bcdedit does not always report a failure in its exit code. It writes the
# reason into its output and returns zero all the same, so the output has to
# be read as well. These are the ways in which it says that a command did not
# do what it was asked to do.
$script:BcdFailurePattern = '(?im)^(an error occurred|the request is not supported|access is denied|the operation was not completed)|specified is not valid\.'

# An object in a dump starts with its name, then a line of dashes, then its
# properties. The objects are separated by an empty line.
$script:BcdObjectPattern = '(?ms)^(?<name>[^\r\n]+)\r?\n-{3,}[ \t]*\r?\n(?<body>.*?)(?=\r?\n[ \t]*\r?\n|\z)'

function Get-BcdEditPath {
    <#
    .SYNOPSIS
        The path of bcdedit.exe.
    .DESCRIPTION
        bcdedit.exe is a 64 bit program and there is no 32 bit copy of it. A
        32 bit process cannot see it in the system directory, because the
        system directory of such a process points at the 32 bit one, and the
        command is then not found at all. The Sysnative alias reaches the
        64 bit one from a 32 bit process.
    #>
    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\bcdedit.exe'),
        (Join-Path $env:SystemRoot 'Sysnative\bcdedit.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    $found = Get-Command bcdedit -ErrorAction SilentlyContinue
    if ($null -ne $found) {
        return $found.Source
    }
    throw ("bcdedit.exe was not found. It is a 64 bit program, and a 32 bit process cannot run it." +
        " Looked in: $($candidates -join ', ')")
}

function Test-BcdFailure {
    <#
    .SYNOPSIS
        Whether the output of bcdedit says that the command failed.
    .DESCRIPTION
        bcdedit does not always report a failure in its exit code. It writes
        the reason into its output and returns zero all the same, so the
        output has to be read as well.
    #>
    param([Parameter(Mandatory)][string]$Text)

    if ($Text -match $script:BcdFailurePattern) {
        return $true
    }
    return $false
}

function Invoke-Bcd {
    <#
    .SYNOPSIS
        Runs bcdedit and returns its output.

    .DESCRIPTION
        The raw output can be put into the log, because bcdedit writes its
        reasons to the error stream and those do not end up in the transcript
        of Windows PowerShell. A failure carries the output with it, so that
        the reason is in the message and not only in the log.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$LogOutput,
        [switch]$IgnoreFailure
    )

    $bcdedit = Get-BcdEditPath

    # bcdedit writes to its error stream when it does not like something.
    # That is read here instead of being turned into a terminating error, so
    # that the reason it gives ends up in the log.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $bcdedit @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }

    $text = (@($output) | ForEach-Object { [string]$_ }) -join "`r`n"

    if ($LogOutput) {
        Write-Host "bcdedit $($Arguments -join ' '):"
        Write-Host $text
    }

    # A failure is reported in the exit code and in the output. bcdedit
    # returns zero for some of them, so the output is what decides.
    if ($code -ne 0 -or (Test-BcdFailure -Text $text)) {
        if ($IgnoreFailure) {
            return $null
        }
        throw "bcdedit $($Arguments -join ' ') failed (exit $code):`r`n$text"
    }
    return $text
}

function Get-BcdIdentifier {
    <#
    .SYNOPSIS
        The identifier of the object in a boot configuration dump.
    .DESCRIPTION
        The dump has to be taken with the verbose switch, because bcdedit
        prints the name of a well known object, such as {bootmgr}, instead of
        its identifier otherwise. The identifier is the first value in the
        dump that has the shape of a GUID.
    #>
    param([Parameter(Mandatory)][string]$Text)

    $match = [regex]::Match($Text, $script:BcdIdentifierPattern)
    if (-not $match.Success) {
        return $null
    }
    return $match.Value
}

function Get-BcdObject {
    <#
    .SYNOPSIS
        The objects in a boot configuration dump, one record each.
    .DESCRIPTION
        The name of an object is the description it carries, and a copied
        entry has no name of its own in bcdedit, so the name of the copy is
        the description that was given to it.
    #>
    param([Parameter(Mandatory)][string]$Text)

    $objects = @()
    foreach ($match in [regex]::Matches($Text, $script:BcdObjectPattern)) {
        $objects += [pscustomobject]@{
            Name = $match.Groups['name'].Value.Trim()
            Body = $match.Groups['body'].Value
        }
    }
    return $objects
}

function Get-BcdEntryId {
    <#
    .SYNOPSIS
        The identifier of the boot entry with a given description.
    .DESCRIPTION
        The name of the "description" property is in the language of the
        machine, so the property is not looked for by its name. Its value is
        not translated, and it is the name that was given to the entry. The
        name of the object in the dump is not that value: bcdedit prints the
        kind of the object there, so a copied Windows Boot Manager is called
        "Windows Boot Manager" whatever its description says.

        The copied entry has no name of its own in bcdedit, so its
        identifier is a real GUID and is the first one in the object.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Description
    )

    foreach ($object in (Get-BcdObject -Text $Text)) {
        $matched = ($object.Name -eq $Description)
        if (-not $matched) {
            # The description is a property of the object as well, and its
            # value is the same string. The property line is a name and a
            # value, separated by at least two spaces.
            foreach ($line in ($object.Body -split '\r?\n')) {
                $trimmed = $line.Trim()
                if (-not $trimmed) { continue }
                $parts = $trimmed -split '\s{2,}', 2
                if ($parts.Count -lt 2) { continue }
                if ($parts[1].Trim() -eq $Description) {
                    $matched = $true
                    break
                }
            }
        }
        if (-not $matched) {
            continue
        }
        $match = [regex]::Match($object.Name + "`r`n" + $object.Body, $script:BcdIdentifierPattern)
        if ($match.Success) {
            return $match.Value
        }
    }
    return $null
}

function Get-BcdDisplayOrder {
    <#
    .SYNOPSIS
        The firmware boot order from a dump of the firmware boot manager.
    .DESCRIPTION
        The order is the list of the identifiers that the manager tries, and
        it is the only list of identifiers in that object. The name of the
        property is in the language of the machine, so the list is not looked
        for by its name: the identifiers of the dump are taken in order, and
        the first one is the identifier of the manager itself.
    #>
    param([Parameter(Mandatory)][string]$Text)

    $found = @([regex]::Matches($Text, $script:BcdIdentifierPattern) | ForEach-Object { $_.Value })
    if ($found.Count -le 1) {
        return @()
    }
    return @($found[1..($found.Count - 1)])
}

function Get-BcdPropertyValue {
    <#
    .SYNOPSIS
        The values of the properties in a dump whose value has a given shape.
    .DESCRIPTION
        A property line is a name and a value, separated by at least two
        spaces. The name is in the language of the machine and is ignored
        here; only the value is matched, which is not translated.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ValuePattern
    )

    $values = @()
    foreach ($line in ($Text -split '\r?\n')) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $parts = $trimmed -split '\s{2,}', 2
        if ($parts.Count -lt 2) { continue }
        $value = $parts[1].Trim()
        if ($value -match $ValuePattern) {
            $values += $value
        }
    }
    return $values
}

function Test-BcdPropertyValue {
    <#
    .SYNOPSIS
        Whether a dump carries a property with a given value.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Value
    )

    foreach ($line in ($Text -split '\r?\n')) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $parts = $trimmed -split '\s{2,}', 2
        if ($parts.Count -lt 2) { continue }
        if ($parts[1].Trim() -eq $Value) {
            return $true
        }
    }
    return $false
}

function Register-BcdBootEntry {
    <#
    .SYNOPSIS
        Registers a boot entry that starts the unlock application.

    .DESCRIPTION
        The entry is a copy of the Windows Boot Manager, so that it inherits
        the partition that the boot manager itself boots from. bcdedit says
        which identifier the new entry got, and that is read from its answer
        rather than looked for afterwards: a name is what a person sees, and
        the identifier is what bcdedit works with.

        The order in which the firmware tries the entries is changed as well,
        so that the new entry comes first. The order before the change is
        returned, so that it can be put back later.

    .PARAMETER Description
        The name the entry carries in the boot menu.

    .PARAMETER Path
        The path of the EFI application, on the partition the entry boots
        from.
    #>
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Path
    )

    # The Windows Boot Manager. The dump is taken with the verbose switch,
    # because bcdedit prints the name of a well known object, such as
    # {bootmgr}, instead of its identifier otherwise. The names of the
    # properties in the dump are in the language of the machine, so nothing is
    # looked for by a name: the identifier is the first value in the dump
    # that has the shape of a GUID.
    $managerText = Invoke-Bcd @('/enum', '{bootmgr}', '/v') -LogOutput
    $managerId = Get-BcdIdentifier -Text $managerText
    if (-not $managerId) {
        throw 'The identifier of the Windows Boot Manager could not be read'
    }

    # The device the Windows Boot Manager boots from. That is the partition
    # the boot manager itself lives on, which is the EFI system partition.
    $managerDevices = @(Get-BcdPropertyValue -Text $managerText -ValuePattern '^partition=')
    $managerDevice = ''
    if ($managerDevices.Count -gt 0) {
        $managerDevice = $managerDevices[0]
    }

    # The boot order before the change, so that it can be restored.
    $beforeOrder = @(Get-BcdDisplayOrder (Invoke-Bcd @('/enum', '{fwbootmgr}', '/v') -LogOutput))
    if ($beforeOrder.Count -eq 0) {
        $beforeOrder = @($managerId)
    }

    # The copy.
    $copyText = Invoke-Bcd @('/copy', '{bootmgr}', '/d', $Description) -LogOutput
    $newId = Get-BcdIdentifier -Text $copyText
    if (-not $newId) {
        throw 'The identifier of the new boot entry was not given by bcdedit'
    }

    # The device. The copy starts out with the one of the Windows Boot
    # Manager. It is checked and, if it names another partition or none at
    # all, it is set to the one of the boot manager. A drive letter is not
    # used for it, because a letter is not known to the firmware at boot
    # time.
    $entryText = Invoke-Bcd @('/enum', $newId, '/v') -LogOutput
    $entryDevices = @(Get-BcdPropertyValue -Text $entryText -ValuePattern '^partition=')
    if ($entryDevices.Count -eq 0 -or ($managerDevice -and $entryDevices[0] -ne $managerDevice)) {
        if (-not $managerDevice) {
            throw 'The Windows Boot Manager does not name a device, and the new entry does not either'
        }
        [void](Invoke-Bcd @('/set', $newId, 'device', $managerDevice))
        $entryText = Invoke-Bcd @('/enum', $newId, '/v') -LogOutput
        $entryDevices = @(Get-BcdPropertyValue -Text $entryText -ValuePattern '^partition=')
        if ($entryDevices.Count -eq 0) {
            throw 'The boot entry does not name the partition it boots from'
        }
    }

    # The path of the application.
    [void](Invoke-Bcd @('/set', $newId, 'path', $Path))

    # The firmware boot order. The new entry comes first, so that the unlock
    # runs before the driver of the card binds it. The Windows Boot Manager
    # stays in the order behind it, so that the machine still boots if the
    # application returns without starting Windows.
    $newOrder = @($newId) + @($beforeOrder | Where-Object { $_ -ne $newId })
    [void](Invoke-Bcd (@('/set', '{fwbootmgr}', 'displayorder') + $newOrder))

    # Read the result back.
    $afterOrder = @(Get-BcdDisplayOrder (Invoke-Bcd @('/enum', '{fwbootmgr}', '/v') -LogOutput))
    if (($afterOrder -join ',') -ne ($newOrder -join ',')) {
        throw "The firmware boot order does not match the plan. Expected $($newOrder -join ','), found $($afterOrder -join ',')"
    }
    $afterText = Invoke-Bcd @('/enum', $newId, '/v') -LogOutput
    if (-not (Test-BcdPropertyValue -Text $afterText -Value $Path)) {
        throw "The boot entry does not point at the staged application. It says:`r`n$afterText"
    }

    return [pscustomobject]@{
        Identifier  = $newId
        Description = $Description
        Device      = $entryDevices[0]
        OrderBefore = @($beforeOrder)
        OrderAfter  = @($afterOrder)
    }
}

function Unregister-BcdBootEntry {
    <#
    .SYNOPSIS
        Removes a boot entry and puts the firmware boot order back.

    .PARAMETER Identifier
        The identifier of the entry.

    .PARAMETER OrderBefore
        The order that was in place before the entry was registered.
    #>
    param(
        [Parameter(Mandatory)][string]$Identifier,
        [string[]]$OrderBefore = @()
    )

    $current = @(Get-BcdDisplayOrder (Invoke-Bcd @('/enum', '{fwbootmgr}', '/v') -LogOutput))
    $restored = @($current | Where-Object { $_ -ne $Identifier })
    $original = @()
    if ($OrderBefore) {
        $original = @($OrderBefore | Where-Object { $_ -ne $Identifier })
    }
    if ($original.Count -gt 0) {
        [void](Invoke-Bcd (@('/set', '{fwbootmgr}', 'displayorder') + $original))
    } elseif ($restored.Count -gt 0) {
        [void](Invoke-Bcd (@('/set', '{fwbootmgr}', 'displayorder') + $restored))
    }

    # The entry itself is taken away as well, and not only put out of the
    # order. It may be gone already, which is not a failure.
    [void](Invoke-Bcd @('/delete', $Identifier) -IgnoreFailure)

    return @(Get-BcdDisplayOrder (Invoke-Bcd @('/enum', '{fwbootmgr}', '/v') -LogOutput))
}

function Get-FirmwareBootOrderNotice {
    <#
    .SYNOPSIS
        The text that tells the user how to set the boot order by hand.

    .DESCRIPTION
        The installer puts the new entry first in the firmware boot order
        and reads the order back, to make sure that it is really there.
        That is all that Windows can do about it. Some motherboards keep
        an order of the entries inside UEFI of their own and ignore the
        one that is set here, and MSI boards are known for that. The
        installer cannot change the settings of the firmware, so it tells
        the user what to do and where to look.

        The same text is shown at the end of the installation and written
        into a file, so that the two cannot drift apart.

    .PARAMETER Identifier
        The identifier of the boot entry.

    .PARAMETER Description
        The name the entry carries in the boot menu.

    .PARAMETER Path
        The path of the application on the EFI system partition.
    #>
    param(
        [Parameter(Mandatory)][string]$Identifier,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Path
    )

    return @(
        'Some motherboards keep an order of the entries inside UEFI of their own and'
        'ignore the one that Windows sets. MSI boards are known for this.'
        ''
        'If the machine boots straight into Windows, without the screen going black'
        'for a few seconds and without the question about pressing C, then the'
        'firmware ignored the order, and the unlock did not run.'
        ''
        'To set the order by hand:'
        '  1. Restart the machine and enter the firmware setup. On an MSI board that'
        '     is the DEL key while it starts. The boot menu of the firmware is F11.'
        '  2. Open the boot order. It is under "Boot", or under "Advanced", and it is'
        '     called "Boot Option #1" or "UEFI boot order", depending on the board.'
        ('  3. In the list of the entries inside UEFI, move "{0}" in front of' -f $Description)
        '     "Windows Boot Manager".'
        '  4. Save the settings and leave the firmware. The machine starts the unlock'
        '     application, and then Windows.'
        ''
        'The entry to look for:'
        ('  name        {0}' -f $Description)
        ('  identifier  {0}' -f $Identifier)
        ('  file        {0}' -f $Path)
    )
}

function Write-FirmwareBootOrderNotice {
    <#
    .SYNOPSIS
        Writes the note about the boot order to a file.

    .DESCRIPTION
        The note is written next to the other files of the installation,
        because the moment it is needed is after a restart, when the user is
        in Windows and does not have the log at hand.

    .PARAMETER Path
        The file the note is written to.

    .PARAMETER Identifier
        The identifier of the boot entry.

    .PARAMETER Description
        The name the entry carries in the boot menu.

    .PARAMETER EfiPath
        The path of the application on the EFI system partition.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Identifier,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$EfiPath
    )

    $lines = @(Get-FirmwareBootOrderNotice -Identifier $Identifier -Description $Description -Path $EfiPath)
    $lines | Set-Content -LiteralPath $Path -Encoding UTF8
    return $lines
}