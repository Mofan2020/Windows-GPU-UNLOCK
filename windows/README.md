# Windows GPU UNLOCK — generic installer

This is a **Windows** port of the [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)
Linux kernel module. It unlocks the FP16/BF16 tensor instruction rate on NVIDIA
GeForce RTX 30-series cards (GA102, GA103, GA104, GA106 — the RTX 3090, 3080,
3070 and 3060 families). Consumer cards run those instructions at roughly half
the rate of the professional parts; the unlock removes that limit. It changes no
clocks and no power limits, and it does not flash the card's VBIOS.

## What is different from the upstream Linux module

The upstream project ships a Linux kernel module. This repository carries a
**UEFI** port of the same unlock transaction, plus an installer.

The transaction itself is the same code. It runs in firmware, before the
operating system loads, so the NVIDIA driver has not yet bound the card. It
reads the board PROM, patches the Booter with the V67 signature, loads the GSP
firmware, writes the SS0/SS1 speed selectors and performs a PCIe function level
reset. Then it hands over to the Windows Boot Manager.

## What is different from the earlier UEFI experiment in this repository

The upstream `internal-boot/` build compiles **one machine** into the EFI
image: a fixed PCI address, device ID, subsystem ID, chip ID, BAR0 base, PROM
hash, and fingerprints of the BIOS display drivers. It therefore works on
exactly the machine it was built for, and every other card needs a rebuild.

The `windows/` build in this repository removes all of that. The card is
identified at run time:

- every display endpoint on the PCI bus is enumerated;
- the one that is a supported GA10x part becomes the target;
- its device ID, subsystem ID, chip ID, framebuffer size and BAR0 geometry are
  read from the card itself;
- the capability chain is checked structurally rather than against a pinned
  hash.

One binary serves every supported card. Nothing is read from a user-editable
file, so a wrong value cannot be injected — it can only make the transaction
refuse to run.

## Installing

Download `WindowsGPUUnlock-<version>-setup.exe` from the releases and run it.

The installer is interactive. It shows what it will do before it touches
anything, checks the machine, then installs. It needs the administrator token,
because it writes to the EFI system partition and edits the boot
configuration.

### Before you install

1. **Turn Secure Boot off in the BIOS.** The application is not signed, so a
   firmware that enforces Secure Boot will refuse to load it. The installer
   checks this and refuses to continue while Secure Boot is on.

2. **Turn off Windows Fast Startup**, so a shutdown really powers the card
   down. A hibernated session keeps the old card state and the unlock will be
   skipped.

   ```powershell
   powercfg /h off
   ```

3. **Suspend BitLocker** on the Windows volume, if it is enabled. The
   transaction resets the graphics card, which can send a locked machine into
   recovery. The installer refuses to continue while the protection is on.

   ```powershell
   manage-bde -protectors -disable C:
   ```

   Turn it back on afterwards with `manage-bde -protectors -enable C:`.

4. **Check that the display is not plugged into the card you want to unlock.**
   The firmware console has to live somewhere else, because the unlock resets
   the card's display engine. If the card drives the display, the tool refuses
   to run. In practice this means a machine with an integrated GPU, with the
   display plugged into it.

### What happens at boot

The registered boot entry runs before Windows. The application asks you to press
`U` to proceed, or `Esc` to cancel and boot Windows unchanged. The screen may
go black for a few seconds while the card resets; that is normal.

The boot entry points at the unlock application, so the application starts the
Windows Boot Manager itself once the transaction is finished, or once it has
been cancelled. The machine therefore ends up in Windows in either case.

### What the installer changes

- It writes `\EFI\WindowsGPUUnlock` on the **existing** EFI system partition.
  No partition is created, resized or reformatted.
- It registers one boot entry and puts it first in the firmware boot order.
  The original boot configuration is exported to
  `%ProgramData%\WindowsGPUUnlock\backups\` before anything is changed.
- The EFI system partition is hidden by default, and the boot configuration can
  only name a partition by drive letter. The installer gives it one (`S:`,
  `T:`, ...) and takes it away again when you uninstall.

A report of every run is written to the EFI system partition:

```
<ESP>\EFI\WindowsGPUUnlock\RUNnn\REPORT.TXT
```

### Removing it

Run the same installer again and choose **Uninstall**. It removes the boot
entry and the staged files, and keeps a backup of your original boot
configuration under `%ProgramData%\WindowsGPUUnlock\backups\`.

## The firmware assets

The five firmware files the unlock needs are **not** shipped with the
installer. NVIDIA's licence does not permit redistributing them.

Instead, the installer downloads the pinned upstream inputs over HTTPS and
generates the assets on your own machine, exactly as the upstream Linux module
does:

- the NVIDIA open kernel module source archive, which carries the Booter and
  GSP boot images;
- the `nvidia-utils` package, which carries the GSP firmware blob.

Both are checked against their pinned SHA-256 before use, and every generated
output is checked against a pinned digest as well. The pinned values come from
the upstream repository's `firmware/artifacts-610.43.03.json`, at commit
`0ebdb1c6308b20714be5bf04513472942541956`.

The `nvidia-utils` package is about 300 MB, but only the part that carries the
GSP firmware is needed. The installer streams the package and stops as soon as
that member is written, so roughly **72 MiB** of it is transferred. Together
with the 26 MiB source archive the download is about 100 MB. It happens once, at
install time.

### The zstd helper

The `nvidia-utils` package is a `.pkg.tar.zst` archive. The `tar.exe` that
ships with Windows is bsdtar 3.3.2, built on libarchive 3.3.2, which has no
zstd support at all — the zstd filter was only added to libarchive in 3.3.3.
The archive also cannot be unpacked through libarchive's external program
filter, because Windows has no `zstd` binary.

The installer therefore ships a small helper, `zstdcat.exe`. It decompresses
the zstd stream, walks the tar headers, writes the wanted member and exits. The
helper is built from the Zstandard reference implementation, which is vendored
under `windows/installer/zstd/lib/`.

The helper reads its input in binary mode. The standard input of a Windows
program is in text mode by default, and a read in text mode stops at the first
Ctrl-Z byte and turns a CRLF into a LF. The compressed stream holds both, so
the read would stop in the middle of the first block.

## Compatibility

| Chip  | Cards                          | Device IDs                    | State                              |
| ----- | ------------------------------ | ----------------------------- | ---------------------------------- |
| GA102 | RTX 3090, 3090 Ti, 3080, 3080 Ti | `0x2200`–`0x222f`            | upstream hardware reports exist     |
| GA103 | RTX 3080 Ti (OEM)              | `0x2414`                      | accepted, no hardware report        |
| GA104 | RTX 3070, 3070 Ti, 3060 Ti      | `0x2480`–`0x24e0`            | upstream hardware reports exist     |
| GA106 | RTX 3060 8GB, 3060 12GB        | `0x2501`–`0x2544`            | upstream hardware report for `0x2504` |

The device ID list is the same one the upstream Linux module accepts. The
installer refuses to run on a machine with no NVIDIA adapter, on an NVIDIA
adapter that is not in this list, and on a machine with more than one
supported card.

The chip revision must be `0xb72000a1` (GA102) or `0xb74000a1` (GA104 and
GA106).

**This is experimental.** It modifies low-level firmware state. The upstream
project has hardware reports for a small number of cards, not for all of them.
Do not use it on a machine you depend on unless you have verified the recovery
path. Keep a bootable USB handy.

## Building from source

The EFI application builds with clang and lld-link, and the host tests build
with any C compiler:

```sh
# The EFI application.
clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding \
  -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar \
  -Os -Wall -Wextra -Werror -D__KERNEL__ -DGU_UEFI_PORT \
  -I windows/efi/compat -I deps/edk2/MdePkg/Include \
  -I deps/edk2/MdePkg/Include/X64 \
  -c windows/efi/<source>.c

# The host tests.
clang -std=c11 -Wall -Wextra -Werror -DGU_HOST_TEST=1 \
  -o test_generic_board windows/tests/test_generic_board.c \
  windows/efi/board.c windows/efi/checks.c
```

`windows/efi/build.ps1` does the same thing with the right flags and links
the image. The installer is packaged with NSIS; see
`windows/installer/WindowsGPUUnlock.nsi`.

The zstd helper is built from the vendored Zstandard sources:

```sh
# For the host.
windows/installer/zstd/build.sh

# For Windows x64, with mingw-w64.
windows/installer/zstd/build.sh x86_64-w64
```

## Tests

```sh
# The card detection and the capability checks.
clang -std=c11 -Wall -Wextra -Werror -O1 -DGU_HOST_TEST=1 \
  -o test_generic_board windows/tests/test_generic_board.c \
  windows/efi/board.c windows/efi/checks.c
./test_generic_board

# The installer's decisions, with the Windows specific commands stubbed.
pwsh -NoProfile -File windows/tests/test-installer-logic.ps1
```

## Licence and attribution

This repository is GPL-2.0-only. The unlock transaction in
`windows/efi/vendor/` is derived from the upstream Linux module and from this
repository's earlier `internal-boot/` experiment. The NVIDIA firmware remains
under NVIDIA's own terms and is not redistributed here; see
`firmware/NOTICE.md` in the upstream repository for the full attribution.
