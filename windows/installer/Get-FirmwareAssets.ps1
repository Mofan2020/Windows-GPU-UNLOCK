# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
<#
.SYNOPSIS
    Fetches and generates the firmware assets the unlock needs.

.DESCRIPTION
    The five firmware assets are not shipped with this tool. NVIDIA's licence
    does not permit redistribution of the driver binaries, so the assets are
    produced on the user's own machine from pinned public inputs, exactly as
    the upstream Linux module does.

    Two inputs are downloaded over HTTPS and checked against their pinned
    SHA-256:

      * the NVIDIA open kernel module source archive, which carries the
        Booter and GSP boot images;
      * the nvidia-utils package, which carries the GSP firmware blob.

    From the first, the Booter bundle and the GSP boot images are decoded.
    From the second, the GSP firmware blob is extracted. The V67 payload is
    generated from its pinned constants.

    Every output is verified against the pinned SHA-256 from the upstream
    manifest before it is used. A mismatch stops the installation.

    The nvidia-utils package is a .pkg.tar.zst archive of about 300 MiB. It
    is streamed into the zstdcat helper, which stops as soon as the wanted
    member has been written, so only about 72 MiB are transferred. The
    helper is used because the tar.exe that ships with Windows is built on
    libarchive 3.3.2, which has no zstd support.

.NOTES
    The upstream tools are written in Python 3.14+, which needs its own
    interpreter. This module reimplements the same pinned, verified pipeline
    so the installer has no runtime dependency beyond Windows itself.
#>

Set-StrictMode -Version Latest

# The shared helpers, among them the digest function.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Installer-Common.ps1')

# The directory this file lives in. It is captured while the file is being
# loaded, because the automatic variables are not available once a function
# of this script is called from somewhere else.
$script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Pinned inputs. These match firmware/artifacts-610.43.03.json in the
# upstream Linux repository, commit 0ebdb1c6308b20714be5bf04513472942541956.
$script:Manifest = @{
    Version = '610.43.03-1'
    SourceArchive = @{
        Url     = 'https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-610.43.03.tar.xz'
        Sha256  = '7e118923c7a23edc36114d63273a46e3e04e9af98695a42203e7ac2dfe9fc1dc'
        File    = 'NVIDIA-kernel-module-source-610.43.03.tar.xz'
    }
    UtilsPackage = @{
        Url     = 'https://archive.cachyos.org/archive/cachyos-v3/nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst'
        # The same file is served by the other CachyOS mirrors. The member is
        # checked against its own pinned digest, so a mirror is only a way to
        # reach the same bytes.
        Mirrors = @(
            'https://mirror.cachyos.org/archive/cachyos-v3/nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst'
        )
        Sha256  = 'e17e7c92eeffa178b0fe1f40eb17a47095f8fc3ce4a77bf115cf5bd5a4df86e9'
        File    = 'nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst'
    }
    # The two generated sources are also in the upstream repository, and the
    # contents API serves them as text. That way they can be fetched without
    # an archive that has to be unpacked, which is the part of the pipeline
    # that the tar of Windows does not do the way the one on a Linux machine
    # does. The tag is the one of the release that the archive holds too, and
    # every file is checked against its own pinned digest either way.
    SourceMirror = @{
        Repository = 'NVIDIA/open-gpu-kernel-modules'
        Tag        = '610.43.03'
    }
}

# Pinned source files inside the source archive, with the SHA-256 of the file
# contents.
$script:PinnedSources = @(
    @{
        Path   = 'src/nvidia/generated/g_bindata_kgspGetBinArchiveBooterLoadUcode_GA102.c'
        Sha256 = '04cd3db7f670adc4efd79d2e76217bb809fffddfbd6f1af884cde2af26dd39af'
    }
    @{
        Path   = 'src/nvidia/generated/g_bindata_kgspGetBinArchiveGspRmBoot_GA102.c'
        Sha256 = '35e5aa9075ad3898b6022ffd5820c953d809caa7dabd530cfc1a83dc2a67c5bd'
    }
)

# The expected outputs, with their pinned SHA-256. These match the upstream
# manifest and the hashes the EFI application verifies at run time.
$script:ExpectedOutputs = @{
    'booter_load_ga102.bin'    = '056cbc064a888f80717726c54d7f64fcd68044d123870c95a74f37f4975dcaa4'
    'v67-ga102-610.43.03.bin'  = '2a0aa1f86d0b6afff5214d641d87d46dc98ef06ed908ff05d0ddbad5ffb7e197'
    'gsp_ga10x.bin'            = '572373620a37418f24dc16b5031c39338778c3257e48e8408de9a57291b24f3a'
    'gsp_boot_ga102.bin'       = '3df651acb174fd5f5561a1996965b192f50c5d763168446ed0d4ead19d895768'
    'gsp_boot_desc_ga102.bin'  = 'cc5a3fc1f4c47f2fe107b1b68f0176d8a448e6dec84b575e5560ccef5262bf15'
}

# The GSP firmware blob path inside the nvidia-utils package.
$script:FirmwarePath = 'usr/lib/firmware/nvidia/610.43.03/gsp_ga10x.bin'

# The V67 payload. This is a fixed byte pattern: a fill word with a table of
# patched words. The upstream generator produces exactly these bytes.
$script:V67Fill = [uint32]0x0000019C
$script:V67Size = 0xFA00
$script:V67Patched = [ordered]@{
    0x1100 = [uint32]0x00000007
    # 0xFFFFFFFF does not fit into a signed 32 bit literal in PowerShell, so
    # the value is written out.
    0xF948 = [uint32]4294967295
    0xF950 = [uint32]0x00000D44
    0xF960 = [uint32]0x00823804
    0xF968 = [uint32]0x00001FCE
    0xF974 = [uint32]0x00000000
    0xF97C = [uint32]0x00001101
    0xF980 = [uint32]0x000084C8
    0xF984 = [uint32]0x00008E18
    0xF98C = [uint32]0x000084C8
    0xF990 = [uint32]0x00000000
    0xF998 = [uint32]0x00001FCE
    0xF9A4 = [uint32]0x0000FFBC
    0xF9AC = [uint32]0x00005789
    0xF9BC = [uint32]0x00000D44
    0xF9CC = [uint32]0x00000003
    0xF9D4 = [uint32]0x00001FCE
    0xF9E8 = [uint32]0x00000D52
    0xF9EC = [uint32]0x000081EE
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Sha256 -Path $Path
}

<#
.SYNOPSIS
    Creates the HTTP client used for the downloads.

.DESCRIPTION
    Windows PowerShell does not load the HTTP assembly on its own, so it is
    loaded here. The TLS versions are requested explicitly, because the
    archive that holds the firmware package only speaks TLS 1.3, while the
    default of the older .NET Framework stops at TLS 1.2.
#>
function New-HttpClient {
    param([int]$TimeoutSeconds = 3600)

    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "The HTTP assembly could not be loaded explicitly: $($_.Exception.Message)"
    }

    $handler = New-Object System.Net.Http.HttpClientHandler
    try {
        $handler.SslProtocols = [System.Security.Authentication.SslProtocols]::Tls12 -bor `
            [System.Security.Authentication.SslProtocols]::Tls13
    } catch {
        Write-Verbose "TLS 1.3 is not available on this system: $($_.Exception.Message)"
    }

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    return $client
}

function Invoke-Download {
    <#
    .SYNOPSIS
        Downloads a file over HTTPS and verifies its SHA-256.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Sha256
    )

    Assert-HttpsUrl $Url

    Write-Host "  Downloading $Url"
    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 900
    } finally {
        $ProgressPreference = $previous
    }

    $actual = Get-FileSha256 $Destination
    if ($actual -ne $Sha256) {
        throw "SHA-256 mismatch for $Url`n  expected $Sha256`n  actual   $actual"
    }
    Write-Host "  Verified $Sha256"
}

function Assert-HttpsUrl {
    <#
    .SYNOPSIS
        Refuses a download that is not protected by TLS.
    #>
    param([Parameter(Mandatory)][string]$Url)

    if (-not $Url.StartsWith('https://')) {
        throw "Refusing a non-HTTPS download: $Url"
    }
}

function Get-GeneratedSourceFromApi {
    <#
    .SYNOPSIS
        Fetches one of the generated sources from the upstream repository.

    .DESCRIPTION
        The contents API of the repository serves a file as text, so the file
        can be taken without an archive that has to be unpacked. The digest is
        the pinned one, so it does not matter who answered.

        The API is asked for a short time only. A network that cannot reach
        it should not hold the installation up, because there is another way
        to the same files.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Sha256
    )

    $url = 'https://api.github.com/repos/{0}/contents/{1}?ref={2}' -f `
        $script:Manifest.SourceMirror.Repository, $Path, $script:Manifest.SourceMirror.Tag
    Assert-HttpsUrl $url

    $client = New-HttpClient -TimeoutSeconds 60
    try {
        $request = New-Object System.Net.Http.HttpRequestMessage `
            ([System.Net.Http.HttpMethod]::Get, $url)
        $request.Headers.UserAgent.ParseAdd('WindowsGPUUnlock-installer')
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) {
                throw "the server answered $([int]$response.StatusCode) $($response.ReasonPhrase)"
            }
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        } finally {
            $response.Dispose()
        }
    } finally {
        $client.Dispose()
    }

    $answer = $body | ConvertFrom-Json
    if ($answer.encoding -ne 'base64' -or -not $answer.content) {
        throw "the answer did not carry the file (encoding $($answer.encoding))"
    }

    $bytes = [Convert]::FromBase64String(($answer.content -replace '\s', ''))
    [System.IO.File]::WriteAllBytes($Destination, $bytes)

    $actual = Get-FileSha256 $Destination
    if ($actual -ne $Sha256) {
        throw "SHA-256 mismatch`n  expected $Sha256`n  actual   $actual"
    }
    return $Destination
}

function Quote-NativeArgument {
    <#
    .SYNOPSIS
        Puts one argument in the form that a native program on Windows reads.
    #>
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-Tar {
    <#
    .SYNOPSIS
        Runs tar and gives back what it said and what it did.

    .DESCRIPTION
        The output of a native program is not part of the transcript of
        Windows PowerShell, so a tar that fails says nothing about why it
        failed. The two streams are read here and put into the log.

        The program is started directly instead of with the call operator, so
        that the error stream of tar does not become a terminating error of
        the script.
    #>
    param(
        [Parameter(Mandatory)][string]$TarPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $TarPath
    $startInfo.Arguments = (($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = $WorkingDirectory

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Get-ZstdHelper {
    <#
    .SYNOPSIS
        Locates the zstdcat helper.
    .DESCRIPTION
        The helper is unpacked by the installer into a directory in the
        temporary folder, because the installer carries it as text. An older
        layout had it next to the scripts, and that is still looked at.
    #>
    $candidates = @(
        (Join-Path ([System.IO.Path]::GetTempPath()) 'WindowsGPUUnlock\zstdcat.exe'),
        (Join-Path $script:ScriptRoot 'zstdcat.exe'),
        (Join-Path $script:ScriptRoot 'zstdcat')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Invoke-ZstdHelper {
    <#
    .SYNOPSIS
        Writes a compressed stream into the zstdcat helper and takes one
        member out of it.

    .DESCRIPTION
        The helper stops as soon as the wanted member has been written, and
        then closes its standard input. The writer then gets a broken pipe,
        which is the normal end of the transfer and not a failure. This is
        what lets the caller abandon a download that still has megabytes to
        go.
    #>
    param(
        [Parameter(Mandatory)][string]$HelperPath,
        [Parameter(Mandatory)][string]$Member,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][System.IO.Stream]$InputStream
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $HelperPath
    $startInfo.Arguments = "--member `"$Member`" --output `"$OutputPath`""
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw "Could not start the helper $HelperPath"
    }

    $total = 0L
    $failed = $null
    try {
        $buffer = New-Object byte[] (1MB)
        while (($read = $InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            try {
                $process.StandardInput.BaseStream.Write($buffer, 0, $read)
            } catch [System.IO.IOException] {
                # The helper closed its input, which means it is done.
                break
            }
            $total += $read
        }
    } catch {
        $failed = $_
    } finally {
        try { $process.StandardInput.Close() } catch { }
    }

    $diagnostics = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $process.Dispose()

    if ($null -ne $failed) {
        throw $failed
    }
    if ($exitCode -ne 0) {
        throw "The helper could not extract $Member.`n$diagnostics"
    }

    return [pscustomobject]@{
        BytesTransferred = $total
        Diagnostics      = $diagnostics
    }
}

function Get-PackageMember {
    <#
    .SYNOPSIS
        Streams a zstd compressed tar package and extracts one member.

    .DESCRIPTION
        The download is written into the standard input of the zstdcat
        helper, which writes the wanted member to the output file and exits
        as soon as it is complete. The download then stops, so only the part
        of the package that holds the member is transferred.

        When the helper is not available the whole package is downloaded and
        unpacked with the tar.exe of Windows. That works only where the
        bundled tar understands zstd, which is Windows 11 and later.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Member,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$HelperPath
    )

    Assert-HttpsUrl $Url

    if ([string]::IsNullOrEmpty($HelperPath)) {
        return Get-PackageMemberWithTar -Url $Url -Member $Member -OutputPath $OutputPath -WorkingDirectory $WorkingDirectory
    }

    Write-Host "  Streaming $Url"
    $client = New-HttpClient
    $response = $null
    $source = $null
    $result = $null
    try {
        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "The download failed with HTTP $([int]$response.StatusCode) $($response.ReasonPhrase)"
        }
        $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()

        $result = Invoke-ZstdHelper -HelperPath $HelperPath -Member $Member -OutputPath $OutputPath -InputStream $source
    } finally {
        if ($null -ne $source) { $source.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $client.Dispose()
    }

    Write-Host ("  Transferred {0:N1} MiB" -f ($result.BytesTransferred / 1MB))
    Write-Host "  $($result.Diagnostics)"
}

function Get-PackageMemberWithTar {
    <#
    .SYNOPSIS
        Downloads a whole package and extracts one member with tar.exe.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Member,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $tar = Get-Command tar -ErrorAction SilentlyContinue
    if ($null -eq $tar) {
        throw 'tar.exe was not found. It ships with Windows 10 (1803) and later.'
    }

    $package = Join-Path $WorkingDirectory ([System.IO.Path]::GetFileName($Url))
    Invoke-Download -Url $Url -Destination $package -Sha256 $script:Manifest.UtilsPackage.Sha256

    $root = Join-Path $WorkingDirectory 'package'
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    & $tar.Source -xf $package -C $root $Member
    if ($LASTEXITCODE -ne 0) {
        throw "tar could not extract $Member. The bundled tar of Windows may not read zstd."
    }

    $extracted = Join-Path $root $Member
    if (-not (Test-Path -LiteralPath $extracted)) {
        throw "tar did not produce $Member"
    }
    Copy-Item -LiteralPath $extracted -Destination $OutputPath -Force
    Remove-Item -LiteralPath $package -Force
}

<#
.SYNOPSIS
    Decodes the Booter bundle from the pinned NVIDIA generated source.

.DESCRIPTION
    The generated source stores the Booter image, its header and the
    signatures as C byte arrays, some of them DEFLATE compressed. This reads
    the array, inflates it when needed, and assembles the bundle in the
    layout the firmware expects.
#>
function ConvertFrom-BindataArray {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Label
    )

    $marker = "BINDATA_LABEL_${Label}_data[]"
    $index = $Text.IndexOf($marker)
    if ($index -lt 0) {
        throw "Missing byte array: $Label"
    }

    # The storage declaration sits in the window just above the array.
    $windowStart = [Math]::Max(0, $index - 400)
    $window = $Text.Substring($windowStart, $index - $windowStart)

    $compressionMatch = [regex]::Matches($window, 'COMPRESSION:\s*(YES|NO)')
    $sizeMatch = [regex]::Matches($window, 'DATA SIZE \(bytes\):\s*(\d+)')
    if ($compressionMatch.Count -eq 0 -or $sizeMatch.Count -eq 0) {
        throw "No storage declaration for $Label"
    }
    $compressed = $compressionMatch[$compressionMatch.Count - 1].Groups[1].Value -eq 'YES'
    $expected = [int]$sizeMatch[$sizeMatch.Count - 1].Groups[1].Value
    if ($expected -le 0 -or $expected -gt 16MB) {
        throw "Unexpected declared size for ${Label}: $expected"
    }

    # Take the array body up to its closing brace.
    $braceIndex = $Text.IndexOf('{', $index)
    if ($braceIndex -lt 0) {
        throw "Malformed array declaration for $Label"
    }
    $endIndex = $Text.IndexOf('}', $braceIndex)
    if ($endIndex -lt 0) {
        throw "Malformed array declaration for $Label"
    }
    $body = $Text.Substring($braceIndex + 1, $endIndex - $braceIndex - 1)

    $list = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($token in ($body -split ',')) {
        $trimmed = $token.Trim()
        if ($trimmed.Length -eq 0) { continue }
        if ($trimmed -notmatch '^0x[0-9a-fA-F]{2}$') {
            throw "Non-byte token in the $Label array: $trimmed"
        }
        $list.Add([Convert]::ToByte($trimmed.Substring(2), 16))
    }
    $bytes = [byte[]]$list.ToArray()

    if ($compressed) {
        # NVIDIA stores raw DEFLATE followed by the gzip CRC32 and ISIZE
        # trailer, without the gzip header.
        $storedMatch = [regex]::Matches($window, 'COMPRESSED SIZE \(bytes\):\s*(\d+)')
        if ($storedMatch.Count -eq 0) {
            throw "No compressed size declaration for $Label"
        }
        $stored = [int]$storedMatch[$storedMatch.Count - 1].Groups[1].Value
        if ($bytes.Count -ne $stored) {
            throw "Compressed size mismatch for $Label"
        }
        $bytes = Expand-RawDeflate $bytes $expected
    }

    if ($bytes.Count -ne $expected) {
        throw "Size mismatch for ${Label}: got $($bytes.Count), expected $expected"
    }
    return ,$bytes
}

<#
.SYNOPSIS
    Inflates a raw DEFLATE stream with a gzip trailer, as NVIDIA stores it.
#>
function Expand-RawDeflate {
    param(
        [Parameter(Mandatory)][byte[]]$Data,
        [Parameter(Mandatory)][int]$Expected
    )

    # Skip the eight byte gzip trailer: CRC32 then ISIZE, both little endian.
    if ($Data.Length -lt 8) {
        throw 'Compressed stream is too short'
    }
    $trailer = $Data[($Data.Length - 8)..($Data.Length - 1)]
    $crc = [BitConverter]::ToUInt32($trailer, 0)
    $size = [BitConverter]::ToUInt32($trailer, 4)
    if ($size -ne $Expected) {
        throw 'Compressed size field does not match the declared size'
    }

    $deflate = $Data[0..($Data.Length - 9)]
    $output = New-Object 'System.Collections.Generic.List[byte]'
    $inputStream = [System.IO.MemoryStream]::new($deflate)
    # A negative window size selects raw DEFLATE, with no zlib wrapper.
    $deflateStream = [System.IO.Compression.DeflateStream]::new($inputStream, [System.IO.Compression.CompressionMode]::Decompress, $true)
    try {
        $buffer = New-Object byte[] 65536
        while (($read = $deflateStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($output.Count + $read -gt $Expected) {
                throw 'Decompressed stream is longer than the declared size'
            }
            for ($i = 0; $i -lt $read; $i++) { $output.Add($buffer[$i]) }
        }
    } finally {
        $deflateStream.Dispose()
        $inputStream.Dispose()
    }

    if ($output.Count -ne $Expected) {
        throw "Decompressed size mismatch: got $($output.Count), expected $Expected"
    }
    # The CRC32 in the trailer covers the decompressed bytes.
    $actualCrc = Get-Crc32 ($output.ToArray())
    if ($actualCrc -ne $crc) {
        throw 'Decompressed data does not match the stored CRC32'
    }
    return ,$output.ToArray()
}

<#
.SYNOPSIS
    Computes the CRC-32 of a byte array.
#>
function Get-Crc32 {
    <#
    .SYNOPSIS
        Computes the CRC-32 of a byte array.
    .DESCRIPTION
        The arithmetic is done in 64 bits and masked back to 32 bits, because
        the initial value and the polynomial do not fit into a signed 32 bit
        literal in PowerShell.
    #>
    param([Parameter(Mandatory)][byte[]]$Data)

    [uint64]$crc = 4294967295
    [uint64]$polynomial = 3988292384
    foreach ($b in $Data) {
        $crc = ($crc -bxor $b) -band 4294967295
        for ($i = 0; $i -lt 8; $i++) {
            if (($crc -band 1) -ne 0) {
                $crc = (($crc -shr 1) -bxor $polynomial) -band 4294967295
            } else {
                $crc = ($crc -shr 1) -band 4294967295
            }
        }
    }
    return [uint32](($crc -bxor 4294967295) -band 4294967295)
}

<#
.SYNOPSIS
    Assembles the Booter bundle from its decoded parts.
#>
function New-BooterBundle {
    param([Parameter(Mandatory)][string]$SourceText)

    $image = ConvertFrom-BindataArray -Text $SourceText -Label 'IMAGE_PROD'
    $header = ConvertFrom-BindataArray -Text $SourceText -Label 'HEADER_PROD'
    $signatures = ConvertFrom-BindataArray -Text $SourceText -Label 'SIG_PROD'
    $patchLoc = ConvertFrom-BindataArray -Text $SourceText -Label 'PATCH_LOC'
    $patchMeta = ConvertFrom-BindataArray -Text $SourceText -Label 'PATCH_META'
    $numSigs = ConvertFrom-BindataArray -Text $SourceText -Label 'NUM_SIGS'

    if ($header.Length -ne 36 -or $patchLoc.Length -ne 4 -or $patchMeta.Length -ne 12 -or $numSigs.Length -ne 4) {
        throw 'Unexpected BooterLoad record size'
    }

    $fields = @()
    for ($i = 0; $i -lt 9; $i++) {
        $fields += [BitConverter]::ToUInt32($header, $i * 4)
    }
    $loc = [BitConverter]::ToUInt32($patchLoc, 0)
    $ucode = [BitConverter]::ToUInt32($patchMeta, 8)
    $engine = [BitConverter]::ToUInt32($patchMeta, 4)
    $count = [BitConverter]::ToUInt32($numSigs, 0)

    if ($count -eq 0 -or $signatures.Length -ne $count * 384 -or $fields[4] -ne 1 -or $ucode -eq 0) {
        throw 'Unsupported production Booter signature table'
    }
    if ($loc -lt $fields[2] -or $loc + 384 -gt $fields[2] + $fields[3] -or $fields[2] + $fields[3] -gt $image.Length) {
        throw 'The signature patch lies outside the DMEM image'
    }
    foreach ($range in @(@($fields[0], $fields[1]), @($fields[2], $fields[3]), @($fields[5], $fields[6]))) {
        if ($range[0] + $range[1] -gt $image.Length -or $range[0] % 256 -ne 0 -or $range[1] % 256 -ne 0) {
            throw 'Invalid Falcon transfer range'
        }
    }

    # The layout is: magic, version, the 14 word header, the image size, the
    # signature byte count, the image, then the signatures. The signature
    # byte count appears twice, once inside the header word list and once
    # next to the image size, exactly as the upstream generator writes it.
    # The image therefore starts at offset 72.
    $bundle = New-Object 'System.Collections.Generic.List[byte]'
    $bundle.AddRange([BitConverter]::GetBytes([uint32]0x314C5442))
    $bundle.AddRange([BitConverter]::GetBytes([uint32]1))
    $bundle.AddRange($header)
    $bundle.AddRange([BitConverter]::GetBytes([uint32]$loc))
    $bundle.AddRange([BitConverter]::GetBytes([uint32]$ucode))
    $bundle.AddRange([BitConverter]::GetBytes([uint32]$engine))
    $bundle.AddRange([BitConverter]::GetBytes([uint32]$count))
    $bundle.AddRange([BitConverter]::GetBytes([uint32]$signatures.Length))
    $bundle.AddRange([BitConverter]::GetBytes([uint32]$image.Length))
    $bundle.AddRange([BitConverter]::GetBytes([uint32]$signatures.Length))
    $bundle.AddRange($image)
    $bundle.AddRange($signatures)
    return ,$bundle.ToArray()
}

<#
.SYNOPSIS
    Generates the V67 payload from its pinned constants.
#>
function New-V67Payload {
    $payload = New-Object byte[] $script:V67Size
    $fill = [BitConverter]::GetBytes($script:V67Fill)
    for ($i = 0; $i -lt $payload.Length; $i += 4) {
        [Array]::Copy($fill, 0, $payload, $i, 4)
    }
    foreach ($entry in $script:V67Patched.GetEnumerator()) {
        $offset = [int]$entry.Key
        $value = [uint32]$entry.Value
        [Array]::Copy([BitConverter]::GetBytes($value), 0, $payload, $offset, 4)
    }
    return ,$payload
}

<#
.SYNOPSIS
    Produces the five firmware assets in the given directory.

.DESCRIPTION
    Downloads the pinned inputs, decodes them, generates the V67 payload and
    verifies every output against its pinned SHA-256. Returns the list of
    written files.
#>
function Get-FirmwareAssets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null

    Write-Host '1/4  Getting the pinned generated sources'

    # The generated sources are fetched from the upstream repository, which
    # serves them as text. That way no archive has to be unpacked, and the
    # unpacking is the part of the pipeline that depends on what the machine
    # has. If the repository cannot be reached, the source archive is used
    # instead: the same files, from the same release, unpacked with tar.
    $generatedRoot = Join-Path $WorkingDirectory 'generated'
    if (Test-Path -LiteralPath $generatedRoot) {
        Remove-Item -LiteralPath $generatedRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $generatedRoot -Force | Out-Null

    $problems = @()
    $missing = @()
    foreach ($pinned in $script:PinnedSources) {
        $leaf = Split-Path -Leaf $pinned.Path
        $destination = Join-Path $generatedRoot $leaf
        try {
            $null = Get-GeneratedSourceFromApi -Path $pinned.Path -Destination $destination -Sha256 $pinned.Sha256
            Write-Host ("  {0}  {1} bytes  from the upstream repository" -f $leaf, (Get-Item -LiteralPath $destination).Length)
        } catch {
            $problems += ("{0}: {1}" -f $leaf, $_.Exception.Message)
            $missing += $pinned
        }
    }

    if ($missing.Count -gt 0) {
        Write-Host '  The upstream repository did not answer, so the source archive is used instead.'
        try {
            # tar ships with Windows 10 and later.
            $tar = Get-Command tar -ErrorAction SilentlyContinue
            if ($null -eq $tar) {
                throw 'tar.exe was not found. It ships with Windows 10 (1803) and later.'
            }
            $version = Invoke-Tar -TarPath $tar.Source -Arguments @('--version') -WorkingDirectory $WorkingDirectory
            Write-Host ("  tar: {0}" -f (($version.StdOut -split "`r?`n")[0]))

            $sourceArchive = Join-Path $WorkingDirectory $script:Manifest.SourceArchive.File
            Invoke-Download -Url $script:Manifest.SourceArchive.Url -Destination $sourceArchive -Sha256 $script:Manifest.SourceArchive.Sha256

            $extractRoot = Join-Path $WorkingDirectory 'source'
            if (Test-Path -LiteralPath $extractRoot) {
                Remove-Item -LiteralPath $extractRoot -Recurse -Force
            }
            New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

            # The member names are resolved with a listing first, so that tar
            # does not have to match a pattern. The tar of Windows does not
            # match them the way the one on a Linux machine does, and a
            # pattern that it does not match ends the extraction with an
            # error and nothing extracted.
            $listing = Invoke-Tar -TarPath $tar.Source -Arguments @('-tf', $sourceArchive) -WorkingDirectory $WorkingDirectory
            if ($listing.ExitCode -ne 0) {
                throw "tar could not read the source archive (exit $($listing.ExitCode)): $($listing.StdErr.Trim())"
            }
            $members = @($listing.StdOut -split "`r?`n" | Where-Object { $_ })

            foreach ($pinned in $missing) {
                $leaf = Split-Path -Leaf $pinned.Path
                $found = @($members | Where-Object { $_.EndsWith('/' + $pinned.Path) })
                if ($found.Count -ne 1) {
                    throw "The source archive does not hold exactly one copy of $leaf, it holds $($found.Count)"
                }
                $result = Invoke-Tar -TarPath $tar.Source -Arguments @('-xf', $sourceArchive, '-C', $extractRoot, $found[0]) -WorkingDirectory $WorkingDirectory
                if ($result.ExitCode -ne 0) {
                    throw "tar could not extract $leaf (exit $($result.ExitCode)): $($result.StdErr.Trim())"
                }
                $extracted = Join-Path $extractRoot ($found[0] -replace '/', '\')
                if (-not (Test-Path -LiteralPath $extracted)) {
                    throw "tar said that it extracted $leaf, but the file is not there"
                }
                Copy-Item -LiteralPath $extracted -Destination (Join-Path $generatedRoot $leaf) -Force

                $actual = Get-FileSha256 (Join-Path $generatedRoot $leaf)
                if ($actual -ne $pinned.Sha256) {
                    throw "The extracted $leaf does not match its pinned SHA-256`n  expected $($pinned.Sha256)`n  actual   $actual"
                }
                Write-Host ("  {0}  {1} bytes  from the source archive" -f $leaf, (Get-Item -LiteralPath (Join-Path $generatedRoot $leaf)).Length)
            }
        } catch {
            throw "$($_.Exception.Message)`nThe upstream repository was asked first, and it said:`n  $($problems -join "`n  ")"
        }
    }

    Write-Host '2/4  Downloading the pinned nvidia-utils package'
    $firmwareRoot = Join-Path $WorkingDirectory 'firmware'
    if (Test-Path -LiteralPath $firmwareRoot) {
        Remove-Item -LiteralPath $firmwareRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $firmwareRoot -Force | Out-Null
    $firmware = Join-Path $firmwareRoot 'gsp_ga10x.bin'

    # Try the pinned location first, then the mirrors of the same archive.
    $sources = @($script:Manifest.UtilsPackage.Url) + @($script:Manifest.UtilsPackage.Mirrors)
    $lastError = $null
    foreach ($source in $sources) {
        try {
            Get-PackageMember -Url $source -Member $script:FirmwarePath `
                -OutputPath $firmware -WorkingDirectory $WorkingDirectory -HelperPath (Get-ZstdHelper)
            $lastError = $null
            break
        } catch {
            $lastError = $_
            Write-Warning "Could not fetch the package from $source : $($_.Exception.Message)"
        }
    }
    if ($null -ne $lastError) {
        throw $lastError
    }

    $actual = Get-FileSha256 $firmware
    if ($actual -ne $script:ExpectedOutputs['gsp_ga10x.bin']) {
        throw "The extracted GSP firmware does not match its pinned SHA-256`n  expected $($script:ExpectedOutputs['gsp_ga10x.bin'])`n  actual   $actual"
    }

    Write-Host '3/4  Decoding the Booter and GSP boot images'

    # The two sources were checked against their pinned digests when they
    # were fetched, so what is read here is what was asked for.
    $booterSource = Get-Content -LiteralPath (Join-Path $generatedRoot (Split-Path -Leaf $script:PinnedSources[0].Path)) -Raw
    $bootSource = Get-Content -LiteralPath (Join-Path $generatedRoot (Split-Path -Leaf $script:PinnedSources[1].Path)) -Raw

    $booter = New-BooterBundle -SourceText $booterSource
    $boot = ConvertFrom-BindataArray -Text $bootSource -Label 'UCODE_IMAGE_PROD'
    $desc = ConvertFrom-BindataArray -Text $bootSource -Label 'UCODE_DESC_PROD'

    if ($desc.Length -ne 84) {
        throw 'Unexpected pinned bootloader descriptor length'
    }
    $fields = @()
    for ($i = 0; $i -lt 21; $i++) {
        $fields += [BitConverter]::ToUInt32($desc, $i * 4)
    }
    if ($fields[0] -ne 5 -or $fields[14] -ne 1 -or $fields[19] -ne $boot.Length -or $fields[20] -ne 0) {
        throw 'Unsupported bootloader descriptor'
    }
    foreach ($index in @(1, 3, 8, 10, 12)) {
        if ($fields[$index + 1] -eq 0 -or $fields[$index] + $fields[$index + 1] -gt $boot.Length) {
            throw 'Bootloader descriptor range lies outside the image'
        }
    }

    Write-Host '4/4  Generating the V67 payload'
    $v67 = New-V67Payload

    $outputs = @{
        'booter_load_ga102.bin'   = $booter
        'gsp_boot_ga102.bin'      = $boot
        'gsp_boot_desc_ga102.bin' = $desc
        'v67-ga102-610.43.03.bin' = $v67
        'gsp_ga10x.bin'           = [System.IO.File]::ReadAllBytes($firmware)
    }

    # Verify every output against the pinned digest before it is written.
    foreach ($name in $outputs.Keys) {
        $bytes = [byte[]]$outputs[$name]
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
        if ($hash -ne $script:ExpectedOutputs[$name]) {
            throw "Generated asset does not match its pinned SHA-256: $name`n  expected $($script:ExpectedOutputs[$name])`n  actual   $hash"
        }
    }

    $written = @()
    foreach ($name in $outputs.Keys) {
        $path = Join-Path $OutputDirectory $name
        [System.IO.File]::WriteAllBytes($path, [byte[]]$outputs[$name])
        $written += $path
        Write-Host "  $name  ($((Get-Item -LiteralPath $path).Length) bytes)"
    }

    return $written
}
