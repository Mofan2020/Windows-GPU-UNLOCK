// Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
/*
 * UEFI platform layer for the generic Windows installer.
 *
 * Derived from internal-boot/unlock/port.h in this repository (GPL-2.0-only,
 * Copyright (C) Windows GPU UNLOCK contributors), with the machine-specific
 * profile removed. Upstream compiles a fixed device ID, subsystem ID, chip ID,
 * BAR0 base and PROM hash into the image; here the card is identified at run
 * time by windows/efi/board.c and the values are injected through
 * GuSetTargetIdentity.
 */
#pragma once

#include <Uefi.h>
#include <Protocol/PciIo.h>
#include <Protocol/DevicePath.h>
#include <stddef.h>

/* The identity of the card the transaction runs against, observed at run
 * time. Zero until GuSetTargetIdentity is called; the transaction refuses to
 * start while it is unset. */
typedef struct {
  BOOLEAN set;
  UINT32 device_id;   /* PCI vendor/device dword, as read from offset 0. */
  UINT32 chip;        /* Chip ID from BAR0 offset 0. */
  UINT32 memory_mb;   /* Framebuffer size in MiB, from BAR0 offset 0x1183a4. */
} GU_TARGET;

extern GU_TARGET GuTarget;

/* Record the observed identity. The vendor core compares the configuration
 * space against device_id at several points to prove the same card is still
 * present; this is that value. */
VOID GuSetTargetIdentity(UINT32 DeviceId, UINT32 Chip, UINT32 MemoryMb);

/* The AMI aggregate console splitter and the nvgop driver differ per BIOS.
 * The generic installer does not fingerprint them, so no machine identity
 * constants are compiled in. These remain for the display topology check. */

#define GU_SELECTOR_PHASE_ENTRY 0U
#define GU_SELECTOR_PHASE_SS0_WRITTEN 1U
#define GU_SELECTOR_PHASE_SS1_WRITE 2U
#define GU_SELECTOR_PHASE_TARGET 3U

typedef struct GU_DMA GU_DMA;
struct GU_DMA {
  GU_DMA *next;
  VOID *cpu, *mapping;
  UINT64 dma;
  UINTN bytes, pages;
  BOOLEAN mapped;
};

typedef struct {
  EFI_BOOT_SERVICES *bs;
  EFI_PCI_IO_PROTOCOL *pci;
  EFI_HANDLE image, handle;
  UINT64 bar_base, bar_size, ticks;
  UINT16 pm_cap, pcie_cap, msi_cap, msix_cap;
  UINT32 saved_config[64];
  UINT16 saved_devctl, saved_devctl2;
  UINT8 pcie_version;
  BOOLEAN fault, retained, started, quiesced, armed, owned, display_ok, saved;
  BOOLEAN profile_verified, prom_verified;
  BOOLEAN master_attributes_pending;
  UINT64 master_original_attributes;
  UINT16 master_original_command;
  EFI_PCI_IO_PROTOCOL *master_pci;
  EFI_STATUS master_attribute_status, master_hardware_status;
  UINT64 master_last_attributes;
  UINT16 master_last_command;
  UINT32 flrs, mmio_writes, dma_count;
  GU_DMA *allocations;
  BOOLEAN (*display_check)(VOID);
} GU_PLATFORM;

extern GU_PLATFORM Gu;

VOID GuInit(EFI_BOOT_SERVICES *Bs, EFI_PCI_IO_PROTOCOL *Pci);

/* Latch the selector values observed at cold entry. The transaction writes
 * SS0 to the unlock value and SS1 to the target value; latching the entry
 * state means the write phase is guarded against a card that changed under
 * us. */
BOOLEAN GuLatchEntrySelectors(UINT32 Ss0, UINT32 Ss1);
BOOLEAN GuGetEntrySelectors(UINT32 *Ss0, UINT32 *Ss1);
BOOLEAN GuEntrySelectorsMatch(UINT32 Ss0, UINT32 Ss1);

/* The write phase may only advance through the recorded order, and SS1 may
 * only be written once, by the phase that owns it. */
BOOLEAN GuSelectorPhase(UINT32 Phase);

BOOLEAN GuTargetConfig(const UINT32 *Config, UINTN Segment, UINTN Bus, UINTN Device, UINTN Function);
BOOLEAN GuSafeToReturn(VOID);
EFI_STATUS GuDmaAllocate(UINTN Bytes, VOID **Cpu, UINT64 *Dma);
EFI_STATUS GuDmaFree(VOID *Cpu, UINT64 Dma);
UINT32 GuRead32(UINT32 Offset);
VOID GuWrite32(UINT32 Offset, UINT32 Value);
EFI_STATUS GuSavePci(VOID);
EFI_STATUS GuRestorePci(VOID);
EFI_STATUS GuFlr(VOID);
EFI_STATUS GuClearMaster(VOID);
EFI_STATUS GuEnableMaster(VOID);
EFI_STATUS GuConfigRead(EFI_PCI_IO_PROTOCOL_WIDTH Width, UINT32 Offset, VOID *Value);
EFI_STATUS GuConfigWrite(EFI_PCI_IO_PROTOCOL_WIDTH Width, UINT32 Offset, VOID *Value);
VOID GuStarted(VOID);
VOID GuQuiesced(VOID);
VOID GuLog(const char *Format, ...);
VOID GuLogText(const char *Text);
VOID GuCopyFromIo(VOID *Destination, const VOID *Source, size_t Bytes);
VOID *GuAlloc(size_t Bytes);
VOID GuFree(VOID *Memory);
VOID GuStall(UINTN Microseconds);
