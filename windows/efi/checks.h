// Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
/*
 * Generic preflight checks for the Windows installer.
 *
 * Upstream's checks.c pins one machine: it rejects any endpoint that is not
 * at segment 0 bus 1 device 0 function 0, and it requires one specific device
 * ID and subsystem ID. This file keeps the structural checks that matter for
 * safety (the endpoint must be a display-class PCIe function with the
 * capabilities the transaction needs) and takes the identity from the card.
 */
#pragma once

#ifdef GU_HOST_TEST
/* Host stand-ins, so the same source compiles for the host tests. */
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
typedef uint8_t UINT8;
typedef uint16_t UINT16;
typedef uint32_t UINT32;
typedef uint64_t UINT64;
typedef uint64_t UINTN;
typedef int BOOLEAN;
#define TRUE 1
#define FALSE 0

/* The PCI constants the checks rely on, mirrored from EDK2's Pci.h so the
 * host build needs no firmware headers. */
#define PCI_CLASS_DISPLAY 0x03
#define PCI_HEADER_TYPE_OFFSET 0x0e
#define HEADER_TYPE_DEVICE 0x00
#define PCI_COMMAND_OFFSET 0x04
#define EFI_PCI_COMMAND_MEMORY_SPACE 0x02
#define EFI_PCI_COMMAND_BUS_MASTER 0x04
#define PCI_EXPANSION_ROM_BASE 0x30
#define PCI_PRIMARY_STATUS_OFFSET 0x06
#define EFI_PCI_STATUS_CAPABILITY 0x10
#define PCI_CAPABILITY_POINTER_OFFSET 0x34
#define EFI_PCI_CAPABILITY_ID_PMI 0x01
#define EFI_PCI_CAPABILITY_ID_MSI 0x05
#define EFI_PCI_CAPABILITY_ID_VENDOR 0x09
#define PCI_EXPRESS_CAPABILITY_ID 0x10
#define PCI_POWER_STATE_D0 0x00
#else
#include <Uefi.h>
#include <Protocol/PciIo.h>
#endif

typedef struct {
  UINT16 pm, pcie, msi, msix;
  UINT8 pcie_version;
} GU_CAPS;

/*
 * Config is a complete, CPU-owned 256-byte snapshot of the endpoint's
 * configuration space. Out is cleared on failure.
 *
 * The checks are structural only: display class, a type-0 header, memory
 * decode enabled, bus mastering off, no expansion ROM decode, a PM capability
 * in D0, a PCIe capability with function level reset, and a capability chain
 * that does not overlap itself. The device and subsystem IDs are deliberately
 * not compared here; board.c decides which cards are supported.
 */
BOOLEAN GuCheckConfigGeneric(const UINT32 Config[64], UINTN Segment, UINTN Bus,
                             UINTN Device, UINTN Function, GU_CAPS *Out);
