# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
<#
.SYNOPSIS
    Builds the generic EFI unlock application.

.DESCRIPTION
    Compiles the application with clang and links it with lld-link, producing
    a PE32+ image that the firmware can load. This is the same toolchain and
    the same command shape the upstream UEFI build uses; only the sources
    differ, because this build carries no machine profile.

.PARAMETER Clang
    Path to clang.

.PARAMETER LldLink
    Path to lld-link.

.PARAMETER Output
    The output directory. The image is written as UNLOCK.EFI.

.PARAMETER Edk2Include
    The EDK2 MdePkg include directory. It ships with the repository under
    deps/edk2.
#>

[CmdletBinding()]
param(
    [string]$Clang = 'clang',
    [string]$LldLink = 'lld-link',
    [string]$Output = "$PSScriptRoot/../build",
    [string]$Edk2Include = "$PSScriptRoot/../../deps/edk2/MdePkg/Include"
)

$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$efi = Join-Path $repo 'windows/efi'
$include = Join-Path $repo 'deps/edk2/MdePkg/Include'

if (-not (Test-Path -LiteralPath (Join-Path $include 'Uefi.h'))) {
    throw "The EDK2 headers were not found at $include"
}

New-Item -ItemType Directory -Path $Output -Force | Out-Null
$Output = [IO.Path]::GetFullPath($Output)

# The application sources. The vendor directory holds the unmodified unlock
# transaction from the upstream Linux module.
$sources = @(
    'app.c',
    'app_io.c',
    'board.c',
    'checks.c',
    'compat/compat.c',
    'format.c',
    'ownership.c',
    'port.c',
    'runtime.c',
    'sha256.c',
    'vendor/gfw_eval.c',
    'vendor/layout_610.c',
    'vendor/prep_610.c',
    'vendor/unlock_610.c',
    'vendor/vbios_610.c'
)

$objects = @()
foreach ($source in $sources) {
    $path = Join-Path $efi $source
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Source file not found: $path"
    }
    $object = Join-Path $Output (($source -replace '/', '_') -replace '\.c$', '.obj')
    & $Clang `
        -target x86_64-pc-windows-msvc `
        -std=c11 `
        -ffreestanding `
        -fno-builtin `
        -fno-stack-protector `
        -mno-red-zone `
        -fshort-wchar `
        -Os `
        -Wall `
        -Wextra `
        -Werror `
        -Wno-unused-parameter `
        -D__KERNEL__ `
        -DGU_UEFI_PORT `
        -I (Join-Path $efi 'compat') `
        -I $include `
        -I (Join-Path $include 'X64') `
        -c $path `
        -o $object
    if ($LASTEXITCODE -ne 0) {
        throw "Compile failed: $source"
    }
    $objects += $object
}

$image = Join-Path $Output 'UNLOCK.EFI'
$map = Join-Path $Output 'UNLOCK.map'

& $LldLink `
    /nologo `
    /nodefaultlib `
    /subsystem:efi_application `
    /entry:efi_main `
    /machine:x64 `
    /base:0 `
    /dynamicbase `
    /nxcompat `
    /timestamp:0 `
    /opt:ref `
    /opt:icf `
    "/map:$map" `
    "/out:$image" `
    @objects

if ($LASTEXITCODE -ne 0) {
    throw 'The EFI link failed'
}

$hash = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash.ToLowerInvariant()
$size = (Get-Item -LiteralPath $image).Length
Write-Host "Built $image"
Write-Host "  bytes  $size"
Write-Host "  sha256 $hash"
