# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
<#
.SYNOPSIS
    Detects the display hardware and reports whether this tool applies.

.DESCRIPTION
    The unlock only applies to NVIDIA GA10x cards (GA102, GA103, GA104 and
    GA106: the RTX 3090 / 3080 / 3070 / 3060 families). This module enumerates
    the display adapters through WMI and the PCI bus, and reports what it
    found. A machine with no NVIDIA adapter, or with an NVIDIA adapter that
    is not a supported part, is refused by the installer.

    Detection is read-only. Nothing is written to the registry, to the
    firmware or to any device.
#>

Set-StrictMode -Version Latest

# The supported device IDs, matching the upstream Linux module's
# kernel/gpu_unlock/main.c supported_ids table. The high word is the PCI
# device ID of the GA10x consumer parts.
$script:SupportedDeviceIds = @(
    # GA102
    0x2200, 0x2203, 0x2204, 0x2205, 0x2206, 0x2207, 0x2208, 0x220a,
    0x220d, 0x2216, 0x222b, 0x222f,
    # GA104
    0x2480, 0x2482, 0x2483, 0x2484, 0x2486, 0x2487, 0x2488, 0x2489,
    0x248a, 0x248c, 0x248d, 0x248e, 0x249c, 0x249d, 0x249f, 0x24a0,
    0x24a4, 0x24ac, 0x24ad, 0x24af, 0x24bf, 0x24c0, 0x24c7, 0x24c8,
    0x24c9, 0x24dc, 0x24dd, 0x24df, 0x24e0,
    # GA103
    0x2414,
    # GA106
    0x2501, 0x2503, 0x2504, 0x2505, 0x2507, 0x2508, 0x2509, 0x252f,
    0x2544
)

# Friendly names for the parts people actually own. Anything not listed here
# is still accepted; the name is only used in the installer text.
$script:DeviceNames = @{
    0x2203 = 'GA102  RTX 3090 Ti'
    0x2204 = 'GA102  RTX 3090'
    0x2205 = 'GA102  RTX 3080 Ti'
    0x2206 = 'GA102  RTX 3080'
    0x2207 = 'GA102  RTX 3080 12GB'
    0x2208 = 'GA102  RTX 3090 Ti (Founders Edition)'
    0x220a = 'GA102  RTX 3080 10GB (OEM)'
    0x220d = 'GA102  RTX 3080 12GB (OEM)'
    0x2216 = 'GA102  RTX 3090 Ti (OEM)'
    0x222b = 'GA102  RTX 3090 (OEM)'
    0x222f = 'GA102  RTX 3080 (OEM)'
    0x2414 = 'GA103  RTX 3080 Ti (OEM)'
    0x2482 = 'GA104  RTX 3070 Ti'
    0x2483 = 'GA104  RTX 3070'
    0x2484 = 'GA104  RTX 3070'
    0x2486 = 'GA104  RTX 3070 Ti (OEM)'
    0x2487 = 'GA104  RTX 3080'
    0x2489 = 'GA104  RTX 3060 Ti'
    0x248a = 'GA104  RTX 3060 Ti'
    0x249d = 'GA104  RTX 3060'
    0x2503 = 'GA106  RTX 3060 8GB'
    0x2504 = 'GA106  RTX 3060 12GB'
}

function Get-SupportedDeviceName {
    param([uint32]$DeviceId)

    # The keys of the table are plain integers. A lookup with a different
    # numeric type would not find them, so the key is converted first.
    $key = [int]$DeviceId
    if ($script:DeviceNames.ContainsKey($key)) {
        return $script:DeviceNames[$key]
    }
    return ('NVIDIA device {0:X4}' -f $DeviceId)
}

<#
.SYNOPSIS
    Enumerates the display adapters on this machine.

.DESCRIPTION
    Returns one record per display adapter. Each record has:
      Adapter   the WMI name
      VendorId  the PCI vendor ID, 0x10de for NVIDIA
      DeviceId  the PCI device ID
      DriverVersion the reported driver version
      Supported $true when the device is a supported GA10x part
#>
function Get-DisplayAdapter {
    [CmdletBinding()]
    param()

    $adapters = @()

    # WMI gives the human-facing picture. The PNP device ID carries the PCI
    # vendor and device IDs, which is what decides whether the unlock applies.
    # The query is given a time limit, because the WMI service on a busy
    # machine can take a very long time to answer, and an installer that
    # hangs is worse than one that says it could not find out.
    $videos = @()
    try {
        $videos = @(Get-CimInstance -ClassName Win32_VideoController -OperationTimeoutSec 20 -ErrorAction Stop)
    } catch {
        Write-Verbose "Win32_VideoController is unavailable: $($_.Exception.Message)"
    }

    foreach ($video in $videos) {
        $vendorId = $null
        $deviceId = $null
        $pnp = $video.PNPDeviceID
        if ($pnp -and $pnp -match 'PCI\\VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})') {
            $vendorId = [Convert]::ToUInt32($Matches[1], 16)
            $deviceId = [Convert]::ToUInt32($Matches[2], 16)
        } elseif ($pnp -and $pnp -match 'PCI\\VEN_([0-9A-Fa-f]{4})') {
            $vendorId = [Convert]::ToUInt32($Matches[1], 16)
        }

        $deviceName = $null
        if ($null -ne $deviceId) {
            $deviceName = Get-SupportedDeviceName $deviceId
        }

        $adapters += [pscustomobject]@{
            Adapter        = $video.Name
            DeviceName     = $deviceName
            PnpDeviceId    = $pnp
            VendorId       = $vendorId
            DeviceId       = $deviceId
            DriverVersion  = $video.DriverVersion
            AdapterRam     = $video.AdapterRAM
            Status         = $video.Status
            IsNvidia       = ($null -ne $vendorId -and $vendorId -eq 0x10de)
            IsSupported    = ($null -ne $deviceId -and $script:SupportedDeviceIds -contains $deviceId)
            # A virtual display adapter, such as the one a remote desktop
            # program installs, has no place on the PCI bus. Only a real
            # adapter can take the screen over from the card that is
            # unlocked.
            IsPhysical     = ($pnp -like 'PCI\*')
        }
    }

    return $adapters
}

<#
.SYNOPSIS
    Decides whether this machine can be unlocked with this tool.

.DESCRIPTION
    Returns a result object with:
      Supported  $true when exactly one supported NVIDIA adapter is present
      Reason     a human-readable explanation when it is not
      Adapters   the full adapter list
      Target     the adapter that would be unlocked
#>
function Test-UnlockTarget {
    [CmdletBinding()]
    param()

    $adapters = @(Get-DisplayAdapter)
    $nvidia = @($adapters | Where-Object { $_.IsNvidia })
    $supported = @($adapters | Where-Object { $_.IsSupported })

    if ($adapters.Count -eq 0) {
        return [pscustomobject]@{
            Supported = $false
            Reason    = 'No display adapter was reported by Windows. This tool cannot determine whether it applies.'
            Adapters  = $adapters
            Target    = $null
        }
    }

    if ($nvidia.Count -eq 0) {
        $other = ($adapters | ForEach-Object { $_.Adapter }) -join '; '
        return [pscustomobject]@{
            Supported = $false
            Reason    = "This tool only works on NVIDIA GeForce RTX 30-series cards. No NVIDIA display adapter was found on this machine. Detected instead: $other"
            Adapters  = $adapters
            Target    = $null
        }
    }

    if ($supported.Count -eq 0) {
        $found = ($nvidia | ForEach-Object { '{0} (PCI {1:X4}:{2:X4})' -f $_.Adapter, $_.VendorId, $_.DeviceId }) -join '; '
        return [pscustomobject]@{
            Supported = $false
            Reason    = "An NVIDIA card was found, but it is not a supported GA10x part. This tool covers the GA102, GA103, GA104 and GA106 families (RTX 3090, 3080, 3070 and 3060). Found: $found"
            Adapters  = $adapters
            Target    = $null
        }
    }

    if ($supported.Count -gt 1) {
        $found = ($supported | ForEach-Object { '{0} (PCI {1:X4}:{2:X4})' -f $_.Adapter, $_.VendorId, $_.DeviceId }) -join '; '
        return [pscustomobject]@{
            Supported = $false
            Reason    = "More than one supported NVIDIA card was found. The unlock transaction targets exactly one card, so remove the extra card or test with a single GPU. Found: $found"
            Adapters  = $adapters
            Target    = $null
        }
    }

    $target = $supported[0]
    return [pscustomobject]@{
        Supported = $true
        Reason    = ''
        Adapters  = $adapters
        Target    = $target
    }
}
