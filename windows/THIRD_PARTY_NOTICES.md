# Third-party notices — generic Windows build

This file covers the `windows/` directory: the generic EFI application, its
host tests and the installer. The notices for the rest of the repository are
in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Unlock transaction core — GPL-2.0-only

- Original: [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock/tree/0ebdb1c6308b20714be5bf04513472942541956)
- Pinned commit: `0ebdb1c6308b20714be5bf04513472942541956`
- Covers: `windows/efi/vendor/unlock_610.c`, `prep_610.c`, `layout_610.c`,
  `vbios_610.c`, `gfw_eval.c` and `diagnostic.h`.
- Licence text: [LICENSE](../LICENSE).

These files are the unlock transaction, ported from the upstream Linux kernel
module to run against EDK2's `EFI_PCI_IO_PROTOCOL`. The transaction sequence,
the register offsets and the firmware handling are unchanged.

## UEFI port of the earlier experiment — GPL-2.0-only

- Covers: `windows/efi/app.c`, `app_io.c`, `board.c`, `checks.c`, `port.c`,
  `runtime.c`, `format.c`, `sha256.c`, `ownership.c`,
  `windows/efi/compat/compat.h` and `compat/compat.c`,
  `windows/efi/compat/linux/*.h`.
- Derived from `internal-boot/unlock/` in this repository, which is itself
  GPL-2.0-only, Copyright (C) Windows GPU UNLOCK contributors.

## EDK2 headers — BSD-2-Clause-Patent

- Original: [TianoCore EDK2](https://github.com/tianocore/edk2/tree/c1415771ac592ad8509351c46cd3cda4f38d7d52)
- Pinned commit: `c1415771ac592ad8509351c46cd3cda4f38d7d52`
- Covers: `deps/edk2/MdePkg/Include/`.
- Licence text: [EDK2 licence](../LICENSES/EDK2-BSD-2-Clause-Patent.txt) and
  the header of each file.

The application uses the header declarations only. No EDK2 library binary is
linked.

## Changes made for the generic build

The earlier `internal-boot/` build compiles one machine into the EFI image: a
fixed PCI address, device ID, subsystem ID, chip ID, BAR0 base, PROM hash and
fingerprints of the BIOS display drivers.

The `windows/` build replaces all of that with a run-time observation of the
card:

- `windows/efi/board.c` identifies the card from the PCI bus and reads its
  device ID, subsystem ID, chip ID, framebuffer size and BAR0 geometry.
- `windows/efi/checks.c` checks the capability chain structurally instead of
  comparing against pinned values.
- `windows/efi/app.c` selects the endpoint at run time and refuses when the
  card is not a supported GA10x part.

The transaction in `windows/efi/vendor/` is not changed in any way that
affects what it writes to the hardware.

## Installer — GPL-2.0-only

`windows/installer/` is original work in this repository, GPL-2.0-only. It
packages the application with NSIS, whose licence is covered by the NSIS
licence, and it drives the Windows built-in PowerShell and bcdedit.

## Zstandard — BSD-3-Clause or GPL-2.0

- Original: [facebook/zstd](https://github.com/facebook/zstd/tree/v1.5.7)
- Pinned tag: `v1.5.7`
- Covers: `windows/installer/zstd/lib/`, and the wrapper
  `windows/installer/zstd/zstdcat.c`.
- Licence text: [windows/installer/zstd/LICENSE](installer/zstd/LICENSE).

Only the decompression half of the reference implementation is vendored, and
only because the `tar.exe` that ships with Windows is built on libarchive
3.3.2, which cannot read zstd at all. The wrapper `zstdcat.c` is original work
in this repository.

The Zstandard sources are offered under the BSD 3-Clause licence and, at your
option, the GPL version 2. The BSD licence is used here, so the helper stays
compatible with the GPL-2.0-only licence of this repository.

## NVIDIA firmware — not redistributed

The five firmware files the unlock needs are **not** included in this
repository or in any release produced from it.

The installer downloads the pinned upstream inputs over HTTPS and generates
the files on the user's own machine, then verifies every output against a
pinned SHA-256:

- the NVIDIA open kernel module source archive, which carries the Booter and
  GSP boot images;
- the `nvidia-utils` package, which carries the GSP firmware blob.

The pinned values come from the upstream repository's
`firmware/artifacts-610.43.03.json`, at commit
`0ebdb1c6308b20714be5bf04513472942541956`.

NVIDIA firmware remains under NVIDIA's own terms. The relevant notices are
kept in this repository:

- [NVIDIA MIT notice](../LICENSES/NVIDIA-MIT.txt)
- [CMP40HX MIT notice](../LICENSES/CMP40HX-MIT.txt)
- [NVIDIA Driver License Agreement](../LICENSES/NVIDIA-Driver.txt)

Nothing here claims redistribution rights over the NVIDIA firmware. The
installer fetches it from NVIDIA's and CachyOS's own servers, at the user's
request, and the user is the one who obtains it.
